import SwiftUI

/// About window content, laid out like About This Mac: icon, name, a label/value table, one button, links.
///
/// Fixed size (`About` metrics in `PanelKit`); `AboutWindow` hosts it. It reads only bundle and process
/// information, so panelshot can capture it without a configuration.
struct AboutView: View {
    static let repository = URL(string: "https://github.com/bobbyhuang-dev/hourglow")!

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: Self.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: About.iconSize, height: About.iconSize)
                .padding(.top, 28)

            Text("HourGlow")
                .font(About.Font.title)
                .padding(.top, 18)
            Text(L10n.t("about.tagline"))
                .font(About.Font.subtitle)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            // Label column right-aligned against the values, as in About This Mac.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                row(L10n.t("about.row.version"), Bundle.main.shortVersion)
                row(L10n.t("about.row.build"), Bundle.main.buildNumber)
                row(L10n.t("about.row.macos"), Self.systemVersion)
            }
            .padding(.top, 24)

            Button(L10n.t("about.repository")) {
                NSWorkspace.shared.open(Self.repository)
            }
            .controlSize(.large)
            .padding(.top, 24)

            Spacer(minLength: 0)

            // Markdown so translations can reorder the sentence around the link. `Text` opens the link itself.
            Text((try? AttributedString(markdown: L10n.t("about.project")))
                 ?? AttributedString(L10n.t("about.project")))
                .font(About.Font.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, About.inset)
        }
        .frame(width: About.width, height: About.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(About.Font.row.weight(.semibold))
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(About.Font.row)
                .foregroundStyle(.secondary)
        }
    }

    private static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The bundled icon. Bare binaries such as panelshot have no bundle, so look for the repository asset beside them
    /// rather than showing the generic application icon in screenshots.
    private static var icon: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApplication.shared.applicationIconImage }
        let repositoryIcon = Bundle.main.executableURL?
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/HourGlow.icns")
        if let repositoryIcon, let image = NSImage(contentsOf: repositoryIcon) { return image }
        return NSApplication.shared.applicationIconImage
    }
}

extension Bundle {
    /// Bare binaries such as panelshot have no Info.plist; show a placeholder rather than leaving the interface blank.
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
