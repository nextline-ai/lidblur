import SwiftUI
import ServiceManagement

/// LidBlur — menu bar app. Follows the lid angle and blurs/shades the built-in display like a folding panel.
@main
struct LidBlurApp: App {
    @StateObject private var engine = EffectEngine(defaultMode: .sensor)

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine)
        } label: {
            Image(systemName: engine.overlayVisible ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
        }
        .menuBarExtraStyle(.window)

        Window("LidBlur 튜닝", id: "tuning") {
            VStack(spacing: 0) {
                if !engine.screenPermission { PermissionBanner(engine: engine) }
                TabView {
                    TuningView(engine: engine).tabItem { Text("튜닝") }
                    CompareView(engine: engine).tabItem { Text("이미지 비교") }
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
            if !engine.screenPermission { PermissionBanner(engine: engine) }
            Toggle("효과 켜기", isOn: $engine.enabled)
            Group {
                if engine.sensor.isAvailable {
                    Text(String(format: "덮개 각도 %@ · 진행도 %.2f", engine.uiAngle.map { String(format: "%.0f°", $0) } ?? "—", engine.uiProgress))
                } else {
                    Text("덮개 각도 센서를 찾지 못했습니다 (\(engine.sensorStatus)). 덮개를 열 때 시간 기반 애니메이션으로 대신합니다.")
                }
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
                Button("튜닝 / 비교…") { openWindow(id: "tuning"); NSApp.activate() }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
