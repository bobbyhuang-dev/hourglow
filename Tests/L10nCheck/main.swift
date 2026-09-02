import Foundation

// 语言表的靶子：完整性、占位符、挑语言的规则，外加「代码里用到的 key 都存在」。
//
//   ./build/l10ncheck [要扫描的源码目录…]
//
// 不带目录只查表；带上 `Sources` 会把 `L10n.t("…")` 里写死的 key 也对一遍，
// 打错一个字母的后果是界面上露出 `slot.apply` 这种半成品，编译器不会拦。

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

// MARK: - 占位符

/// `String(format:)` 的一个参数位。`%1$@` → (1, "@")，`%.4f` → (顺序位, "f")。
private struct Placeholder: Equatable, Comparable {
    var position: Int
    var kind: Character
    var explicit: Bool

    static func < (a: Placeholder, b: Placeholder) -> Bool { a.position < b.position }
}

/// 把一条文案里的占位符解析出来。翻译允许重排（`%2$@ at %1$@`），
/// 所以比较的是「第几个参数是什么类型」，不是它们在句子里的先后。
private func placeholders(in text: String) -> [Placeholder] {
    var result: [Placeholder] = []
    var implicit = 0
    let scalars = Array(text)
    var i = 0
    while i < scalars.count {
        guard scalars[i] == "%" else { i += 1; continue }
        i += 1
        guard i < scalars.count else { break }
        if scalars[i] == "%" { i += 1; continue }   // 转义的百分号

        // 显式位置 `n$`
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

        // 标志、宽度、精度、长度修饰符
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

// MARK: - 表本身

let source = L10n.catalogs.first { $0.code == L10n.sourceCode }
check(source != nil, "原文语言 \(L10n.sourceCode) 在 L10n.catalogs 里")
check(L10n.catalogs.contains { $0.code == L10n.defaultCode },
      "兜底语言 \(L10n.defaultCode) 在 L10n.catalogs 里")
check(Set(L10n.catalogs.map(\.code)).count == L10n.catalogs.count, "语言代码没有重复")
check(L10n.catalogs.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
      "每门语言都写了母语名（选择器里要按母语显示）")

let reference = source ?? L10n.catalogs[0]
let referenceKeys = baseKeys(reference)
check(!referenceKeys.isEmpty, "原文表不是空的（\(referenceKeys.count) 条）")

for catalog in L10n.catalogs {
    let keys = baseKeys(catalog)

    let missing = referenceKeys.subtracting(keys).sorted()
    check(missing.isEmpty,
          "\(catalog.code) 没有漏词" + (missing.isEmpty ? "" : "，缺：\(missing.joined(separator: ", "))"))

    let extra = keys.subtracting(referenceKeys).sorted()
    check(extra.isEmpty,
          "\(catalog.code) 没有多出原文里没有的 key"
          + (extra.isEmpty ? "" : "，多：\(extra.joined(separator: ", "))"))

    let empty = catalog.strings.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .keys.sorted()
    check(empty.isEmpty,
          "\(catalog.code) 没有空文案" + (empty.isEmpty ? "" : "：\(empty.joined(separator: ", "))"))

    // 单数形是可选的补充，但它必须补在一条真的存在的 key 上，
    // 否则 `t(count:)` 永远挑不到它，写了等于没写。
    let orphans = catalog.strings.keys
        .filter { $0.hasSuffix(singularSuffix) }
        .filter { !keys.contains(String($0.dropLast(singularSuffix.count))) }
        .sorted()
    check(orphans.isEmpty,
          "\(catalog.code) 的单数形都挂在存在的 key 上"
          + (orphans.isEmpty ? "" : "，孤儿：\(orphans.joined(separator: ", "))"))

    // 占位符对不上就是崩溃或乱码：`String(format:)` 会照着格式串去取参数。
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
        // 一条文案里混用 `%@` 与 `%1$@` 的行为是未定义的。
        if got.count > 1, got.contains(where: \.explicit), got.contains(where: { !$0.explicit }) {
            mixed.append(key)
        }
    }
    check(mismatched.isEmpty,
          "\(catalog.code) 的占位符与原文一一对应"
          + (mismatched.isEmpty ? "" : "，对不上：\(mismatched.sorted().joined(separator: ", "))"))
    check(mixed.isEmpty,
          "\(catalog.code) 没有混用带序号与不带序号的占位符"
          + (mixed.isEmpty ? "" : "：\(mixed.sorted().joined(separator: ", "))"))

    // 多于一个参数就必须带序号：语序一变，不带序号的那份就取错了参数。
    let unordered = catalog.strings
        .filter { placeholders(in: $0.value).count > 1
                  && !placeholders(in: $0.value).allSatisfy(\.explicit) }
        .keys.sorted()
    check(unordered.isEmpty,
          "\(catalog.code) 里多参数的文案都用了 %n$ 序号"
          + (unordered.isEmpty ? "" : "：\(unordered.joined(separator: ", "))"))
}

// MARK: - 挑语言

let codes = L10n.catalogs.map(\.code)
check(L10n.match(preferred: ["zh-Hans"], available: codes) == "zh-Hans", "完全一致的代码直接命中")
check(L10n.match(preferred: ["zh-Hans-CN"], available: codes) == "zh-Hans",
      "带地区的 zh-Hans-CN 归到 zh-Hans")
check(L10n.match(preferred: ["en-GB"], available: codes) == "en", "en-GB 归到 en")
check(L10n.match(preferred: ["EN_US"], available: codes) == "en", "下划线与大小写都认")
check(L10n.match(preferred: ["zh-Hant-TW"], available: codes) == "zh-Hans",
      "没有繁体时退到简体，而不是扔去英文")
check(L10n.match(preferred: ["fr-FR"], available: codes) == nil, "没有的语言不硬凑")
check(L10n.match(preferred: ["fr", "en"], available: codes) == "en", "按用户的偏好顺序往下找")
check(L10n.match(preferred: ["zh-Hans"], available: ["en", "zh-Hant"]) == "zh-Hant",
      "只有繁体时简体用户拿到繁体")

check(L10n.resolve(preference: .system, environment: nil, system: ["fr-FR"]).code == L10n.defaultCode,
      "系统语言一门都对不上时用兜底语言")
check(L10n.resolve(preference: .system, environment: nil, system: ["zh-Hans-CN", "en-US"]).code == "zh-Hans",
      "跟随系统按系统的偏好顺序挑")
check(L10n.resolve(preference: .fixed("en"), environment: nil, system: ["zh-Hans-CN"]).code == "en",
      "用户选定的语言压过系统语言")
check(L10n.resolve(preference: .fixed("en"), environment: "zh-Hans", system: ["en-US"]).code == "zh-Hans",
      "HOURGLOW_LANG 压过用户选定的语言")
check(L10n.resolve(preference: .fixed("xx-Fake"), environment: nil, system: ["zh-Hans-CN"]).code == "zh-Hans",
      "偏好里是一门不存在的语言时退回系统语言，不是空白")

// MARK: - 查表与单复数

setenv("HOURGLOW_LANG", "en", 1)
L10n.invalidate()
check(L10n.code == "en", "HOURGLOW_LANG 立刻生效")
check(L10n.t("common.ok") == "OK", "英文表查得到词")
check(L10n.t(count: 1, "import.done", 1) == "Imported 1 wallpaper", "数量为 1 时挑单数形")
check(L10n.t(count: 3, "import.done", 3) == "Imported 3 wallpapers", "其余数量用主形")
check(L10n.t("no.such.key.at.all") == "no.such.key.at.all",
      "查不到的 key 原样露出来，不是空字符串")

setenv("HOURGLOW_LANG", "zh-Hans", 1)
L10n.invalidate()
check(L10n.code == "zh-Hans", "换回中文")
check(L10n.t(count: 1, "import.done", 1) == "已导入 1 张", "中文没有单数形，两种数量同一句")
check(L10n.t(count: 9, "import.done", 9) == "已导入 9 张", "中文没有单数形，两种数量同一句")
check(L10n.t("timeline.subtitle.next", "18:16", "Tahoe Night", "还有 2 小时")
      == "18:16 切换到 Tahoe Night · 还有 2 小时", "多参数按序号填进去")
unsetenv("HOURGLOW_LANG")
L10n.invalidate()

// MARK: - 代码里用到的 key 都在表里

/// 扫 `L10n.t("…")` / `L10n.t(count: …, "…")` 里写死的 key。
/// 拼出来的（`"category." + raw`）扫不到，也不该扫 —— 它们各自有兜底。
private func literalKeys(in source: String) -> [String] {
    var keys: [String] = []
    var index = source.startIndex
    while let call = source.range(of: "L10n.t(", range: index..<source.endIndex) {
        index = call.upperBound
        var cursor = call.upperBound
        // 跳过 `count: <表达式>, `，只认它后面的第一个字符串字面量。
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
    print("\n（没有给源码目录，跳过 key 使用检查；CI 里跑的是 `l10ncheck Sources`）")
} else {
    var used: [String: String] = [:]      // key → 第一次出现的文件
    for root in roots {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base,
                                                          includingPropertiesForKeys: nil) else {
            check(false, "扫得到目录 \(root)")
            continue
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for key in literalKeys(in: text) where used[key] == nil {
                used[key] = url.path
            }
        }
    }
    check(!used.isEmpty, "扫到了 \(used.count) 个写死的 key")
    let undefined = used.filter { reference.strings[$0.key] == nil }
        .map { "\($0.key)（\($0.value)）" }.sorted()
    check(undefined.isEmpty,
          "代码里用到的 key 全都在原文表里"
          + (undefined.isEmpty ? "" : "，缺：\n    " + undefined.joined(separator: "\n    ")))
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项语言表检查失败\n".utf8))
    exit(1)
}
print("\n全部语言表检查通过（\(L10n.catalogs.count) 门语言 × \(referenceKeys.count) 条）")
