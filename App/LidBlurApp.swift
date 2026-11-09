import SwiftUI
import ServiceManagement

/// LidBlur — menu bar app. Follows the lid angle and blurs/shades the built-in display like a folding panel.
@main
struct LidBlurApp: App {
    @StateObject private var engine = EffectEngine(defaultMode: .sensor)

    init() {
        DispatchQueue.main.async {
            #if DEBUG
            // Install the automation hook even if the menu is never opened.
            DebugHooks.installLazily()
            #endif
            if let e = EffectEngine.shared { OnboardingPresenter.showIfNeeded(engine: e) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine)
                #if DEBUG
                .onAppear { DebugHooks.install(engine: engine) }
                #endif
        } label: {
            MenuIcon(state: engine.iconState)
        }
        .menuBarExtraStyle(.window)

        Window("LidBlur", id: "tuning") {
            VStack(spacing: 0) {
                if !engine.screenPermission { PermissionBanner(engine: engine) }
                TabView {
                    TuningView(engine: engine).tabItem { Text("튜닝") }
                    AboutView().tabItem { Text("About") }
                }
            }
            .frame(minWidth: 760, minHeight: 640)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var engine: EffectEngine
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LidBlur").font(.headline)
            if !engine.screenPermission {
                PermissionBanner(engine: engine)
                Button("권한 설정 안내 열기") { OnboardingPresenter.show(engine: engine) }
            }
            Toggle("효과 켜기", isOn: $engine.enabled)
            Group {
                MenuStatusText(engine: engine, status: engine.status)
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("센서가 없을 때 열림 애니메이션", isOn: $engine.fallbackOnWake)
            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Divider()
            HStack {
                Button("튜닝 / About…") { openWindow(id: "tuning"); NSApp.activate() }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct MenuIcon: View {
    @ObservedObject var state: IconState
    var body: some View { Image(systemName: state.active ? "laptopcomputer.and.arrow.down" : "laptopcomputer") }
}

struct MenuStatusText: View {
    let engine: EffectEngine
    @ObservedObject var status: LiveStatus
    var body: some View {
        if engine.sensor.isAvailable {
            Text(String(format: "덮개 각도 %@ · 진행도 %.2f", status.angle.map { String(format: "%.0f°", $0) } ?? "—", status.progress))
        } else {
            Text("덮개 각도 센서를 찾지 못했습니다 (\(status.sensorStatus)). 덮개를 열 때 시간 기반 애니메이션으로 대신합니다.")
        }
    }
}
