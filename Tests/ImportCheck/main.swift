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

private func touch(_ url: URL, bytes: Int = 8) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? Data(repeating: 0xFF, count: bytes).write(to: url)
}

private func names(_ urls: [URL]) -> [String] {
    urls.map(\.lastPathComponent)
}

// 沙箱用 `/private/tmp` 那个拼法，而且原样交给 `HOURGLOW_HOME`（`URL.path` 会把它
// 归一成 `/tmp`，那就试不出问题了）。`/tmp` 是指向 `/private/tmp` 的软链：同一个目录，
// 自己拼出来的 URL 带 `/private`、`contentsOfDirectory` 拿回来的不带。清理旧素材时
// 若按字符串比路径，就会把刚写好的那一套当成「别人的」删掉。
let sandboxPath = "/private/tmp/hourglow-importcheck-\(UUID().uuidString)"
let sandbox = URL(fileURLWithPath: sandboxPath)
setenv("HOURGLOW_HOME", sandboxPath, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

// MARK: - 文件名

check(SceneImport.phase(from: "01_sunrise_1.heic") == .sunrise, "01_sunrise_1 归入日出")
check(SceneImport.phase(from: "sunrise_2.HEIC") == .sunrise, "sunrise_2 归入日出")
check(SceneImport.phase(from: "morning_3.jpg") == .sunrise, "morning 是日出的别名")
check(SceneImport.phase(from: "04_day_1.heic") == .day, "04_day_1 归入白昼")
check(SceneImport.phase(from: "07_sunset_1.heic") == .sunset, "07_sunset_1 归入日落")
check(SceneImport.phase(from: "evening-2.png") == .sunset, "evening 是日落的别名")
check(SceneImport.phase(from: "12_night_3.heic") == .night, "12_night_3 归入夜晚")
check(SceneImport.phase(from: "dusk_1.heic") == .sunset, "dusk 归入日落")
check(SceneImport.phase(from: "dawn_1.heic") == .sunrise, "dawn 归入日出")
check(SceneImport.phase(from: "holiday.jpg") == nil, "holiday 不含时段关键词")
check(SceneImport.phase(from: "sunday.heic") == nil, "sunday 不会被 day 误伤")

// MARK: - 01_sunrise_1 这种 12 张

let numbered = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-numbered-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: numbered) }
for name in [
    "01_sunrise_1.heic", "02_sunrise_2.heic", "03_sunrise_3.heic",
    "04_day_1.heic", "05_day_2.heic", "06_day_3.heic",
    "07_sunset_1.heic", "08_sunset_2.heic", "09_sunset_3.heic",
    "10_night_1.heic", "11_night_2.heic", "12_night_3.heic",
] {
    touch(numbered.appendingPathComponent(name))
}
do {
    let files = try SceneImport.listImages(in: numbered)
    let (grouped, skipped) = SceneImport.group(files, root: numbered)
    check(skipped.isEmpty, "12 张全部认得出，没有跳过的")
    check(files.count == 12, "12 张编号文件全部收进来")
    check((grouped[.sunrise] ?? []).count == 3, "3 张日出")
    check((grouped[.day] ?? []).count == 3, "3 张白昼")
    check((grouped[.sunset] ?? []).count == 3, "3 张日落")
    check((grouped[.night] ?? []).count == 3, "3 张夜晚")
    check(names(grouped[.sunrise] ?? []) == ["01_sunrise_1.heic", "02_sunrise_2.heic", "03_sunrise_3.heic"],
          "日出按编号排序")
    check(names(grouped[.night] ?? []).last == "12_night_3.heic", "夜晚最后一张是 12")
} catch {
    check(false, "编号文件夹可读：\(error)")
}

// MARK: - 24 Hour Wallpaper 原名 + 多分辨率

let sundial = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tokyo_anime_24h.sundialScene")
defer { try? FileManager.default.removeItem(at: sundial) }
let small = sundial.appendingPathComponent("images/2560x1440")
let large = sundial.appendingPathComponent("images/5120x2880")
for name in [
    "sunrise_1.heic", "sunrise_2.heic", "sunrise_3.heic", "sunrise_4.heic",
    "day_1.heic", "day_2.heic", "day_3.heic", "day_4.heic", "day_5.heic", "day_6.heic",
    "sunset_1.heic", "sunset_2.heic", "sunset_3.heic", "sunset_4.heic",
    "night_1.heic", "night_2.heic", "night_3.heic", "night_4.heic", "night_5.heic",
] {
    touch(small.appendingPathComponent(name), bytes: 10)
    touch(large.appendingPathComponent(name), bytes: 40)
}
do {
    let files = try SceneImport.listImages(in: sundial)
    let (grouped, _) = SceneImport.group(files, root: sundial)
    check(files.count == 19, "多分辨率只留一份，19 张")
    check(files.allSatisfy { $0.path.contains("5120x2880") }, "留下分辨率更大的那份")
    check((grouped[.sunrise] ?? []).count == 4, "4 张日出")
    check((grouped[.day] ?? []).count == 6, "6 张白昼")
    check((grouped[.sunset] ?? []).count == 4, "4 张日落")
    check((grouped[.night] ?? []).count == 5, "5 张夜晚")
} catch {
    check(false, "sundialScene 可读：\(error)")
}

// MARK: - 无关键词时均分成四段

let plain = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-plain-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: plain) }
for i in 1...12 {
    touch(plain.appendingPathComponent(String(format: "frame_%02d.jpg", i)))
}
do {
    let (grouped, _) = SceneImport.group(try SceneImport.listImages(in: plain), root: plain)
    check((grouped[.sunrise] ?? []).count == 3
          && (grouped[.day] ?? []).count == 3
          && (grouped[.sunset] ?? []).count == 3
          && (grouped[.night] ?? []).count == 3,
          "12 张无名图均分成 3+3+3+3")
    check(names(grouped[.sunrise] ?? []).first == "frame_01.jpg", "均分保持文件名顺序")
} catch {
    check(false, "无名文件夹可读：\(error)")
}

// MARK: - apply 写出 solarPhase 时段

do {
    let schedule = try SceneImport.apply(folder: numbered, to: Schedule(), name: "zhangjiajie").schedule
    check(schedule.slots.count == 12, "导入写出 12 个时段")
    check(schedule.slots.allSatisfy {
        if case .solarPhase = $0.trigger { return true } else { return false }
    }, "全部是 solarPhase")
    if case .solarPhase(let phase, let index, let count) = schedule.slots.first?.trigger {
        check(phase == .sunrise && index == 0 && count == 3, "第一张是日出 1/3")
    } else {
        check(false, "第一张触发条件是 solarPhase")
    }
    if case .solarPhase(let phase, let index, let count) = schedule.slots.last?.trigger {
        check(phase == .night && index == 2 && count == 3, "最后一张是夜晚 3/3")
    } else {
        check(false, "最后一张触发条件是 solarPhase")
    }
    let dest = SceneImport.scenesDirectory.appendingPathComponent("zhangjiajie")
    check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("sunrise_1.heic").path),
          "图片拷到 Scenes/<slug>/")
} catch {
    check(false, "apply 成功：\(error)")
}

do {
    let picked = [
        numbered.appendingPathComponent("01_sunrise_1.heic"),
        numbered.appendingPathComponent("04_day_1.heic"),
        numbered.appendingPathComponent("07_sunset_1.heic"),
        numbered.appendingPathComponent("10_night_1.heic"),
    ]
    let schedule = try SceneImport.apply(urls: picked, to: Schedule(), name: "picked").schedule
    check(schedule.slots.count == 4, "直接选中的 4 张图也能导入")
    check(schedule.slots.map { slot -> DayPhase? in
        if case .solarPhase(let phase, _, _) = slot.trigger { return phase }
        return nil
    } == [.sunrise, .day, .sunset, .night], "4 张分别进四段")
} catch {
    check(false, "多文件 apply 成功：\(error)")
}

// MARK: - 按段分子目录、文件名从 1 编号
//
// 归并键曾经是光秃秃的文件名，`sunrise/1.jpg` 与 `night/1.jpg` 会被当成
// 「同一张图的两个分辨率」并成一张：12 张进去、3 张出来，还报「已导入」成功。

let foldered = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-foldered-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: foldered) }
for phase in ["sunrise", "day", "sunset", "night"] {
    for i in 1...3 {
        touch(foldered.appendingPathComponent("\(phase)/\(i).jpg"))
    }
}
do {
    let files = try SceneImport.listImages(in: foldered)
    check(files.count == 12, "分子目录的同名文件不互相吞：12 张都在")
    let (grouped, skipped) = SceneImport.group(files, root: foldered)
    check(skipped.isEmpty, "上级文件夹名认得出时段，没有跳过的")
    check((grouped[.sunrise] ?? []).count == 3
          && (grouped[.day] ?? []).count == 3
          && (grouped[.sunset] ?? []).count == 3
          && (grouped[.night] ?? []).count == 3,
          "按上级文件夹名归入四段")
    // 没有 root 就不该乱猜：只看文件名的话这 12 张一个都认不出，均分成四段。
    let (blind, _) = SceneImport.group(files, root: nil)
    check((blind[.sunrise] ?? []).count == 3, "没有 root 时退回均分")
} catch {
    check(false, "分子目录文件夹可读：\(error)")
}

// MARK: - 认不出的那几张要报出来，不能默默丢掉

let mixed = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-mixed-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: mixed) }
for i in 1...3 {
    touch(mixed.appendingPathComponent("sunrise_\(i).jpg"))
    touch(mixed.appendingPathComponent("sunset_\(i).jpg"))
}
for i in 1...4 {
    touch(mixed.appendingPathComponent("IMG_004\(i).jpg"))
}
do {
    let outcome = try SceneImport.apply(folder: mixed, to: Schedule(), name: "mixed")
    check(outcome.schedule.slots.count == 6, "只收认得出的 6 张")
    check(outcome.skipped.count == 4, "另外 4 张作为 skipped 报出来")
    check(Set(outcome.skipped.map(\.lastPathComponent))
          == Set(["IMG_0041.jpg", "IMG_0042.jpg", "IMG_0043.jpg", "IMG_0044.jpg"]),
          "报出来的正是认不出的那几张")
    try Store.save(outcome.schedule)
} catch {
    check(false, "混合文件夹 apply 成功：\(error)")
}

// MARK: - 换一套壁纸后，上一套的素材不再留着占地方

do {
    let scenes = SceneImport.scenesDirectory
    let stale = scenes.appendingPathComponent("mixed")
    check(FileManager.default.fileExists(atPath: stale.path), "上一套素材此刻还在")
    let latest = try SceneImport.apply(folder: numbered, to: Schedule(), name: "latest")
    check(FileManager.default.fileExists(atPath: stale.path),
          "新素材写好但配置尚未提交时不会提前删除旧素材")
    try Store.save(latest.schedule)
    SceneImport.finalize(latest)
    check(!FileManager.default.fileExists(atPath: stale.path), "导入新的一套后旧素材被清掉")
    check(FileManager.default.fileExists(atPath:
        scenes.appendingPathComponent("latest/sunrise_1.heic").path), "新素材在位")
    let fresh = try SceneImport.apply(folder: numbered, to: Schedule(), name: "again")
    try Store.save(fresh.schedule)
    SceneImport.finalize(fresh)
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "清理之后，时间轴引用的每一张图都还在盘上")

    // 同名再次导入不能先覆盖 `again/`：保存若失败，旧配置仍会引用那一目录。
    // 新实现先写唯一目录，调用方可以 discard，旧时间轴完全不受影响。
    let replacement = FileManager.default.temporaryDirectory
        .appendingPathComponent("hourglow-scene-replacement-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: replacement) }
    touch(replacement.appendingPathComponent("sunrise_1.jpg"), bytes: 64)
    let pending = try SceneImport.apply(folder: replacement, to: fresh.schedule, name: "again")
    check(pending.destination.path != fresh.destination.path,
          "同名导入写入新目录，不覆盖仍被旧配置引用的素材")
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "同名导入提交前旧时间轴的全部图片仍在")
    SceneImport.discard(pending)
    check(!FileManager.default.fileExists(atPath: pending.destination.path),
          "配置保存失败时撤掉本次新素材")
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "撤销失败导入后旧时间轴仍可用")

    // 两个进程可能同时导入。A 先复制、B 后提交成磁盘上的权威配置；A 随后清理时
    // 必须重新读配置，不能按自己的 outcome 把 B 的素材删掉。
    let raceA = try SceneImport.apply(folder: numbered, to: fresh.schedule, name: "race-a")
    let raceB = try SceneImport.apply(folder: numbered, to: fresh.schedule, name: "race-b")
    try Store.save(raceB.schedule)
    SceneImport.finalize(raceA)
    check(FileManager.default.fileExists(atPath: raceB.destination.path),
          "并发导入的旧任务清理时会保留磁盘配置正在引用的新素材")
    check(!FileManager.default.fileExists(atPath: raceA.destination.path),
          "并发导入中没有提交的素材会被清掉")
    SceneImport.finalize(raceB)
} catch {
    check(false, "清理旧素材：\(error)")
}

// MARK: - 只有「数字 x 数字」才算分辨率层

let oddly = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-odd-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: oddly) }
touch(oddly.appendingPathComponent("extra/sunrise_1.jpg"))
touch(oddly.appendingPathComponent("extras/sunrise_2.jpg"))
do {
    let files = try SceneImport.listImages(in: oddly)
    check(files.count == 2, "`extra` 不是分辨率层，两张都在")
} catch {
    check(false, "怪名字文件夹可读：\(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项导入测试失败\n".utf8))
    exit(1)
}
print("\n全部导入测试通过")
