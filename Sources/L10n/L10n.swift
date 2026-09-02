import Foundation

/// 一门语言的文案表。
///
/// 加一门语言 = 新建一个 `Catalogs/<code>.swift` + 在 `L10n.catalogs` 里加一行，
/// 别的地方都不用动。完整性由 `build/l10ncheck` 守着。
struct StringCatalog {
    /// BCP-47 语言代码。`HOURGLOW_LANG`、`hourglow-cli language` 与设置页认的都是它。
    let code: String
    /// 语言自己的名字（「简体中文」「English」）。选择器里永远按母语显示 ——
    /// 看不懂当前界面语言的人，才最需要在列表里认出自己那一行。
    let name: String
    /// 城市与行政区的展示名从哪一列取，见 `System/Cities.swift`。
    /// 翻译一门语言不必逐个翻译地名：拉丁字母的语言写 `.latin` 就够了。
    let placeNames: PlaceNames
    let strings: [String: String]
}

enum PlaceNames: Hashable {
    /// 中文名（深圳、广东）。
    case chinese
    /// 拉丁字母名（Shenzhen、Guangdong）。
    case latin
}

/// 界面文案。
///
/// **为什么不是 `.lproj/Localizable.strings`**：这个仓库不走 Xcode 工程，产物里有一堆
/// 没有 bundle 的裸二进制（`hourglow-cli`、`panelshot`、七个靶子），
/// `Bundle.main.localizedString` 在它们身上只会把 key 原样退回来，靶子也就查不出
/// 漏翻。文案编进二进制里，三种产物拿到的是同一份，加一门语言只是加一个 Swift 文件。
enum L10n {

    /// 加一门语言，改这一行。顺序不影响挑选，只影响设置页里的排列。
    static let catalogs: [StringCatalog] = [.zhHans, .en]

    /// 文案的原文语言：新文案先写它，靶子按它对完整性，缺词时也退回它。
    static let sourceCode = "zh-Hans"

    /// 系统语言一门都对不上时用的语言（法语系统 → 英文，而不是中文）。
    static let defaultCode = "en"

    /// 语言变了。`AppModel` 收到之后让面板整棵重建。
    static let didChangeNotification = Notification.Name("dev.bobbyhuang.hourglow.languageDidChange")

    // MARK: - 当前语言

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cached: StringCatalog?

    static var catalog: StringCatalog {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let cached { return cached }
        let value = resolve(preference: storedPreference)
        cached = value
        return value
    }

    static var code: String { catalog.code }
    static var placeNames: PlaceNames { catalog.placeNames }

    // MARK: - 偏好

    /// 用户选的语言。`.system` 表示跟随系统。
    enum Preference: Hashable {
        case system
        case fixed(String)

        var code: String? {
            if case .fixed(let code) = self { return code }
            return nil
        }
    }

    /// app 与 CLI 共用同一份偏好。
    ///
    /// app 里 `UserDefaults.standard` 就是 bundle ID 那个域；CLI 是裸二进制，
    /// 得显式指名。把自己的 bundle ID 当 suite 传给 `UserDefaults(suiteName:)`
    /// 是未定义行为，所以分两条路。
    static let defaultsSuite = "dev.bobbyhuang.hourglow"
    private static let defaultsKey = "language"

    private static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == defaultsSuite { return .standard }
        return UserDefaults(suiteName: defaultsSuite) ?? .standard
    }()

    static var storedPreference: Preference {
        guard let raw = defaults.string(forKey: defaultsKey), !raw.isEmpty else { return .system }
        return .fixed(raw)
    }

    /// 立即生效。写盘、清缓存、广播 —— 顺序不能反，收到广播的人会立刻来读新语言。
    static func setPreference(_ preference: Preference) {
        switch preference {
        case .system: defaults.removeObject(forKey: defaultsKey)
        case .fixed(let code): defaults.set(code, forKey: defaultsKey)
        }
        stateLock.lock()
        cached = nil
        stateLock.unlock()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// 重新挑一次语言。改过 `HOURGLOW_LANG` 之后要调它 —— 环境变量只在挑语言那一刻读。
    static func invalidate() {
        stateLock.lock()
        cached = nil
        stateLock.unlock()
    }

    // MARK: - 挑一门语言

    /// 优先级：`HOURGLOW_LANG` > 用户选的 > 系统语言 > `defaultCode`。
    ///
    /// 参数都能注入，`l10ncheck` 直接按表断言，不必真去改环境。
    static func resolve(preference: Preference,
                        environment: String? = environmentCode(),
                        system: [String] = Locale.preferredLanguages) -> StringCatalog {
        let wanted = [environment, preference.code].compactMap { $0 }
        for code in wanted {
            if let hit = match(preferred: [code], available: catalogs.map(\.code)) {
                return catalogs.first { $0.code == hit } ?? fallbackCatalog
            }
        }
        if let hit = match(preferred: system, available: catalogs.map(\.code)) {
            return catalogs.first { $0.code == hit } ?? fallbackCatalog
        }
        return fallbackCatalog
    }

    private static var fallbackCatalog: StringCatalog {
        catalogs.first { $0.code == defaultCode } ?? catalogs[0]
    }

    /// 用 `getenv` 而不是 `ProcessInfo.environment`：后者是进程启动时的快照，
    /// 靶子里 `setenv` 之后再问它拿到的还是旧值（`Store.directoryURL` 同理）。
    static func environmentCode() -> String? {
        guard let raw = getenv("HOURGLOW_LANG"),
              let value = String(validatingCString: raw), !value.isEmpty else { return nil }
        return value
    }

    /// 系统语言 → 我们有的语言。纯函数，靶子按表断言。
    ///
    /// 逐条看用户的偏好顺序，每一条依次试三档：完全一致 → 语言+文字一致
    /// （`zh-Hans-CN` → `zh-Hans`）→ 只有语言一致（`en-GB` → `en`，
    /// `zh-Hant` → `zh-Hans`）。最后一档是有意为之：繁体读者看简体，
    /// 总比被扔去英文近。
    static func match(preferred: [String], available: [String]) -> String? {
        let pool = available.map { (code: $0, tags: Subtags($0)) }
        for want in preferred.map(Subtags.init) {
            if let hit = pool.first(where: { $0.tags == want }) { return hit.code }
            if let script = want.script,
               let hit = pool.first(where: { $0.tags.language == want.language
                                             && $0.tags.script == script }) { return hit.code }
            if let hit = pool.first(where: { $0.tags.language == want.language }) { return hit.code }
        }
        return nil
    }

    /// `zh-Hans-CN` → 语言 zh、文字 hans。四个字母的那一段才是文字，
    /// 两个字母/三个数字的是地区（`en-GB`、`es-419`），不能混。
    struct Subtags: Equatable {
        var language: String
        var script: String?

        init(_ raw: String) {
            let parts = raw.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").map { $0.lowercased() }
            language = parts.first ?? ""
            script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        }
    }

    // MARK: - 查表

    /// 缺词时退回原文语言，再缺就把 key 本身还回去 —— 界面上露出一个
    /// `slot.apply` 比露出一片空白更容易被发现。`l10ncheck` 保证正常情况下走不到这儿。
    static func value(forKey key: String) -> String? {
        let current = catalog
        if let hit = current.strings[key] { return hit }
        guard current.code != sourceCode else { return nil }
        return catalogs.first { $0.code == sourceCode }?.strings[key]
    }

    static func t(_ key: String) -> String {
        value(forKey: key) ?? key
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    /// 带数量的文案。
    ///
    /// 中文没有单复数，只写 `key` 就够；英文这类语言另外补一条 `key.one`，
    /// 数量为 1 时自动挑它。没有 `key.one` 就用 `key`，所以补不补是可选的。
    static func t(count: Int, _ key: String, _ arguments: CVarArg...) -> String {
        let singular = "\(key).one"
        let chosen = (count == 1 && value(forKey: singular) != nil) ? singular : key
        return String(format: t(chosen), arguments: arguments)
    }
}
