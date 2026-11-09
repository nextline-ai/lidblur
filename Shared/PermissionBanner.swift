import SwiftUI

struct PermissionBanner: View {
    @ObservedObject var engine: EffectEngine
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("화면을 흐리게 하려면 '화면 및 시스템 오디오 기록' 권한이 필요합니다. 허용한 뒤 앱을 다시 실행하세요.")
                .font(.callout)
            Spacer()
            Button("권한 요청") { engine.requestScreenPermission() }
            Button("설정 열기") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}
