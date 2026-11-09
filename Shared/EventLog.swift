import Foundation
import QuartzCore

/// Lightweight CSV event log for tuning on real hardware (angle samples, sleep/wake, capture timing).
/// Written to Application Support/LidBlur/events.csv (inside the sandbox container for the App Store build).
final class EventLog {
    static let shared = EventLog()
    private let queue = DispatchQueue(label: "studio.xtower.lidblur.log")
    private var handle: FileHandle?
    private(set) var url: URL?
    #if DEBUG
    private static let defaultEnabled = true
    #else
    private static let defaultEnabled = false
    #endif
    var enabled: Bool = UserDefaults.standard.object(forKey: "eventLog") as? Bool ?? EventLog.defaultEnabled {
        didSet { UserDefaults.standard.set(enabled, forKey: "eventLog") }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LidBlur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("events.csv")
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: "wall,media,event,value1,value2\n".data(using: .utf8))
        }
        url = u
        handle = try? FileHandle(forWritingTo: u)
        handle?.seekToEndOfFile()
    }

    func log(_ event: String, _ v1: Double? = nil, _ v2: Double? = nil) {
        guard enabled else { return }
        let line = String(format: "%.3f,%.4f,%@,%@,%@\n", Date().timeIntervalSince1970, CACurrentMediaTime(), event,
                          v1.map { String(format: "%.4f", $0) } ?? "", v2.map { String(format: "%.4f", $0) } ?? "")
        queue.async { [handle] in handle?.write(line.data(using: .utf8)!) }
    }
}
