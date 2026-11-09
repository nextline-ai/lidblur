import Foundation
import QuartzCore
import IOKit
import IOKit.hid

/// Reads the MacBook lid-angle sensor (HID usage page 0x20 Sensor, usage 0x8A) by polling its feature report.
/// The report is [reportID, lo, hi] with the angle in whole degrees.
final class LidAngleSensor {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private let lock = NSLock()
    private var _angle: Double?
    private var _timestamp: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "work.nextline.lidblur.sensor", qos: .userInteractive)
    private(set) var statusText: String = "초기화 전"
    private var currentHz: Double = 0
    /// Called on the sensor queue whenever the raw angle changes.
    var onChange: ((Double) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x0020,
            kIOHIDPrimaryUsageKey: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        openDevice()
    }

    var isAvailable: Bool { lock.withLock { device != nil } }

    /// Latest raw angle in degrees, or nil if the sensor is unavailable.
    var angle: Double? { lock.withLock { _angle } }

    /// The sensor only refreshes about every 100 ms in whole degrees. To get continuous motion, each new
    /// sample is approached linearly over one sensor period, starting from the value shown at that moment.
    static let samplePeriod: CFTimeInterval = 0.1
    private var segStart: Double?
    private var segTarget: Double = 0
    private var segTime: CFTimeInterval = 0

    /// Continuous angle estimate (about one sensor period behind the raw value).
    func smoothAngle(at now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        lock.withLock {
            guard let start = segStart else { return _angle }
            let a = min(1, max(0, (now - segTime) / Self.samplePeriod))
            return start + (segTarget - start) * a
        }
    }

    private func pushSample(_ v: Double, at now: CFTimeInterval) {
        // called with lock held
        if segStart == nil { segStart = v; segTarget = v; segTime = now; return }
        let a = min(1, max(0, (now - segTime) / Self.samplePeriod))
        let current = segStart! + (segTarget - segStart!) * a
        segStart = current
        segTarget = v
        segTime = now
    }

    @discardableResult
    func openDevice() -> Bool {
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            statusText = r == kIOReturnSuccess ? "센서 없음" : String(format: "센서 열기 실패 (0x%08x)", r)
            lock.withLock { device = nil }
            return false
        }
        let preferred = set.first { (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) == 0x8104 } ?? set.first!
        let o = IOHIDDeviceOpen(preferred, IOOptionBits(kIOHIDOptionsTypeNone))
        // Some environments refuse open() but still allow feature-report reads; try reading either way.
        lock.withLock { device = preferred }
        if o != kIOReturnSuccess, readOnce() == nil {
            statusText = String(format: "센서 접근 거부 (0x%08x)", o)
            lock.withLock { device = nil }
            return false
        }
        if let a = readOnce() {
            lock.withLock { _angle = a; _timestamp = CACurrentMediaTime(); segStart = nil; pushSample(a, at: _timestamp) }
            statusText = "사용 가능"
            return true
        }
        statusText = "센서 응답 없음"
        lock.withLock { device = nil }
        return false
    }

    /// One synchronous read (about 0.6 ms on Apple silicon).
    func readOnce() -> Double? {
        guard let d = lock.withLock({ device }) else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(buf.count)
        let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard r == kIOReturnSuccess, len >= 3 else { return nil }
        let v = Double(Int(buf[1]) | (Int(buf[2]) << 8))
        guard v >= 0, v <= 200 else { return nil }
        return v
    }

    /// Polls in the background at the given rate (0 stops polling).
    /// Jump the smoothed estimate to the current raw value (e.g. after wake).
    func resetSmoothing() {
        lock.withLock { if let a = _angle { segStart = nil; pushSample(a, at: CACurrentMediaTime()) } }
    }

    func setPollingRate(_ hz: Double) {
        guard hz != currentHz else { return }
        currentHz = hz
        timer?.cancel(); timer = nil
        guard hz > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / hz
        // Generous leeway when slow so the system can coalesce wake-ups.
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * (hz <= 5 ? 400 : 100))))
        var failures = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let a = self.readOnce() {
                failures = 0
                let now = CACurrentMediaTime()
                let changed = self.lock.withLock { a != self._angle }
                self.lock.withLock {
                    if a != self._angle {
                        self.pushSample(a, at: now)
                        EventLog.shared.log("angle", a)
                    }
                    self._angle = a; self._timestamp = now
                }
                if changed { self.onChange?(a) }
            } else {
                failures += 1
                if failures == 1 { EventLog.shared.log("sensorReadFailed") }
                if failures == 30 { _ = self.openDevice() }   // e.g. after sleep/wake
            }
        }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }
}
