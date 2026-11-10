import SwiftUI

struct PermissionBanner: View {
    @ObservedObject var engine: EffectEngine
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("To blur the screen, LidBlur needs the Screen & System Audio Recording permission. Allow it, then relaunch the app.")
                .font(.callout)
            Spacer()
            Button("Request Permission") { engine.requestScreenPermission() }
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}
