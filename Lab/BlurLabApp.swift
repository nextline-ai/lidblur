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
                #if DEBUG
                .onAppear { DebugHooks.install(engine: engine) }
                #endif
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

