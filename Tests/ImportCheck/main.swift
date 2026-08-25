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

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-importcheck-\(UUID().uuidString)")
setenv("HOURGLOW_HOME", sandbox.path, 1)
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
    let grouped = SceneImport.group(files)
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
    let grouped = SceneImport.group(files)
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
    let grouped = SceneImport.group(try SceneImport.listImages(in: plain))
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
    let schedule = try SceneImport.apply(folder: numbered, to: Schedule(), name: "zhangjiajie")
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
    let schedule = try SceneImport.apply(urls: picked, to: Schedule(), name: "picked")
    check(schedule.slots.count == 4, "直接选中的 4 张图也能导入")
    check(schedule.slots.map { slot -> DayPhase? in
        if case .solarPhase(let phase, _, _) = slot.trigger { return phase }
        return nil
    } == [.sunrise, .day, .sunset, .night], "4 张分别进四段")
} catch {
    check(false, "多文件 apply 成功：\(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项导入测试失败\n".utf8))
    exit(1)
}
print("\n全部导入测试通过")
