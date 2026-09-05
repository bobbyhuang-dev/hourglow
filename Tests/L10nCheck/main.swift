import Foundation

// Catalog checks: completeness, placeholders, language resolution, and source key usage.
//
//   ./build/l10ncheck [source directories to scan…]
//
// Without directories, only catalogs are checked. Passing `Sources` also checks literal
// `L10n.t("…")` keys: the compiler cannot catch a typo that exposes a raw key in the UI.

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

// MARK: - Placeholders

/// A `String(format:)` argument: `%1$@` → (1, "@"), `%.4f` → (implicit position, "f").
private struct Placeholder: Equatable, Comparable {
    var position: Int
    var kind: Character
    var explicit: Bool

    static func < (a: Placeholder, b: Placeholder) -> Bool { a.position < b.position }
}

/// Translations may reorder arguments (`%2$@ at %1$@`), so compare each argument's
/// position and type rather than its order in the sentence.
private func placeholders(in text: String) -> [Placeholder] {
    var result: [Placeholder] = []
    var implicit = 0
    let scalars = Array(text)
    var i = 0
    while i < scalars.count {
        guard scalars[i] == "%" else { i += 1; continue }
        i += 1
        guard i < scalars.count else { break }
        if scalars[i] == "%" { i += 1; continue }   // Escaped percent sign

        // Explicit position `n$`
        var position: Int?
        var digits = ""
        var lookahead = i
        while lookahead < scalars.count, scalars[lookahead].isNumber {
            digits.append(scalars[lookahead])
            lookahead += 1
        }
        if !digits.isEmpty, lookahead < scalars.count, scalars[lookahead] == "$" {
            position = Int(digits)
            i = lookahead + 1
        }

        // Flags, width, precision, and length modifiers
        while i < scalars.count, "-+ #0".contains(scalars[i]) { i += 1 }
        while i < scalars.count, scalars[i].isNumber { i += 1 }
        if i < scalars.count, scalars[i] == "." {
            i += 1
            while i < scalars.count, scalars[i].isNumber { i += 1 }
        }
        while i < scalars.count, "hlLqzjt".contains(scalars[i]) { i += 1 }

        guard i < scalars.count else { break }
        implicit += 1
        result.append(Placeholder(position: position ?? implicit,
                                  kind: scalars[i],
                                  explicit: position != nil))
        i += 1
    }
    return result.sorted()
}

private let singularSuffix = ".one"

private func baseKeys(_ catalog: StringCatalog) -> Set<String> {
    Set(catalog.strings.keys.filter { !$0.hasSuffix(singularSuffix) })
}

// MARK: - Catalog integrity

let source = L10n.catalogs.first { $0.code == L10n.sourceCode }
check(source != nil, "Source language \(L10n.sourceCode) is registered in L10n.catalogs")
check(L10n.catalogs.contains { $0.code == L10n.defaultCode },
      "Fallback language \(L10n.defaultCode) is registered in L10n.catalogs")
check(Set(L10n.catalogs.map(\.code)).count == L10n.catalogs.count, "Language codes are unique")
check(L10n.catalogs.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
      "Every language has a native name for the picker")

let reference = source ?? L10n.catalogs[0]
let referenceKeys = baseKeys(reference)

for catalog in L10n.catalogs {
    let keys = baseKeys(catalog)

    let missing = referenceKeys.subtracting(keys).sorted()
    check(missing.isEmpty,
          "\(catalog.code) has every base key" + (missing.isEmpty ? "" : "; missing: \(missing.joined(separator: ", "))"))

    let extra = keys.subtracting(referenceKeys).sorted()
    check(extra.isEmpty,
          "\(catalog.code) has no base keys absent from the source"
          + (extra.isEmpty ? "" : "; extra: \(extra.joined(separator: ", "))"))

    let empty = catalog.strings.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .keys.sorted()
    check(empty.isEmpty,
          "\(catalog.code) has no empty strings" + (empty.isEmpty ? "" : ": \(empty.joined(separator: ", "))"))

    // Singular forms are optional, but require an existing base key;
    // otherwise `t(count:)` can never select them.
    let orphans = catalog.strings.keys
        .filter { $0.hasSuffix(singularSuffix) }
        .filter { !keys.contains(String($0.dropLast(singularSuffix.count))) }
        .sorted()
    check(orphans.isEmpty,
          "\(catalog.code) singular forms have existing base keys"
          + (orphans.isEmpty ? "" : "; orphaned: \(orphans.joined(separator: ", "))"))

    // Mismatched placeholders can corrupt output or crash: the format determines argument types.
    var mismatched: [String] = []
    var mixed: [String] = []
    for (key, value) in catalog.strings {
        let base = key.hasSuffix(singularSuffix)
            ? String(key.dropLast(singularSuffix.count)) : key
        guard let original = reference.strings[base] else { continue }
        let want = placeholders(in: original)
        let got = placeholders(in: value)
        if want.map(\.kind) != got.map(\.kind) || want.count != got.count {
            mismatched.append(key)
        }
        // Mixing `%@` and `%1$@` in one format string is undefined behavior.
        if got.count > 1, got.contains(where: \.explicit), got.contains(where: { !$0.explicit }) {
            mixed.append(key)
        }
    }
    check(mismatched.isEmpty,
          "\(catalog.code) placeholders match the source argument types"
          + (mismatched.isEmpty ? "" : "; mismatched: \(mismatched.sorted().joined(separator: ", "))"))
    check(mixed.isEmpty,
          "\(catalog.code) does not mix positional and implicit placeholders"
          + (mixed.isEmpty ? "" : ": \(mixed.sorted().joined(separator: ", "))"))

    // Multiple arguments require positions so translations can safely reorder them.
    let unordered = catalog.strings
        .filter { placeholders(in: $0.value).count > 1
                  && !placeholders(in: $0.value).allSatisfy(\.explicit) }
        .keys.sorted()
    check(unordered.isEmpty,
          "\(catalog.code) multi-argument strings use %n$ positions"
          + (unordered.isEmpty ? "" : ": \(unordered.joined(separator: ", "))"))
}

// MARK: - Language resolution

let codes = L10n.catalogs.map(\.code)
check(L10n.match(preferred: ["zh-Hans"], available: codes) == "zh-Hans", "Exact language codes match")
check(L10n.match(preferred: ["zh-Hans-CN"], available: codes) == "zh-Hans",
      "Regional zh-Hans-CN matches zh-Hans")
check(L10n.match(preferred: ["en-GB"], available: codes) == "en", "en-GB matches en")
check(L10n.match(preferred: ["EN_US"], available: codes) == "en", "Underscores and case are normalized")
check(L10n.match(preferred: ["zh-Hant-TW"], available: codes) == "zh-Hans",
      "Traditional Chinese falls back to Simplified Chinese, not English")
check(L10n.match(preferred: ["fr-FR"], available: codes) == nil, "Unavailable languages do not invent a match")
check(L10n.match(preferred: ["fr", "en"], available: codes) == "en", "Matching follows preference order")
check(L10n.match(preferred: ["zh-Hans"], available: ["en", "zh-Hant"]) == "zh-Hant",
      "Simplified Chinese matches Traditional Chinese when that is all that is available")

check(L10n.resolve(preference: .system, environment: nil, system: ["fr-FR"]).code == L10n.defaultCode,
      "Unmatched system languages use the default language")
check(L10n.resolve(preference: .system, environment: nil, system: ["zh-Hans-CN", "en-US"]).code == "zh-Hans",
      "System language matching follows preference order")
check(L10n.resolve(preference: .fixed("en"), environment: nil, system: ["zh-Hans-CN"]).code == "en",
      "A fixed preference overrides system languages")
check(L10n.resolve(preference: .fixed("en"), environment: "zh-Hans", system: ["en-US"]).code == "zh-Hans",
      "HOURGLOW_LANG overrides a fixed preference")
check(L10n.resolve(preference: .fixed("xx-Fake"), environment: nil, system: ["zh-Hans-CN"]).code == "zh-Hans",
      "An unavailable preference falls back to system languages")

// MARK: - Lookup and plural selection

setenv("HOURGLOW_LANG", "en", 1)
L10n.invalidate()
check(L10n.code == "en", "HOURGLOW_LANG takes effect immediately")
check(L10n.t(count: 1, "import.done", 1) == L10n.t("import.done.one", 1),
      "English selects the singular form for one item")
check(L10n.t(count: 3, "import.done", 3) == L10n.t("import.done", 3),
      "English selects the base form for multiple items")
check(L10n.t("no.such.key.at.all") == "no.such.key.at.all",
      "Unknown keys remain visible instead of returning blank text")

setenv("HOURGLOW_LANG", "zh-Hans", 1)
L10n.invalidate()
check(L10n.code == "zh-Hans", "The language can switch back to Chinese")
check(L10n.t(count: 1, "import.done", 1) == L10n.t("import.done", 1),
      "A missing Chinese singular uses the Chinese base, not the English source singular")
check(L10n.t(count: 9, "import.done", 9) == L10n.t("import.done", 9),
      "Chinese uses its base form for multiple items")
unsetenv("HOURGLOW_LANG")
L10n.invalidate()

// MARK: - Source key usage

/// Scan literal keys in `L10n.t("…")` and `L10n.t(count: …, "…")`.
/// Computed keys (`"category." + raw`) are excluded; their callers provide fallbacks.
private func literalKeys(in source: String) -> [String] {
    var keys: [String] = []
    var index = source.startIndex
    while let call = source.range(of: "L10n.t(", range: index..<source.endIndex) {
        index = call.upperBound
        var cursor = call.upperBound
        // Skip `count: <expression>, ` and accept only the first following string literal.
        if source[cursor...].hasPrefix("count:"),
           let comma = source.range(of: ", ", range: cursor..<source.endIndex) {
            cursor = comma.upperBound
        }
        guard cursor < source.endIndex, source[cursor] == "\"" else { continue }
        let after = source.index(after: cursor)
        guard let close = source.range(of: "\"", range: after..<source.endIndex) else { continue }
        let key = String(source[after..<close.lowerBound])
        if !key.isEmpty, !key.contains("\\") { keys.append(key) }
    }
    return keys
}

let roots = Array(CommandLine.arguments.dropFirst())
if roots.isEmpty {
    print("\n(No source directories supplied; skipping key usage checks. CI runs `l10ncheck Sources`.)")
} else {
    var used: [String: String] = [:]      // Key → first file containing it
    for root in roots {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base,
                                                          includingPropertiesForKeys: nil) else {
            check(false, "Source directory \(root) can be enumerated")
            continue
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for key in literalKeys(in: text) where used[key] == nil {
                used[key] = url.path
            }
        }
    }
    let undefined = used.filter { reference.strings[$0.key] == nil }
        .map { "\($0.key) (\($0.value))" }.sorted()
    check(undefined.isEmpty,
          "All literal source keys exist in the source catalog"
          + (undefined.isEmpty ? "" : "; missing:\n    " + undefined.joined(separator: "\n    ")))
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) catalog checks failed\n".utf8))
    exit(1)
}
print("\nAll catalog checks passed (\(L10n.catalogs.count) languages × \(referenceKeys.count) base keys)")
