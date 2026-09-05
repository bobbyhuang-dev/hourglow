import Foundation

// 断言里写着中文原文（城市名、指引文案），所以靶子必须跑在原文语言下：
// 不钉住的话，英文系统上会挂在 `深圳` vs `Shenzhen` 这种地方。
// 换语言本身由 `l10ncheck` 单独覆盖。
setenv("HOURGLOW_LANG", L10n.sourceCode, 1)
L10n.invalidate()

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

private func localDate(_ text: String, calendar: Calendar) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: text) else {
        fatalError("测试日期无效: \(text)")
    }
    return date
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let coordinate = Coordinate(latitude: 31.2333, longitude: 121.4667)

// 固定时刻跨午夜时，应承接前一天最后一个时段，并给出今天第一次切换。
let morning = Slot(trigger: .clock(hour: 9, minute: 0), wallpaper: .image(path: "/morning"))
let night = Slot(trigger: .clock(hour: 21, minute: 0), wallpaper: .image(path: "/night"))
let clockSchedule = Schedule(slots: [morning, night], location: coordinate)
let afterMidnight = localDate("2026-08-22 01:00", calendar: calendar)
let clockResolution = clockSchedule.resolve(at: afterMidnight, calendar: calendar)
check(clockResolution?.active.id == night.id, "固定时刻在午夜后承接前一天")
check(clockResolution?.next?.slot.id == morning.id, "固定时刻能找到当天的下一次切换")

// 两段同刻时必须有稳定规则，而且“下次”预告的必须就是到点后真正生效的那一段。
// 旧实现只按 Date 排序，相等元素的先后不受保证；next 还会取第一个、active 取最后一个。
let sameTimeFirst = Slot(trigger: .clock(hour: 9, minute: 0),
                         wallpaper: .image(path: "/same-first"))
let sameTimeLast = Slot(trigger: .clock(hour: 9, minute: 0),
                        wallpaper: .image(path: "/same-last"))
let sameTimeSchedule = Schedule(slots: [sameTimeFirst, sameTimeLast])
let beforeSameTime = localDate("2026-08-22 08:00", calendar: calendar)
let afterSameTime = localDate("2026-08-22 10:00", calendar: calendar)
check(sameTimeSchedule.resolve(at: beforeSameTime, calendar: calendar)?.next?.slot.id
      == sameTimeLast.id,
      "同刻时段的下一次切换预告配置中靠后的胜出者")
check(sameTimeSchedule.resolve(at: afterSameTime, calendar: calendar)?.active.id
      == sameTimeLast.id,
      "同刻时段到点后由配置中靠后的稳定胜出")

// 偏移可以跨越不止一个日历日。旧实现统一围绕 now 展开 ±1 天，
// 因此“日出后 48 小时”在触发当日会完全求值失败。
let delayed = Slot(trigger: .solar(event: .sunrise, offsetMinutes: 48 * 60),
                   wallpaper: .image(path: "/delayed"))
let delayedSchedule = Schedule(slots: [delayed], location: coordinate)
let noon = localDate("2026-08-22 12:00", calendar: calendar)
let delayedResolution = delayedSchedule.resolve(at: noon, calendar: calendar)
check(delayedResolution?.active.id == delayed.id, "太阳触发支持超过一天的正偏移")
check(delayedResolution.map { $0.since <= noon } ?? false, "正偏移触发点不晚于当前时刻")
check((delayedResolution?.next?.at ?? .distantPast) > noon, "正偏移仍能找到下一次切换")

let advanced = Slot(trigger: .solar(event: .sunset, offsetMinutes: -48 * 60),
                    wallpaper: .image(path: "/advanced"))
let advancedSchedule = Schedule(slots: [advanced], location: coordinate)
let advancedResolution = advancedSchedule.resolve(at: noon, calendar: calendar)
check(advancedResolution?.active.id == advanced.id, "太阳触发支持超过一天的负偏移")
check((advancedResolution?.next?.at ?? .distantPast) > noon, "负偏移仍能找到下一次切换")

let homeImage = Wallpaper.image(path: "~/Pictures/hour glow.jpg")
let absoluteImage = Wallpaper.image(
    path: ("~/Pictures/hour glow.jpg" as NSString).expandingTildeInPath)
check(WallpaperWriter.normalized(homeImage) == WallpaperWriter.normalized(absoluteImage),
      "图片路径比较前会统一展开波浪号")

let relativeImage = Wallpaper.image(path: "Pictures/../Pictures/hour glow.jpg")
let workingDirectoryImage = Wallpaper.image(
    path: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Pictures/hour glow.jpg").path)
check(WallpaperWriter.normalized(relativeImage) == WallpaperWriter.normalized(workingDirectoryImage),
      "图片路径比较前会转成规范化绝对路径")

do {
    let legacy = Data("""
        {"slots":[{"trigger":{"type":"clock","hour":9},
                    "wallpaper":{"type":"image","path":"/legacy.jpg"}}]}
        """.utf8)
    let migrated = try Store.decode(legacy)
    check(migrated.needsIDMigration, "缺少 slot ID 的旧配置会被标记为待迁移")

    let encoded = try JSONEncoder().encode(migrated.schedule)
    let reloaded = try Store.decode(encoded)
    check(!reloaded.needsIDMigration, "回写后的配置不再重复迁移")
    check(reloaded.schedule.slots.first?.id == migrated.schedule.slots.first?.id,
          "自动生成的 slot ID 回写后保持稳定")
} catch {
    check(false, "旧配置迁移可以完成：\(error)")
}

check(ApproxLocation.parseISO6709("+3114+12128")
      == Coordinate(latitude: 31 + 14.0 / 60, longitude: 121 + 28.0 / 60),
      "ISO 6709 度分坐标解析正确")
check(ApproxLocation.parseISO6709("+513030-0000731")
      == Coordinate(latitude: 51 + 30.0 / 60 + 30.0 / 3600,
                    longitude: -(7.0 / 60 + 31.0 / 3600)),
      "ISO 6709 度分秒坐标解析正确")
check(ApproxLocation.parseISO6709("+3199+12128") == nil,
      "ISO 6709 解析拒绝非法分钟")
check(ApproxLocation.parseISO6709("+31xx+12128") == nil,
      "ISO 6709 解析拒绝非数字字段")
check(ApproxLocation.parseISO6709("+9001+12128") == nil,
      "ISO 6709 解析拒绝越界纬度")

// MARK: - 首次启动写入预设
//
// 这条只能在一个空目录上验：文件已经存在时那段分支根本不会走。`HOURGLOW_HOME` 就是
// 为此存在的（macOS 上 `NSHomeDirectory()` 取的是账户真实家目录，改 $HOME 不管用）。
// 写的全是临时目录，不碰真配置。

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-modelcheck-\(UUID().uuidString)")
setenv("HOURGLOW_HOME", sandbox.path, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

check(Store.directoryURL == sandbox, "HOURGLOW_HOME 能把配置目录整体改道")
check(!FileManager.default.fileExists(atPath: Store.fileURL.path), "起点是一个空目录")

let firstRun = (try? Store.load()) ?? Schedule()
check(FileManager.default.fileExists(atPath: Store.fileURL.path),
      "首次启动把预设落到了磁盘上")
check(firstRun.slots.count == 4, "预设是四段")
check(firstRun.slots.map(\.trigger) == [
        .solar(event: .sunrise, offsetMinutes: 0),
        .clock(hour: 9, minute: 0),
        .solar(event: .sunset, offsetMinutes: -30),
        .solar(event: .sunset, offsetMinutes: 60),
      ], "预设的四个触发条件是日出 / 09:00 / 日落前 30 / 日落后 60")
check(firstRun.slots.map(\.wallpaper) == [
        .aerial(assetID: Tahoe.morning), .aerial(assetID: Tahoe.day),
        .aerial(assetID: Tahoe.evening), .aerial(assetID: Tahoe.night),
      ], "预设绑的是 Tahoe 四张")
// ID 每次启动都换的话，引擎会把同一段当成「配置换了一段」而覆盖用户的手动选择。
check((try? Store.load())?.slots.map(\.id) == firstRun.slots.map(\.id),
      "第二次读回来的 slot ID 与首次写入的一致")

check(Cities.lookup("深圳")?.isChina == true, "深圳归入中国")
// 子串兜底会让一个字母命中到地球另一边（lookup("a") → Abidjan），打错字就被静默设错地方。
check(Cities.lookup("a") == nil, "一个字母不做模糊兜底")
check(Cities.lookup("深")?.name == "深圳", "从头对上的仍然算命中")
check(Cities.lookup("东京")?.isChina == false, "东京不归入中国")
check(Cities.lookup("shenzhen")?.name == "深圳", "拼音能搜到深圳")

// MARK: - 天光分段

let shenzhen = Coordinate(latitude: 22.543, longitude: 114.058, name: "深圳")
let solstice = localDate("2026-12-21 12:00", calendar: calendar)
guard let windows = TimeMap.windows(on: solstice, coordinate: shenzhen, calendar: calendar) else {
    check(false, "冬至能算出天光窗口")
    fatalError("no windows")
}
check(windows.sunrise.start < windows.sunrise.end, "日出窗口有长度")
check(windows.sunrise.end == windows.day.start, "日出窗口接到白昼")
check(windows.day.end == windows.sunset.start, "白昼接到日落")
check(windows.sunset.end == windows.night.start, "日落接到夜晚")
check(windows.night.end > windows.night.start, "夜晚窗口跨过午夜仍有长度")

let three = TimeMap.fireDate(phase: .sunrise, index: 0, count: 3,
                             on: solstice, coordinate: shenzhen, calendar: calendar)
let five = TimeMap.fireDate(phase: .sunrise, index: 0, count: 5,
                            on: solstice, coordinate: shenzhen, calendar: calendar)
check(three == five, "3 张和 5 张日出的第一张落在同一窗口起点")

let sunriseLast3 = TimeMap.fireDate(phase: .sunrise, index: 2, count: 3,
                                    on: solstice, coordinate: shenzhen, calendar: calendar)
let sunriseMid3 = TimeMap.fireDate(phase: .sunrise, index: 1, count: 3,
                                   on: solstice, coordinate: shenzhen, calendar: calendar)
if let a = three, let b = sunriseMid3, let c = sunriseLast3 {
    let step = b.timeIntervalSince(a)
    check(abs(c.timeIntervalSince(b) - step) < 1, "同一段内等分")
    check(c < windows.sunrise.end, "最后一张仍在窗口内，不会顶到下一段")
} else {
    check(false, "三张日出都能算出触发时刻")
}

let nightLast = TimeMap.fireDate(phase: .night, index: 2, count: 3,
                                 on: solstice, coordinate: shenzhen, calendar: calendar)
if let nightLast {
    check(!calendar.isDate(nightLast, inSameDayAs: solstice)
          || nightLast >= windows.night.start,
          "夜晚最后几张可以落在次日凌晨")
} else {
    check(false, "夜晚最后一张能算出来")
}

// MARK: - 高纬：晨光 / 黄昏根本不存在的那几天
//
// 太阳掉不到 −12°/−6° 时 `Solar.events` 给的是 nil。曾经回退成日出 / 日落本身，
// 于是「晨光到日出」长度为 0，被 max(_, 60) 撑成 60 秒 —— 一段三张壁纸
// 挤在 20 秒里连着刷过去，还连着 killall 三次 WallpaperAgent。

var arctic = Calendar(identifier: .gregorian)
arctic.timeZone = TimeZone(identifier: "Europe/Oslo")!
let tromso = Coordinate(latitude: 69.65, longitude: 18.96, name: "Tromsø")
let august = localDate("2026-08-20 12:00", calendar: arctic)
let arcticEvents = Solar.events(on: august, at: tromso, calendar: arctic)
check(arcticEvents?.nauticalDawn == nil, "特罗姆瑟 8 月 20 日没有航海晨光")
if let arcticWindows = TimeMap.windows(on: august, coordinate: tromso, calendar: arctic) {
    let span = arcticWindows.sunrise.end.timeIntervalSince(arcticWindows.sunrise.start)
    check(span > 30 * 60, "算不出晨光时按名义时长兜底，日出段不会缩成几十秒")
    let first = TimeMap.fireDate(phase: .sunrise, index: 0, count: 3,
                                 on: august, coordinate: tromso, calendar: arctic)
    let second = TimeMap.fireDate(phase: .sunrise, index: 1, count: 3,
                                  on: august, coordinate: tromso, calendar: arctic)
    if let first, let second {
        check(second.timeIntervalSince(first) > 5 * 60, "三张日出彼此至少隔几分钟")
    } else {
        check(false, "兜底之后仍能算出触发时刻")
    }
    check(arcticWindows.day.start < arcticWindows.day.end, "白昼窗口没有被兜底挤成负的")
    check(arcticWindows.night.start < arcticWindows.night.end, "夜晚窗口没有被兜底挤成负的")
} else {
    check(false, "特罗姆瑟 8 月能算出天光窗口")
}

let midnightSun = localDate("2026-06-21 12:00", calendar: arctic)
check(TimeMap.windows(on: midnightSun, coordinate: tromso, calendar: arctic) == nil,
      "极昼那天算不出窗口，天光时段整体跳过")

let phaseSlot = Slot(trigger: .solarPhase(phase: .sunset, index: 1, count: 3),
                     wallpaper: .image(path: "/sunset_2.heic"))
let phaseSchedule = Schedule(slots: [phaseSlot], location: shenzhen)
let dusk = localDate("2026-12-21 23:00", calendar: calendar)
let phaseResolution = phaseSchedule.resolve(at: dusk, calendar: calendar)
check(phaseResolution?.active.id == phaseSlot.id, "solarPhase 能被求值")
check((phaseResolution?.next?.at ?? .distantPast) > dusk, "solarPhase 能找到下一次切换")

do {
    let encoded = try JSONEncoder().encode(phaseSlot.trigger)
    let decoded = try JSONDecoder().decode(Trigger.self, from: encoded)
    check(decoded == phaseSlot.trigger, "solarPhase 可以 JSON 往返")
    let legacy = Data(#"{"type":"solarPhase","phase":"sunrise","index":0,"count":3}"#.utf8)
    let loaded = try JSONDecoder().decode(Trigger.self, from: legacy)
    check(loaded == .solarPhase(phase: .sunrise, index: 0, count: 3),
          "手写的 solarPhase JSON 能解码")
} catch {
    check(false, "solarPhase Codable：\(error)")
}

// MARK: - 发布前输入边界

for trigger in [
    #"{"type":"clock","hour":24}"#,
    #"{"type":"clock","hour":-1}"#,
    #"{"type":"clock","hour":12,"minute":60}"#,
    #"{"type":"clock","hour":12,"minute":-1}"#,
] {
    check((try? JSONDecoder().decode(Trigger.self, from: Data(trigger.utf8))) == nil,
          "非法固定时刻不能解码：\(trigger)")
}
for (latitude, longitude) in [(91.0, 0.0), (-91, 0), (0, 181), (0, -181)] {
    let json = "{\"latitude\":\(latitude),\"longitude\":\(longitude)}"
    check((try? JSONDecoder().decode(Coordinate.self, from: Data(json.utf8))) == nil,
          "拒绝越界坐标 \(latitude), \(longitude)")
}
check(Coordinate(latitude: 90, longitude: -180).isValid, "南北极与换日线端点合法")
check(!Coordinate(latitude: .nan, longitude: 0).isValid, "拒绝 NaN 坐标")
check(!Coordinate(latitude: 0, longitude: .infinity).isValid, "拒绝无限坐标")
check(Trigger.solar(event: .sunrise, offsetMinutes: Int.min).description
      .contains(String(Int.min.magnitude)), "最小整数偏移展示不溢出、不截断")
check(Trigger.solar(event: .sunset, offsetMinutes: Int.max).description
      .contains(String(Int.max)), "最大整数偏移展示不截断")

do {
    let nullID = Data(#"{"slots":[{"id":null,"trigger":{"type":"clock","hour":9},"wallpaper":{"type":"image","path":"/null.jpg"}}]}"#.utf8)
    try nullID.write(to: Store.fileURL)
    let first = try Store.load()
    let second = try Store.load()
    check(first.slots.first?.id == second.slots.first?.id,
          "显式 null ID 也会回写，反复加载保持稳定")
    let saved = try Data(contentsOf: Store.fileURL)
    for invalid in [
        Schedule(slots: first.slots, location: Coordinate(latitude: 91, longitude: 0)),
        Schedule(slots: [morning, morning]),
        Schedule(slots: [Slot(trigger: .clock(hour: 25, minute: 0), wallpaper: .image(path: "/bad"))]),
    ] {
        do {
            try Store.save(invalid)
            check(false, "非法配置不能覆盖原文件")
        } catch {
            let afterFailure = try Data(contentsOf: Store.fileURL)
            check(afterFailure == saved, "非法保存失败后原配置保持不变")
        }
    }
    let damaged = Data("{broken".utf8)
    try damaged.write(to: Store.fileURL)
    check((try? Store.load()) == nil, "损坏配置必须报错，不回退预设")
    let afterLoad = try Data(contentsOf: Store.fileURL)
    check(afterLoad == damaged, "读取失败保留原始配置供修复")
} catch {
    check(false, "配置边界检查可以完成：\(error)")
}

var newYork = Calendar(identifier: .gregorian)
newYork.timeZone = TimeZone(identifier: "America/New_York")!
let skippedClock = Trigger.clock(hour: 2, minute: 30)
let springDay = localDate("2026-03-08 12:00", calendar: newYork)
check(skippedClock.fireDate(on: springDay, coordinate: nil, calendar: newYork)
      == localDate("2026-03-08 03:00", calendar: newYork),
      "夏令时跳过的 02:30 在 03:00 补触发")
let repeatedClock = Trigger.clock(hour: 1, minute: 30)
let autumnDay = localDate("2026-11-01 12:00", calendar: newYork)
check(repeatedClock.fireDate(on: autumnDay, coordinate: nil, calendar: newYork)
      == ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"),
      "夏令时回拨的 01:30 只取第一次")
for slot in [morning, night] {
    let instant = slot.trigger.fireDate(on: noon, coordinate: nil, calendar: calendar)!
    check(clockSchedule.resolve(at: instant, calendar: calendar)?.active.id == slot.id,
          "恰好到达边界时新时段立即生效")
    check(clockSchedule.resolve(at: instant.addingTimeInterval(-0.001), calendar: calendar)?.active.id != slot.id,
          "边界前一毫秒仍是上一段")
}

// Compare cached scene evaluation with direct, uncached trigger evaluation across
// date/location/time-zone changes, including polar days and mixed trigger kinds.
for (zone, latitude, longitude, dayText) in [
    ("Asia/Shanghai", 22.543, 114.058, "2026-09-04 12:00"),
    ("America/New_York", 40.713, -74.006, "2026-03-08 03:00"),
    ("America/New_York", 40.713, -74.006, "2026-11-01 01:30"),
    ("Europe/Oslo", 69.65, 18.96, "2026-06-21 12:00"),
    ("Europe/Oslo", 69.65, 18.96, "2026-12-21 12:00"),
    ("Pacific/Auckland", -36.85, 174.76, "2026-09-27 03:00"),
] {
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: zone)!
    let instant = localDate(dayText, calendar: local)
    let place = Coordinate(latitude: latitude, longitude: longitude)
    var slots = DayPhase.allCases.flatMap { phase in
        (0..<8).map { index in
            Slot(trigger: .solarPhase(phase: phase, index: index, count: 8),
                 wallpaper: .image(path: "/fixture/\(phase)/\(index)"))
        }
    }
    slots += [morning, night, delayed, advanced,
              Slot(trigger: slots[0].trigger, wallpaper: .image(path: "/tie")),
              Slot(trigger: slots[1].trigger, wallpaper: .image(path: "/disabled"), enabled: false)]
    let mixed = Schedule(slots: slots, location: place)
    for location in [Optional(place), nil] {
        var expected: [(date: Date, slot: Slot, order: Int)] = []
        for (order, slot) in slots.enumerated() where slot.enabled {
            let anchor: Date
            if case .solar(_, let offset) = slot.trigger {
                anchor = instant.addingTimeInterval(-Double(offset) * 60)
            } else {
                anchor = instant
            }
            for offset in -1...1 {
                let day = local.date(byAdding: .day, value: offset, to: anchor)!
                if let date = slot.trigger.fireDate(on: day, coordinate: location, calendar: local) {
                    expected.append((date, slot, order))
                }
            }
        }
        expected.sort { $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date }
        let actual = mixed.firings(around: instant, coordinate: location, calendar: local)
        check(actual.count == expected.count && zip(actual, expected).allSatisfy {
            $0.date == $1.date && $0.slot == $1.slot
        }, "Cached scene firings match direct evaluation: \(zone), \(dayText), location=\(location != nil)")
    }
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项测试失败\n".utf8))
    exit(1)
}
print("\n全部模型测试通过")
