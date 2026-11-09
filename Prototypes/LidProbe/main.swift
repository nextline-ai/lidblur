// LidProbe — reads the MacBook lid-angle HID sensor (usage page 0x20 Sensor, usage 0x8A).
// Prints raw feature-report bytes, decoded angle, and sample timing.
import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
    kIOHIDVendorIDKey: 0x05AC,
    kIOHIDPrimaryUsagePageKey: 0x0020,
    kIOHIDPrimaryUsageKey: 0x008A,
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen:", String(format: "0x%08x", openRes))
guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("NO lid angle device found"); exit(1)
}
for d in set {
    let p = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? -1
    let rs = IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? -1
    print("device: \(p) pid=0x\(String(pid, radix: 16)) maxFeature=\(rs)")
}
let dev = set.first!
let o = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDDeviceOpen:", String(format: "0x%08x", o))

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "5") ?? 5
let interval = Double(CommandLine.arguments.dropFirst(2).first ?? "0.01") ?? 0.01
let start = Date()
var last: Int = -1
var n = 0, changes = 0
var lastPrint = Date.distantPast
var minDt = 1e9, maxDt = 0.0, sumDt = 0.0
while Date().timeIntervalSince(start) < seconds {
    var buf = [UInt8](repeating: 0, count: 8)
    var len: CFIndex = buf.count
    let t0 = Date()
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &buf, &len)
    let dt = Date().timeIntervalSince(t0)
    minDt = min(minDt, dt); maxDt = max(maxDt, dt); sumDt += dt; n += 1
    if r != kIOReturnSuccess { print("GetReport err", String(format: "0x%08x", r)); break }
    let angle = Int(buf[1]) | (Int(buf[2]) << 8)
    if angle != last { changes += 1 }
    if angle != last || Date().timeIntervalSince(lastPrint) > 1 {
        let bytes = buf[0..<len].map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "t=%6.3f len=%d [%@] angle=%d", Date().timeIntervalSince(start), len, bytes, angle))
        lastPrint = Date(); last = angle
    }
    Thread.sleep(forTimeInterval: interval)
}
print(String(format: "reads=%d changes=%d getReport min=%.2fms avg=%.2fms max=%.2fms", n, changes, minDt*1000, sumDt/Double(n)*1000, maxDt*1000))
