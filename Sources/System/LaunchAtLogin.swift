import Foundation
import ServiceManagement

/// 开机自启：把 `.app` 自己注册成登录项。
///
/// 用 `SMAppService.mainApp`，不再往 `~/Library/LaunchAgents` 里塞 plist ——
/// 系统设置的「登录项」里能看见它、能关掉它，用户的关闭意愿也会被系统记住
/// （被用户关掉后 `status` 是 `.requiresApproval`，此时再 `register()` 也不会真的生效，
/// 只能引导他去系统设置里打开）。
///
/// **注册的是当前这个 bundle 的路径**。`build.sh` 每次都 `rm -rf` 重建 `build/HourGlow.app`，
/// 重建之后原来的登录项就指向了一个不存在的 bundle（`status` 变成 `.notFound`）。
/// 所以自用请把 app 拷进 `/Applications` 再开自启，别对着 `build/` 里那份开。
enum LaunchAtLogin {

    /// 裸二进制（`hourglow-cli`、`panelshot`）没有可注册的 bundle，这些场合整栏都不该出现。
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// 用户在系统设置里手动关过 —— 此时 `register()` 不会报错也不会生效，只能引导过去。
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

    /// 给 UI 和 CLI 共用的一句话状态。
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
