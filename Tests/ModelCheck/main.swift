import Foundation

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

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项测试失败\n".utf8))
    exit(1)
}
print("\n全部模型测试通过")
