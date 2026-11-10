import SwiftUI
import Combine
import ServiceManagement

/// First-run guide: explains what the app does and walks through the Screen Recording permission.
struct OnboardingView: View {
    @ObservedObject var engine: EffectEngine
    var onDone: () -> Void

    @State private var permission = CGPreflightScreenCaptureAccess()
    @State private var requested = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: AppIconImage.current)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get Started with LidBlur").font(.title2.weight(.semibold))
                    Text("When you close and open the lid, the screen tilts like a folding panel, blurring and dimming.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                StepRow(number: 1, title: "Screen Recording Permission",
                        detail: permission
                            ? "Allowed. LidBlur can draw the screen blurred."
                            : "To draw the effect, LidBlur needs to read the screen. Screen content never leaves your Mac.",
                        done: permission) {
                    if !permission {
                        HStack {
                            Button(requested ? LocalizedStringKey("Open System Settings") : LocalizedStringKey("Allow Permission")) {
                                if requested {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                } else {
                                    requested = true
                                    engine.requestScreenPermission()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if requested {
                                Button("Relaunch LidBlur") { Relaunch.now() }
                            }
                        }
                        if requested {
                            Text("After turning on LidBlur in Settings, you may need to relaunch it for the change to take effect.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().padding(.leading, 44)
                StepRow(number: 2, title: "Lid Angle Sensor",
                        detail: engine.sensor.isAvailable
                            ? "Available. LidBlur follows the lid angle in real time."
                            : "Not found on this Mac. A timed animation plays when you open the lid instead.",
                        done: engine.sensor.isAvailable, optional: !engine.sensor.isAvailable) { EmptyView() }
                Divider().padding(.leading, 44)
                StepRow(number: 3, title: "Launch at Login", detail: "Appears in the menu bar every time you start your Mac.",
                        done: launchAtLogin, optional: true) {
                    Toggle("On", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))

            HStack {
                Text("You can change settings anytime from the LidBlur icon in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(permission ? LocalizedStringKey("Get Started") : LocalizedStringKey("Later")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onReceive(tick) { _ in permission = CGPreflightScreenCaptureAccess() }
    }
}

private struct StepRow<Accessory: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let done: Bool
    var optional = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : (optional ? Color.secondary.opacity(0.35) : Color.accentColor))
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }
}

enum Relaunch {
    static func now() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Shows the onboarding window on first launch or while the permission is missing.
@MainActor
enum OnboardingPresenter {
    private static var window: NSWindow?
    private static let doneKey = "onboardingDone"

    static func showIfNeeded(engine: EffectEngine) {
        let done = UserDefaults.standard.bool(forKey: doneKey)
        if !done || !CGPreflightScreenCaptureAccess() { show(engine: engine) }
    }

    static func show(engine: EffectEngine) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let host = NSHostingController(rootView: OnboardingView(engine: engine) {
            UserDefaults.standard.set(true, forKey: doneKey)
            window?.close()
        })
        let w = NSWindow(contentViewController: host)
        w.title = "LidBlur"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
