import Foundation
import ServiceManagement

/// Launch at login: registers the app itself as a login item.
///
/// Uses `SMAppService.mainApp` instead of installing a plist in `~/Library/LaunchAgents`.
/// Users can see and disable it in System Settings > Login Items, and the system remembers that choice.
/// Once disabled, status becomes `.requiresApproval`; another `register()` does not enable it.
/// The user must be directed to System Settings to approve it.
///
/// **Registration records this bundle's current path.** `build.sh` removes and recreates `build/HourGlow.app`,
/// leaving the old login item pointing to a nonexistent bundle (`status` becomes `.notFound`).
/// Copy the app to `/Applications` before enabling launch at login; do not register the build directory copy.
enum LaunchAtLogin {

    /// Bare binaries (`hourglow-cli`, `panelshot`) have no registrable bundle; hide this entire section for them.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Disabled by the user in System Settings: register() silently has no effect, so direct the user there.
    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// A one-line status shared by the UI and CLI.
    static func describe(_ status: SMAppService.Status = LaunchAtLogin.status) -> String {
        switch status {
        case .enabled:          return L10n.t("launchAtLogin.enabled")
        case .notRegistered:    return L10n.t("launchAtLogin.off")
        case .requiresApproval: return L10n.t("launchAtLogin.requiresApproval")
        case .notFound:         return L10n.t("launchAtLogin.notFound")
        @unknown default:       return L10n.t("launchAtLogin.unknown", status.rawValue)
        }
    }
}
