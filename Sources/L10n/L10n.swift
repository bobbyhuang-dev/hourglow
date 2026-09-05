import Foundation

/// The string catalog for one language.
///
/// Add `Catalogs/<code>.swift` and one entry in `L10n.catalogs` to add a language.
/// `build/l10ncheck` verifies completeness; no other language list needs updating.
struct StringCatalog {
    /// BCP-47 code used by `HOURGLOW_LANG`, `hourglow-cli language`, and Settings.
    let code: String
    /// The language's native name, always displayed in its own language so users
    /// can find it even when they cannot read the current interface.
    let name: String
    /// Which city and region name column to display; see `System/Cities.swift`.
    /// Languages using Latin script can use `.latin` without translating every place.
    let placeNames: PlaceNames
    let strings: [String: String]
}

enum PlaceNames: Hashable {
    /// Chinese names.
    case chinese
    /// Latin-script names (Shenzhen, Guangdong).
    case latin
}

/// Shared interface strings.
///
/// These catalogs are compiled in rather than loaded from `.lproj/Localizable.strings`
/// because the project builds without Xcode and includes unbundled CLI/check binaries.
/// `Bundle.main.localizedString` would return raw keys there, preventing the checks
/// from catching missing translations. Every product uses the same compiled catalogs.
enum L10n {

    /// Add languages here. Order affects the Settings picker, not language resolution.
    static let catalogs: [StringCatalog] = [.zhHans, .en]

    /// Write new strings in this language first; it defines completeness and missing-key fallback.
    static let sourceCode = "en"

    /// Used when no available language matches the system, independently of the source language.
    static let defaultCode = "en"

    /// `AppModel` rebuilds the panel tree when the language changes.
    static let didChangeNotification = Notification.Name("dev.bobbyhuang.hourglow.languageDidChange")

    // MARK: - Current language

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

    // MARK: - Preferences

    /// `.system` follows the user's system language preferences.
    enum Preference: Hashable {
        case system
        case fixed(String)

        var code: String? {
            if case .fixed(let code) = self { return code }
            return nil
        }
    }

    /// The app and CLI share one preference domain.
    ///
    /// The app's standard domain already uses its bundle ID; an unbundled CLI must
    /// name that domain explicitly. Passing the current bundle ID to
    /// `UserDefaults(suiteName:)` is undefined behavior, so keep the paths separate.
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

    /// Save, invalidate, then notify: observers immediately read the new language.
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

    /// Call after changing `HOURGLOW_LANG`; the environment is read only during resolution.
    static func invalidate() {
        stateLock.lock()
        cached = nil
        stateLock.unlock()
    }

    // MARK: - Language resolution

    /// Priority: `HOURGLOW_LANG` > stored preference > system languages > `defaultCode`.
    ///
    /// Injectable inputs let `l10ncheck` exercise resolution without changing the environment.
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

    /// Use `getenv`: `ProcessInfo.environment` is a startup snapshot and does not reflect
    /// the checks' later `setenv` calls. `Store.directoryURL` follows the same rule.
    static func environmentCode() -> String? {
        guard let raw = getenv("HOURGLOW_LANG"),
              let value = String(validatingCString: raw), !value.isEmpty else { return nil }
        return value
    }

    /// Pure matching from system language preferences to available catalogs.
    ///
    /// Try each preference in order: exact match, language + script, then language only.
    /// Thus `zh-Hans-CN` matches `zh-Hans`, and `en-GB` matches `en`.
    /// Letting `zh-Hant` match `zh-Hans` is intentional: Simplified Chinese is closer
    /// to a Traditional Chinese reader's preference than falling back to English.
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

    /// In `zh-Hans-CN`, `zh` is the language and `hans` the script. Four-letter subtags
    /// denote scripts; two-letter or three-digit subtags denote regions (`en-GB`, `es-419`).
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

    // MARK: - String lookup

    /// Fall back to the source language, then the key itself: a visible `slot.apply`
    /// is easier to spot than blank text. `l10ncheck` guards against missing keys.
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

    /// Count-dependent strings.
    ///
    /// Languages such as Chinese need only the base key. Languages such as English
    /// can add `key.one` for a count of 1; the singular form is optional.
    static func t(count: Int, _ key: String, _ arguments: CVarArg...) -> String {
        let current = catalog
        // Choose the language before the plural form: a missing Chinese singular
        // must not override an existing Chinese base string with English text.
        let selected = current.strings[key] != nil
            ? current
            : catalogs.first { $0.code == sourceCode } ?? current
        let format = (count == 1 ? selected.strings["\(key).one"] : nil)
            ?? selected.strings[key] ?? key
        return String(format: format, arguments: arguments)
    }
}
