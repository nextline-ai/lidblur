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
                    TuningView(engine: engine).tabItem { Text("Tuning") }
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
                Button("Open Permission Guide") { OnboardingPresenter.show(engine: engine) }
            }
            Toggle("Enable Effect", isOn: $engine.enabled)
            Group {
                MenuStatusText(engine: engine, status: engine.status)
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Opening animation when there's no sensor", isOn: $engine.fallbackOnWake)
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Divider()
            HStack {
                Button("Tuning / About…") { openWindow(id: "tuning"); NSApp.activate() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
            Text(String(format: NSLocalizedString("Lid angle %@ · progress %.2f", comment: "menu status"), status.angle.map { String(format: "%.0f°", $0) } ?? "—", status.progress))
        } else {
            Text("Couldn't find the lid angle sensor (\(status.sensorStatus)). A timed animation plays when you open the lid instead.")
        }
    }
}
