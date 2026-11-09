import SwiftUI

/// About tab: app name, version, developer and distributor.
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "버전 \(v) (\(b))"
    }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LidBlur"
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                Text(appName).font(.title.weight(.semibold))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }

            Divider().frame(maxWidth: 420)

            HStack(alignment: .top, spacing: 56) {
                credit(role: "개발", image: "NextLineLogo", name: "NextLine", host: "nextline.work")
                credit(role: "배포", image: "DeaumLogo", name: "DEAUM", host: "deaum.org")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// All logos share one height so they read as equals.
    private let logoHeight: CGFloat = 44

    @ViewBuilder
    private func credit(role: String, image: String, name: String, host: String) -> some View {
        VStack(spacing: 12) {
            Text(role).font(.caption).foregroundStyle(.secondary)
            Image(image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: logoHeight)
                .accessibilityLabel(name)
            Link(host, destination: URL(string: "https://\(host)")!)
                .font(.callout)
        }
        .frame(minWidth: 180)
    }
}
