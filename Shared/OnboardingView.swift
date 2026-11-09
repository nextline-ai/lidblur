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
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LidBlur 시작하기").font(.title2.weight(.semibold))
                    Text("덮개를 닫고 열 때, 화면이 접히는 패널처럼 기울며 흐려지고 어두워집니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                StepRow(number: 1, title: "화면 기록 권한",
                        detail: permission
                            ? "허용됨. 화면 내용을 흐리게 그릴 수 있습니다."
                            : "효과를 그리려면 화면을 읽어야 합니다. 화면 내용은 기기 밖으로 나가지 않습니다.",
                        done: permission) {
                    if !permission {
                        HStack {
                            Button(requested ? "시스템 설정 열기" : "권한 허용하기") {
                                if requested {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                } else {
                                    requested = true
                                    engine.requestScreenPermission()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if requested {
                                Button("LidBlur 다시 시작") { Relaunch.now() }
                            }
                        }
                        if requested {
                            Text("설정에서 LidBlur를 켠 뒤, 바뀐 권한을 적용하려면 다시 시작이 필요할 수 있습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().padding(.leading, 44)
                StepRow(number: 2, title: "덮개 각도 센서",
                        detail: engine.sensor.isAvailable
                            ? "사용 가능. 덮개 각도를 실시간으로 따라갑니다."
                            : "이 Mac에서는 찾지 못했습니다. 덮개를 열 때 시간 기반 애니메이션으로 대신합니다.",
                        done: engine.sensor.isAvailable, optional: !engine.sensor.isAvailable) { EmptyView() }
                Divider().padding(.leading, 44)
                StepRow(number: 3, title: "로그인 시 자동 실행", detail: "Mac을 켤 때마다 메뉴 막대에 자동으로 나타납니다.",
                        done: launchAtLogin, optional: true) {
                    Toggle("사용", isOn: $launchAtLogin)
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
                Text("설정은 메뉴 막대의 LidBlur 아이콘에서 언제든 바꿀 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(permission ? "시작하기" : "나중에") { onDone() }
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
    let title: String
    let detail: String
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
