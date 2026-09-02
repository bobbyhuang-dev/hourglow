import Foundation

/// 新手指引的步骤定义与「谁该看到它」这条规则。
///
/// 纯 Foundation，不碰 UI，也不碰 `Store` —— 这样 `appcheck` 能把这个文件单独编进去，
/// 把规则写成离线断言。窗口与版式在 `UI/OnboardingView.swift`、`UI/OnboardingWindow.swift`。
///
/// 文案也放在这里而不是散在视图里：每一步「说什么」是内容，不是版式，
/// 靶子还能顺手守住「没有哪一步是空的」。
enum OnboardingStep: Int, CaseIterable, Identifiable, Equatable {
    /// 它住在菜单栏 —— 一个 `LSUIElement` app 最容易被找不到的就是入口本身。
    case welcome
    /// 位置：日出日落的前提，也是唯一要用户点「允许」的系统权限。
    case place
    /// 常驻：开机自启、菜单栏许可、别在「下载」文件夹里跑。
    case resident
    /// 时间轴怎么改。
    case timeline
    case done

    var id: Int { rawValue }

    /// 每一步的 key 前缀。文案在语言表里（`Sources/L10n/Catalogs/`），
    /// 不散在视图中 —— 说什么是内容，靶子要能查。
    var slug: String {
        switch self {
        case .welcome:  return "welcome"
        case .place:    return "place"
        case .resident: return "resident"
        case .timeline: return "timeline"
        case .done:     return "done"
        }
    }

    var title: String { L10n.t("guide.\(slug).title") }

    /// 标题下面那两行：这一步在干什么、为什么要这么做。
    var summary: String { L10n.t("guide.\(slug).summary") }
}

/// 走到第几步。纯状态机，越界由它自己兜住，视图不必再判一次。
struct OnboardingFlow: Equatable {
    static let steps = OnboardingStep.allCases

    private(set) var index = 0

    var step: OnboardingStep { Self.steps[index] }
    var count: Int { Self.steps.count }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == count - 1 }

    /// 「第 2 步 / 共 5 步」。人从 1 数起。
    var caption: String { L10n.t("guide.step", index + 1, count) }

    mutating func advance() {
        guard !isLast else { return }
        index += 1
    }

    mutating func back() {
        guard !isFirst else { return }
        index -= 1
    }

    mutating func jump(to step: OnboardingStep) {
        guard let target = Self.steps.firstIndex(of: step) else { return }
        index = target
    }
}

enum Onboarding {

    /// 指引版本。步骤有实质变化时 +1，看过旧版的人会被再请来一次；只改错别字不要动它。
    static let version = 1

    private static let seenKey = "onboarding.seenVersion"

    // MARK: - 规则

    /// 该不该自动弹出来。纯函数，`appcheck` 直接按这张表断言。
    ///
    /// - 从没看过的人：**只有真·新安装**才自动弹。1.2 升上来的老用户配置早就在了，
    ///   一次自动更新之后突然弹一扇窗解释「什么是时间轴」是打扰 ——
    ///   他们从 ⋯ 菜单里的「新手指引」自己进来。
    /// - 看过旧版指引的人：内容有实质更新（`version` 变大）时再弹一次。
    static func shouldPresent(seenVersion: Int?, isFirstRun: Bool) -> Bool {
        guard let seenVersion else { return isFirstRun }
        return seenVersion < version
    }

    // MARK: - 是不是全新安装

    /// `nil` 表示还没人问过。
    @MainActor private static var freshInstall: Bool?

    /// 记下「这次启动之前配置文件在不在」。
    ///
    /// **必须赶在任何人调 `Store.load()` 之前**：那个调用会顺手把 Tahoe 预设写下去，
    /// 之后再看文件在不在就永远是「在」。第一次调用说了算，后来的调用不会翻案 ——
    /// `AppModel.init` 与 `AppDelegate` 都会踩一脚，谁先都对。
    @MainActor
    static func captureFirstRun(configExists: Bool) {
        guard freshInstall == nil else { return }
        freshInstall = !configExists
    }

    @MainActor
    static var isFirstRun: Bool { freshInstall ?? false }

    /// `--guide show` 用：这一次启动无论如何都弹，方便改完版式直接看效果。
    @MainActor static var forcedByFlag = false

    @MainActor
    static var shouldPresentOnLaunch: Bool {
        forcedByFlag || shouldPresent(seenVersion: seenVersion, isFirstRun: isFirstRun)
    }

    // MARK: - 记住看过了

    /// 看过的指引版本。没看过是 `nil`。
    ///
    /// 存 `UserDefaults` 而不是 `schedule.json`：那份配置是给用户手改的调度表，
    /// 「我看过指引了」不属于调度。代价是 `HOURGLOW_HOME` 改道也带不走它，
    /// 所以留了 `--guide reset`。
    static var seenVersion: Int? {
        get { UserDefaults.standard.object(forKey: seenKey) as? Int }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: seenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: seenKey)
            }
        }
    }

    /// 关窗就算看过 —— 跳过、走完、点红灯都一样。否则它每次启动都来，比没有还糟。
    static func markSeen() { seenVersion = version }

    static func reset() { seenVersion = nil }

    /// `--guide status` 打印的那一行。
    @MainActor
    static func describe() -> String {
        let seen = seenVersion.map { L10n.t("guide.status.seen", $0) }
            ?? L10n.t("guide.status.unseen")
        let verdict = L10n.t(shouldPresentOnLaunch ? "guide.status.willShow"
                                                   : "guide.status.wontShow")
        return L10n.t("guide.status", seen, version, verdict)
    }
}
