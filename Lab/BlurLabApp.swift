import SwiftUI

/// BlurLab — standalone prototype of the renderer: live screen capture + overlay on the built-in display,
/// a debug progress slider, the tuning panel and a still-image comparison view.
@main
struct BlurLabApp: App {
    @StateObject private var engine = EffectEngine(defaultMode: .manual)

    var body: some Scene {
        WindowGroup("BlurLab") {
            LabRootView(engine: engine)
                .frame(minWidth: 760, minHeight: 640)
                .onAppear { DebugHooks.install(engine: engine) }
        }
    }
}

struct LabRootView: View {
    @ObservedObject var engine: EffectEngine
    var body: some View {
        VStack(spacing: 0) {
            if !engine.screenPermission {
                PermissionBanner(engine: engine)
            }
            TabView {
                TuningView(engine: engine).tabItem { Text("튜닝") }
                CompareView(engine: engine).tabItem { Text("이미지 비교") }
            }
        }
    }
}

/// Automation hook for testing: `studio.xtower.lidblur.debug` distributed notification with
/// userInfo ["progress": "0.7"] or ["mode": "manual"|"sensor"].
@MainActor
enum DebugHooks {
    private static var token: NSObjectProtocol?
    static func install(engine: EffectEngine) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("studio.xtower.lidblur.debug"), object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                if let p = (n.userInfo?["progress"] as? String).flatMap(Double.init) { engine.inputMode = .manual; engine.manualProgress = p }
                if let m = (n.userInfo?["mode"] as? String).flatMap(EffectEngine.InputMode.init(rawValue:)) { engine.inputMode = m }
                if let path = n.userInfo?["snapshot"] as? String {
                    let status = engine.debugSnapshot(to: path)
                    try? status.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
