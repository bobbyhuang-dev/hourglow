import Foundation

// CLI 入口。求值与定时都在 `Engine/Scheduler.swift` 里，
// 这里只是它的外壳与排障工具。常驻相关的命令见 `RunCommand.swift`。
//
// 输出全部走 `L10n`：CLI 是裸二进制，没有 bundle，文案表是编进来的那一份。

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "now"
let operands = Array(arguments.dropFirst())
let flags = Set(operands.filter { $0.hasPrefix("--") })
let positional = operands.filter { !$0.hasPrefix("--") }

extension Character {
    /// 终端里占两列的字符（CJK、全角、emoji）。
    var isDoubleWidth: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

extension String {
    /// 终端里占几列。中文一个字两列，英文一列。
    var displayWidth: Int { reduce(0) { $0 + ($1.isDoubleWidth ? 2 : 1) } }

    /// 按显示列宽右侧补空格。`String(format:)` 的 %-N@ 按字符数补齐，中文会错位。
    func padded(to width: Int) -> String {
        self + String(repeating: " ", count: max(0, width - displayWidth))
    }
}

/// 一列文字的宽度按内容算，不写死数字：同一个栏目中文占四列、英文占七列，
/// 写死哪个数字都会在另一门语言里错行。
func column(_ values: [String], min floor: Int = 0) -> Int {
    max(floor, values.map(\.displayWidth).max() ?? 0)
}

/// 左边的标签列（配置 / 坐标 / 状态…）。宽度按当前语言里最长的那个标签算。
let labelWidth = column(["cli.label.config", "cli.label.coordinate", "cli.label.state",
                         "cli.label.assets", "cli.label.trigger", "cli.label.log",
                         "cli.label.plist"].map { L10n.t($0) })

func labeled(_ key: String, _ value: String) -> String {
    L10n.t(key).padded(to: labelWidth) + "  " + value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((L10n.t("cli.error", message) + "\n").utf8))
    exit(1)
}

let clockFormat: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()
let dayFormat: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

let catalog = (try? AerialCatalog.load()) ?? []
let assetNames = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

func describe(_ wallpaper: Wallpaper) -> String {
    switch wallpaper {
    case .aerial(let id): return assetNames[id] ?? "aerial \(id.prefix(8))…"
    case .image(let path): return (path as NSString).lastPathComponent
    }
}

func humanize(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int((interval / 60).rounded()))
    let (h, m) = (minutes / 60, minutes % 60)
    if h == 0 { return L10n.t("cli.duration.minutes", m) }
    return m == 0 ? L10n.t("cli.duration.hours", h)
                  : L10n.t("cli.duration.hoursMinutes", h, m)
}

func loadSchedule() -> Schedule {
    do { return try Store.load() }
    catch { fail(L10n.t("cli.loadFailed", "\(error)")) }
}

// MARK: - 命令

func showList() {
    let schedule = loadSchedule()
    let coordinate = schedule.effectiveCoordinate
    let source = L10n.t(schedule.location == nil ? "cli.place.fromTimeZone" : "cli.place.manual")

    print(labeled("cli.label.config", Store.fileURL.path))
    if let c = coordinate {
        let name = c.name.map { "  \($0)" } ?? ""
        print(labeled("cli.label.coordinate",
                      String(format: "%.2f, %.2f  (%@)%@", c.latitude, c.longitude, source, name)))
    } else {
        print(labeled("cli.label.coordinate", L10n.t("cli.coordinate.unknown")))
    }
    print(labeled("cli.label.state",
                  L10n.t(schedule.paused ? "cli.state.paused" : "cli.state.running")))
    print("")

    guard !schedule.slots.isEmpty else { print(L10n.t("cli.list.empty")); return }

    let resolution = schedule.resolve(coordinate: coordinate)
    let today = schedule.firings(around: Date(), coordinate: coordinate)
        .filter { Calendar.current.isDateInToday($0.date) }

    let triggerWidth = column(schedule.slots.map(\.trigger.description), min: 12) + 2
    let nameWidth = column(schedule.slots.map { describe($0.wallpaper) }, min: 22)

    for slot in schedule.slots {
        let marker = resolution?.active.id == slot.id ? "●" : " "
        let time = today.first { $0.slot.id == slot.id }
            .map { clockFormat.string(from: $0.date) } ?? "  —  "
        let status = slot.enabled ? "" : L10n.t("cli.list.disabled")
        print(" \(marker) \(time)  \(slot.trigger.description.padded(to: triggerWidth))"
              + "→  \(describe(slot.wallpaper).padded(to: nameWidth))\(status)")
    }
}

func showNow() {
    let schedule = loadSchedule()
    guard let resolution = schedule.resolve() else { fail(L10n.t("cli.unresolvable")) }
    print(L10n.t("cli.now.current",
                 clockFormat.string(from: Date()),
                 describe(resolution.active.wallpaper),
                 clockFormat.string(from: resolution.since)))
    if let next = resolution.next {
        print(L10n.t("cli.now.next",
                     clockFormat.string(from: next.at),
                     describe(next.slot.wallpaper),
                     humanize(next.at.timeIntervalSinceNow)))
    }
    if let actual = try? WallpaperWriter.current() {
        let match = WallpaperWriter.normalized(actual)
            == WallpaperWriter.normalized(resolution.active.wallpaper)
            ? L10n.t("cli.now.match") : L10n.t("cli.now.mismatch")
        print(L10n.t("cli.now.actual", describe(actual), match))
    }
}

func showCurrent() {
    do {
        guard let wallpaper = try WallpaperWriter.current() else {
            fail(L10n.t("cli.current.unreadable"))
        }
        // 这两行是给排障用的原始事实（provider 与 assetID），不翻译。
        switch wallpaper {
        case .aerial(let id): print("aerial  \(describe(wallpaper))  \(id)")
        case .image(let path): print("image   \(path)")
        }
    } catch { fail("\(error)") }
}

func runApply() {
    let schedule = loadSchedule()
    if schedule.paused, !flags.contains("--force") {
        print(L10n.t("cli.apply.paused")); return
    }
    guard let resolution = schedule.resolve() else { fail(L10n.t("cli.unresolvable")) }
    let dryRun = flags.contains("--dry-run")
    do {
        let changed = try WallpaperWriter.apply(resolution.active.wallpaper,
                                                dryRun: dryRun,
                                                force: flags.contains("--force"))
        let name = describe(resolution.active.wallpaper)
        if dryRun {
            print(L10n.t(changed ? "cli.apply.willSet" : "cli.apply.alreadyDryRun", name))
        } else {
            print(L10n.t(changed ? "cli.apply.set" : "cli.apply.already", name))
        }
    } catch { fail("\(error)") }
}

func runSet() {
    guard let target = positional.first else { fail(L10n.t("cli.set.usage")) }

    let wallpaper: Wallpaper
    if FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath) {
        wallpaper = .image(path: (target as NSString).expandingTildeInPath)
    } else if let exact = catalog.first(where: { $0.id.caseInsensitiveCompare(target) == .orderedSame }) {
        wallpaper = .aerial(assetID: exact.id)
    } else if let byName = catalog.first(where: { $0.name.localizedCaseInsensitiveContains(target) }) {
        wallpaper = .aerial(assetID: byName.id)
    } else {
        fail(L10n.t("cli.set.notFound", target))
    }

    do {
        let changed = try WallpaperWriter.apply(wallpaper, force: flags.contains("--force"))
        print(L10n.t(changed ? "cli.apply.set" : "cli.apply.already", describe(wallpaper)))
    } catch { fail("\(error)") }
}

func showCatalog() {
    guard !catalog.isEmpty else {
        fail(L10n.t("cli.catalog.unreadable", AerialCatalog.entriesURL.path))
    }
    let query = positional.first
    let onlyDownloaded = flags.contains("--downloaded")

    var shown = 0
    for asset in catalog {
        if let query, !asset.name.localizedCaseInsensitiveContains(query),
           !asset.categories.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            continue
        }
        if onlyDownloaded, !asset.isDownloaded { continue }
        let mark = asset.isDownloaded ? "✓" : " "
        let size = asset.sizeMB.map { "\($0) MB" } ?? L10n.t("cli.catalog.notDownloaded")
        // 名称与分类是系统素材库里的原文，`catalog` 是排障用的原样转储，不翻译。
        print(" \(mark) \(asset.name.padded(to: 26))"
              + "\(asset.categories.joined(separator: ",").padded(to: 14))"
              + "\(size.padded(to: 14))\(asset.id)")
        shown += 1
    }
    print("\n" + L10n.t("cli.catalog.count", shown, catalog.count,
                        catalog.filter(\.isDownloaded).count))
}

func showSolar() {
    let schedule = loadSchedule()
    guard let coordinate = schedule.effectiveCoordinate else { fail(L10n.t("cli.solar.noCoordinate")) }

    let day: Date
    if let text = positional.first {
        guard let parsed = dayFormat.date(from: text) else { fail(L10n.t("cli.solar.badDate")) }
        day = parsed
    } else {
        day = Date()
    }

    print(L10n.t("cli.solar.header", coordinate.latitude, coordinate.longitude,
                 TimeZone.current.identifier))
    guard let times = Solar.times(on: day, at: coordinate) else {
        print(L10n.t("cli.solar.polar", dayFormat.string(from: day))); return
    }
    print(L10n.t("cli.solar.times", dayFormat.string(from: day),
                 clockFormat.string(from: times.sunrise),
                 clockFormat.string(from: times.sunset)))
    if let events = Solar.events(on: day, at: coordinate) {
        // 高纬夏天太阳掉不到 −12°/−6°，这两个时刻并不存在。不要在这里编一个出来：
        // 天光分段的兜底在 `TimeMap.nominalTwilight`，这里如实说「无」。
        let dawn = events.nauticalDawn.map(clockFormat.string(from:)) ?? L10n.t("common.none")
        let dusk = events.civilDusk.map(clockFormat.string(from:)) ?? L10n.t("common.none")
        print(L10n.t("cli.solar.twilight", dawn, dusk))
    }
}

func setLocation() {
    var schedule = loadSchedule()
    if positional.isEmpty {
        schedule.location = nil
        do {
            try Store.save(schedule)
            print(L10n.t("cli.location.cleared"))
        } catch { fail("\(error)") }
        return
    }
    if positional.count >= 2,
       let lat = Double(positional[0]), let lon = Double(positional[1]) {
        let name = positional.count > 2 ? positional.dropFirst(2).joined(separator: " ") : nil
        schedule.location = Coordinate(latitude: lat, longitude: lon, name: name)
        do {
            try Store.save(schedule)
            print(L10n.t("cli.location.set", lat, lon, name.map { " \($0)" } ?? ""))
        } catch { fail("\(error)") }
        return
    }

    let query = positional.joined(separator: " ")
    let city = Cities.lookup(query) ?? PlaceSearch.nominatimBlocking(query).first
    guard let city else { fail(L10n.t("cli.location.notFound", query)) }
    schedule.location = city.asCoordinate
    do {
        try Store.save(schedule)
        print(L10n.t("cli.location.place", city.name,
                     city.coordinate.latitude, city.coordinate.longitude))
    } catch { fail("\(error)") }
}

func showCities() {
    let query = positional.joined(separator: " ")
    let hits = Cities.search(query)
    guard !hits.isEmpty else { fail(L10n.t("cli.cities.empty")) }
    let shown = Array(hits.prefix(40))
    let nameWidth = column(shown.map(\.name), min: 12)
    for city in shown {
        print(String(format: "  %@  %7.3f  %8.3f  %@",
                     city.name.padded(to: nameWidth),
                     city.coordinate.latitude, city.coordinate.longitude,
                     city.detail))
    }
    print("\n" + L10n.t("cli.cities.count", shown.count, hits.count))
}

/// 时间旅行：在一整天上按固定步长求值，打印每一次切换。
/// 比等真实时钟快得多，也能一眼看出跨午夜回绕对不对。
func runSimulate() {
    let schedule = loadSchedule()
    let calendar = Calendar.current

    let day: Date
    if let text = positional.first {
        guard let parsed = dayFormat.date(from: text) else { fail(L10n.t("cli.solar.badDate")) }
        day = parsed
    } else {
        day = Date()
    }
    guard let start = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: day) else {
        fail(L10n.t("cli.simulate.midnightFailed"))
    }

    print(L10n.t("cli.simulate.header", dayFormat.string(from: day)) + "\n")

    let nameWidth = column(schedule.slots.map { describe($0.wallpaper) }, min: 20)
    var previous: UUID?
    var transitions = 0
    for minute in 0..<(24 * 60) {
        let instant = start.addingTimeInterval(Double(minute) * 60)
        guard let resolution = schedule.resolve(at: instant, calendar: calendar) else { continue }
        if resolution.active.id != previous {
            let origin = minute == 0 ? L10n.t("cli.simulate.carried") : ""
            print("  \(clockFormat.string(from: instant))  →  "
                  + "\(describe(resolution.active.wallpaper).padded(to: nameWidth))\(origin)")
            previous = resolution.active.id
            transitions += 1
        }
    }
    print("\n" + L10n.t("cli.simulate.count", transitions))
}

func runImport() {
    var rest = Array(operands)
    var name: String?
    if let flag = rest.firstIndex(of: "--name"), flag + 1 < rest.count {
        name = rest[flag + 1]
        rest.remove(at: flag + 1)
        rest.remove(at: flag)
    }
    let paths = rest.filter { !$0.hasPrefix("--") }
    guard !paths.isEmpty else { fail(L10n.t("cli.import.usage")) }
    let urls = paths.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let schedule = loadSchedule()
    do {
        let outcome = try SceneImport.apply(urls: urls, to: schedule, name: name)
        do {
            try Store.save(outcome.schedule)
        } catch {
            // 配置没落盘，旧时间轴仍是权威；撤掉本次新素材，不能提前清旧目录。
            SceneImport.discard(outcome)
            throw error
        }
        SceneImport.finalize(outcome)
        let count = outcome.schedule.slots.count
        print(L10n.t(count: count, "cli.import.done", count))
        print(labeled("cli.label.assets", SceneImport.scenesDirectory.path))
        print(labeled("cli.label.config", Store.fileURL.path))
        print(labeled("cli.label.trigger", L10n.t("cli.import.trigger")))
        let triggerWidth = column(outcome.schedule.slots.map(\.trigger.description), min: 12) + 2
        for slot in outcome.schedule.slots {
            print("  \(slot.trigger.description.padded(to: triggerWidth))→  \(describe(slot.wallpaper))")
        }
        if !outcome.skipped.isEmpty {
            // 别的文件认得出时段、它们认不出，硬塞会把夜景排到中午。跳过可以，闷声跳过不行。
            let skipped = outcome.skipped.count
            print("\n" + L10n.t(count: skipped, "cli.import.skipped", skipped))
            for url in outcome.skipped.prefix(12) {
                print("  \(url.lastPathComponent)")
            }
            if skipped > 12 { print(L10n.t("cli.import.more", skipped - 12)) }
        }
    } catch {
        fail(error.localizedDescription)
    }
}

/// 界面与命令行的语言。不带参数只打印现状。
/// 偏好存在 `UserDefaults`，与菜单栏 app 是同一份 —— 改这里，面板下次打开就跟着变。
func runLanguage() {
    if let wanted = positional.first {
        if wanted == "system" {
            L10n.setPreference(.system)
        } else if let hit = L10n.match(preferred: [wanted], available: L10n.catalogs.map(\.code)) {
            L10n.setPreference(.fixed(hit))
        } else {
            fail(L10n.t("cli.language.unknown", wanted,
                        L10n.catalogs.map(\.code).joined(separator: ", ")))
        }
    }

    let current = L10n.catalog
    print(L10n.t("cli.language.current", current.code, current.name))
    switch L10n.storedPreference {
    case .system:          print(L10n.t("cli.language.preference", L10n.t("cli.language.system")))
    case .fixed(let code): print(L10n.t("cli.language.preference", code))
    }
    print(L10n.t("cli.language.available",
                 L10n.catalogs.map { "\($0.code) (\($0.name))" }
                     .joined(separator: L10n.t("list.separator"))))
    // 环境变量压过刚写下的偏好，不说一句的话「设了没生效」会被当成 bug。
    if let env = L10n.environmentCode() { print(L10n.t("cli.language.env", env)) }
}

func showHelp() {
    print(L10n.t("cli.help"))
}

switch command {
case "list":     showList()
case "now":      showNow()
case "current":  showCurrent()
case "apply":    runApply()
case "set":      runSet()
case "catalog":  showCatalog()
case "simulate": runSimulate()
case "solar":    showSolar()
case "location": setLocation()
case "cities":   showCities()
case "language": runLanguage()
case "import":   runImport()
case "run":      runDaemon()
case "status":   runStatus()
case "pause":    runPause()
case "resume":   runResume()
case "agent":    runAgent(positional.first)
case "help", "-h", "--help": showHelp()
default: fail(L10n.t("cli.unknownCommand", command))
}
