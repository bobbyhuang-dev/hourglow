import Foundation

// CLI 入口。求值与定时都在 `Engine/Scheduler.swift` 里，
// 这里只是它的外壳与排障工具。常驻相关的命令见 `RunCommand.swift`。

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
    /// 按显示列宽右侧补空格。`String(format:)` 的 %-N@ 按字符数补齐，中文会错位。
    func padded(to width: Int) -> String {
        let columns = reduce(0) { $0 + ($1.isDoubleWidth ? 2 : 1) }
        return self + String(repeating: " ", count: max(0, width - columns))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
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
    if h == 0 { return "\(m) 分钟" }
    return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
}

func loadSchedule() -> Schedule {
    do { return try Store.load() }
    catch { fail("读取配置失败: \(error)") }
}

// MARK: - 命令

func showList() {
    let schedule = loadSchedule()
    let coordinate = schedule.effectiveCoordinate
    let source = schedule.location == nil ? "由时区推断" : "手动设置"

    print("配置  \(Store.fileURL.path)")
    if let c = coordinate {
        print(String(format: "坐标  %.2f, %.2f  (%@)", c.latitude, c.longitude, source))
    } else {
        print("坐标  未知 — solar 触发将被跳过")
    }
    print("状态  \(schedule.paused ? "已暂停" : "运行中")")
    print("")

    guard !schedule.slots.isEmpty else { print("(没有任何时段)"); return }

    let resolution = schedule.resolve(coordinate: coordinate)
    let today = schedule.firings(around: Date(), coordinate: coordinate)
        .filter { Calendar.current.isDateInToday($0.date) }

    for slot in schedule.slots {
        let marker = resolution?.active.id == slot.id ? "●" : " "
        let time = today.first { $0.slot.id == slot.id }
            .map { clockFormat.string(from: $0.date) } ?? "  —  "
        let status = slot.enabled ? "" : "  (已禁用)"
        print(" \(marker) \(time)  \(slot.trigger.description.padded(to: 14))"
              + "→  \(describe(slot.wallpaper).padded(to: 22))\(status)")
    }
}

func showNow() {
    let schedule = loadSchedule()
    guard let resolution = schedule.resolve() else {
        fail("无法求值：没有启用的时段，或 solar 触发缺少坐标")
    }
    print("现在  \(clockFormat.string(from: Date()))  →  \(describe(resolution.active.wallpaper))"
          + "   (自 \(clockFormat.string(from: resolution.since)) 起)")
    if let next = resolution.next {
        print("下次  \(clockFormat.string(from: next.at))  →  \(describe(next.slot.wallpaper))"
              + "   (还有 \(humanize(next.at.timeIntervalSinceNow)))")
    }
    if let actual = try? WallpaperWriter.current() {
        let match = WallpaperWriter.normalized(actual)
            == WallpaperWriter.normalized(resolution.active.wallpaper)
            ? "✓ 一致" : "✗ 不一致，需要 apply"
        print("实际  \(describe(actual))   \(match)")
    }
}

func showCurrent() {
    do {
        guard let wallpaper = try WallpaperWriter.current() else { fail("读不出当前壁纸") }
        switch wallpaper {
        case .aerial(let id): print("aerial  \(describe(wallpaper))  \(id)")
        case .image(let path): print("image   \(path)")
        }
    } catch { fail("\(error)") }
}

func runApply() {
    let schedule = loadSchedule()
    if schedule.paused, !flags.contains("--force") {
        print("已暂停，跳过。加 --force 强制应用。"); return
    }
    guard let resolution = schedule.resolve() else {
        fail("无法求值：没有启用的时段，或 solar 触发缺少坐标")
    }
    let dryRun = flags.contains("--dry-run")
    do {
        let changed = try WallpaperWriter.apply(resolution.active.wallpaper,
                                                dryRun: dryRun,
                                                force: flags.contains("--force"))
        let name = describe(resolution.active.wallpaper)
        if dryRun {
            print(changed ? "将设置为 \(name)" : "已经是 \(name)，无需改动")
        } else {
            print(changed ? "已设置为 \(name)" : "已经是 \(name)，跳过")
        }
    } catch { fail("\(error)") }
}

func runSet() {
    guard let target = positional.first else { fail("用法: hourglow-cli set <assetID | 名称 | 图片路径>") }

    let wallpaper: Wallpaper
    if FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath) {
        wallpaper = .image(path: (target as NSString).expandingTildeInPath)
    } else if let exact = catalog.first(where: { $0.id.caseInsensitiveCompare(target) == .orderedSame }) {
        wallpaper = .aerial(assetID: exact.id)
    } else if let byName = catalog.first(where: { $0.name.localizedCaseInsensitiveContains(target) }) {
        wallpaper = .aerial(assetID: byName.id)
    } else {
        fail("找不到匹配的壁纸: \(target)")
    }

    do {
        let changed = try WallpaperWriter.apply(wallpaper, force: flags.contains("--force"))
        print(changed ? "已设置为 \(describe(wallpaper))" : "已经是 \(describe(wallpaper))，跳过")
    } catch { fail("\(error)") }
}

func showCatalog() {
    guard !catalog.isEmpty else { fail("读不到 aerial 素材库: \(AerialCatalog.entriesURL.path)") }
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
        let size = asset.sizeMB.map { "\($0) MB" } ?? "未下载"
        print(" \(mark) \(asset.name.padded(to: 26))"
              + "\(asset.categories.joined(separator: ",").padded(to: 14))"
              + "\(size.padded(to: 9))\(asset.id)")
        shown += 1
    }
    print("\n\(shown) / \(catalog.count) 项，已下载 \(catalog.filter(\.isDownloaded).count) 项")
}

func showSolar() {
    let schedule = loadSchedule()
    guard let coordinate = schedule.effectiveCoordinate else { fail("没有坐标可用") }

    let day: Date
    if let text = positional.first {
        guard let parsed = dayFormat.date(from: text) else { fail("日期格式应为 YYYY-MM-DD") }
        day = parsed
    } else {
        day = Date()
    }

    print(String(format: "坐标  %.4f, %.4f   时区 %@",
                 coordinate.latitude, coordinate.longitude, TimeZone.current.identifier))
    guard let times = Solar.times(on: day, at: coordinate) else {
        print("\(dayFormat.string(from: day))  极昼或极夜"); return
    }
    print("\(dayFormat.string(from: day))  日出 \(clockFormat.string(from: times.sunrise))"
          + "   日落 \(clockFormat.string(from: times.sunset))")
}

func setLocation() {
    var schedule = loadSchedule()
    if positional.isEmpty {
        schedule.location = nil
        do {
            try Store.save(schedule)
            print("已清除手动坐标，回退到时区推断")
        } catch { fail("\(error)") }
        return
    }
    guard positional.count == 2,
          let lat = Double(positional[0]), let lon = Double(positional[1]) else {
        fail("用法: hourglow-cli location <纬度> <经度>   （不带参数则清除）")
    }
    schedule.location = Coordinate(latitude: lat, longitude: lon)
    do { try Store.save(schedule); print(String(format: "坐标已设为 %.4f, %.4f", lat, lon)) }
    catch { fail("\(error)") }
}

/// 时间旅行：在一整天上按固定步长求值，打印每一次切换。
/// 比等真实时钟快得多，也能一眼看出跨午夜回绕对不对。
func runSimulate() {
    let schedule = loadSchedule()
    let calendar = Calendar.current

    let day: Date
    if let text = positional.first {
        guard let parsed = dayFormat.date(from: text) else { fail("日期格式应为 YYYY-MM-DD") }
        day = parsed
    } else {
        day = Date()
    }
    guard let start = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: day) else {
        fail("无法构造当天零点")
    }

    print("模拟 \(dayFormat.string(from: day))  步长 1 分钟\n")

    var previous: UUID?
    var transitions = 0
    for minute in 0..<(24 * 60) {
        let instant = start.addingTimeInterval(Double(minute) * 60)
        guard let resolution = schedule.resolve(at: instant, calendar: calendar) else { continue }
        if resolution.active.id != previous {
            let origin = minute == 0 ? "（承接前一天）" : ""
            print("  \(clockFormat.string(from: instant))  →  "
                  + "\(describe(resolution.active.wallpaper).padded(to: 20))\(origin)")
            previous = resolution.active.id
            transitions += 1
        }
    }
    print("\n当天共 \(transitions) 次切换（含 00:00 承接前一天的那次）")
}

func showHelp() {
    print("""
    hourglow-cli — HourGlow 的调试入口

      list                       显示时间轴与今天各段的实际时刻
      now                        当前应生效的壁纸、下次切换、与实际是否一致
      current                    读取系统当前壁纸
      apply [--dry-run|--force]  把当前应生效的壁纸写入系统
      set <assetID|名称|路径>     直接设置某张（调试用）
      catalog [关键词] [--downloaded]
                                 列出 156 张系统 aerial
      simulate [YYYY-MM-DD]      时间旅行：打印该日全天的每一次切换
      solar [YYYY-MM-DD]         该日的日出日落
      location [纬度 经度]        设置或清除手动坐标

    引擎（M2）
      run                        前台常驻：定时器 + 唤醒/时区/配置变更驱动
      status                     引擎视角：上次写了什么、当前是不是还是那张
      pause / resume             全局暂停 / 恢复（恢复时立即校正）
      agent install|uninstall|status
                                 把 run 注册成 LaunchAgent，重启后仍然活着
    """)
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
case "run":      runDaemon()
case "status":   runStatus()
case "pause":    runPause()
case "resume":   runResume()
case "agent":    runAgent(positional.first)
case "help", "-h", "--help": showHelp()
default: fail("未知命令 \(command)，试试 hourglow-cli help")
}
