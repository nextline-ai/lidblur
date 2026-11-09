import Foundation
import AppKit

#if DEBUG
/// Automation hook for testing: `work.nextline.lidblur.debug` distributed notification with
/// userInfo ["progress": "0.7"] or ["mode": "manual"|"sensor"].
@MainActor
enum DebugHooks {
    private static var token: NSObjectProtocol?
    static weak var current: EffectEngine?
    /// Installs the hook for the most recently created engine.
    static func installLazily() { if let e = current { install(engine: e) } }
    static func install(engine: EffectEngine) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("work.nextline.lidblur.debug"), object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                if let p = (n.userInfo?["progress"] as? String).flatMap(Double.init) { engine.inputMode = .manual; engine.manualProgress = p }
                if let m = (n.userInfo?["mode"] as? String).flatMap(EffectEngine.InputMode.init(rawValue:)) { engine.inputMode = m }
                if let a = n.userInfo?["angle"] as? String {
                    engine.debugAngle = Double(a)   // "none" clears it
                    engine.evaluate()
                }
                if let path = n.userInfo?["snapshot"] as? String {
                    let status = engine.debugSnapshot(to: path)
                    try? status.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
#endif
