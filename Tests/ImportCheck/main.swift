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

// Use the literal /private/tmp spelling for HOURGLOW_HOME: URL.path normalizes it
// to /tmp and would hide this bug. /tmp is a symlink to /private/tmp, so URLs built
// here include /private while contentsOfDirectory returns paths without it.
// Comparing path strings during cleanup could mistake newly written assets for another scene and delete them.
let sandboxPath = "/private/tmp/hourglow-importcheck-\(UUID().uuidString)"
let sandbox = URL(fileURLWithPath: sandboxPath)
setenv("HOURGLOW_HOME", sandboxPath, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

// MARK: - Filenames

check(SceneImport.phase(from: "01_sunrise_1.heic") == .sunrise, "01_sunrise_1 maps to sunrise")
check(SceneImport.phase(from: "sunrise_2.HEIC") == .sunrise, "sunrise_2 maps to sunrise")
check(SceneImport.phase(from: "morning_3.jpg") == .sunrise, "morning is an alias for sunrise")
check(SceneImport.phase(from: "04_day_1.heic") == .day, "04_day_1 maps to day")
check(SceneImport.phase(from: "07_sunset_1.heic") == .sunset, "07_sunset_1 maps to sunset")
check(SceneImport.phase(from: "evening-2.png") == .sunset, "evening is an alias for sunset")
check(SceneImport.phase(from: "12_night_3.heic") == .night, "12_night_3 maps to night")
check(SceneImport.phase(from: "dusk_1.heic") == .sunset, "dusk maps to sunset")
check(SceneImport.phase(from: "dawn_1.heic") == .sunrise, "dawn maps to sunrise")
check(SceneImport.phase(from: "holiday.jpg") == nil, "holiday contains no phase keyword")
check(SceneImport.phase(from: "sunday.heic") == nil, "sunday does not falsely match day")

// MARK: - Twelve numbered images such as 01_sunrise_1

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
    check(skipped.isEmpty, "All twelve images are recognized without skipping any")
    check(files.count == 12, "All twelve numbered files are collected")
    check((grouped[.sunrise] ?? []).count == 3, "Three sunrise images")
    check((grouped[.day] ?? []).count == 3, "Three day images")
    check((grouped[.sunset] ?? []).count == 3, "Three sunset images")
    check((grouped[.night] ?? []).count == 3, "Three night images")
    check(names(grouped[.sunrise] ?? []) == ["01_sunrise_1.heic", "02_sunrise_2.heic", "03_sunrise_3.heic"],
          "Sunrise images sort by number")
    check(names(grouped[.night] ?? []).last == "12_night_3.heic", "The last night image is number twelve")
} catch {
    check(false, "The numbered-image folder is readable: \(error)")
}

// MARK: - Original 24 Hour Wallpaper names and multiple resolutions

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
    check(files.count == 19, "Multiple resolutions deduplicate to nineteen images")
    check(files.allSatisfy { $0.path.contains("5120x2880") }, "The higher-resolution copy is retained")
    check((grouped[.sunrise] ?? []).count == 4, "Four sunrise images")
    check((grouped[.day] ?? []).count == 6, "Six day images")
    check((grouped[.sunset] ?? []).count == 4, "Four sunset images")
    check((grouped[.night] ?? []).count == 5, "Five night images")
} catch {
    check(false, "sundialScene is readable: \(error)")
}

// MARK: - Evenly dividing four phases without keywords

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
          "Twelve unnamed images divide evenly into 3+3+3+3")
    check(names(grouped[.sunrise] ?? []).first == "frame_01.jpg", "Even division preserves filename order")
} catch {
    check(false, "The unnamed-image folder is readable: \(error)")
}

// MARK: - apply creates solarPhase slots

do {
    let schedule = try SceneImport.apply(folder: numbered, to: Schedule(), name: "zhangjiajie").schedule
    check(schedule.slots.count == 12, "Import creates twelve slots")
    check(schedule.slots.allSatisfy {
        if case .solarPhase = $0.trigger { return true } else { return false }
    }, "All triggers are solarPhase")
    if case .solarPhase(let phase, let index, let count) = schedule.slots.first?.trigger {
        check(phase == .sunrise && index == 0 && count == 3, "The first image is sunrise 1/3")
    } else {
        check(false, "The first image has a solarPhase trigger")
    }
    if case .solarPhase(let phase, let index, let count) = schedule.slots.last?.trigger {
        check(phase == .night && index == 2 && count == 3, "The last image is night 3/3")
    } else {
        check(false, "The last image has a solarPhase trigger")
    }
    let dest = SceneImport.scenesDirectory.appendingPathComponent("zhangjiajie")
    check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("sunrise_1.heic").path),
          "Images are copied into Scenes/<slug>/")
} catch {
    check(false, "apply succeeds: \(error)")
}

do {
    let picked = [
        numbered.appendingPathComponent("01_sunrise_1.heic"),
        numbered.appendingPathComponent("04_day_1.heic"),
        numbered.appendingPathComponent("07_sunset_1.heic"),
        numbered.appendingPathComponent("10_night_1.heic"),
    ]
    let schedule = try SceneImport.apply(urls: picked, to: Schedule(), name: "picked").schedule
    check(schedule.slots.count == 4, "Four directly selected images can also be imported")
    check(schedule.slots.map { slot -> DayPhase? in
        if case .solarPhase(let phase, _, _) = slot.trigger { return phase }
        return nil
    } == [.sunrise, .day, .sunset, .night], "The four images each map to a different phase")
} catch {
    check(false, "Multi-file apply succeeds: \(error)")
}

// MARK: - Phase subdirectories with filenames numbered from one
//
// Using only the bare filename as the deduplication key merged sunrise/1.jpg and night/1.jpg
// as resolutions of the same image: twelve images went in, three came out, and import still reported success.

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
    check(files.count == 12, "Identical filenames in separate subdirectories preserve all twelve images")
    let (grouped, skipped) = SceneImport.group(files, root: foldered)
    check(skipped.isEmpty, "Recognized parent-folder phase names prevent skipped images")
    check((grouped[.sunrise] ?? []).count == 3
          && (grouped[.day] ?? []).count == 3
          && (grouped[.sunset] ?? []).count == 3
          && (grouped[.night] ?? []).count == 3,
          "Parent folder names group images into four phases")
    // Without root, do not guess: none of these filenames identify phases, so divide evenly.
    let (blind, _) = SceneImport.group(files, root: nil)
    check((blind[.sunrise] ?? []).count == 3, "Without root, grouping falls back to even division")
} catch {
    check(false, "The phase-subdirectory folder is readable: \(error)")
}

// MARK: - Report unrecognized images instead of silently dropping them

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
    check(outcome.schedule.slots.count == 6, "Only the six recognized images are imported")
    check(outcome.skipped.count == 4, "The other four images are reported as skipped")
    check(Set(outcome.skipped.map(\.lastPathComponent))
          == Set(["IMG_0041.jpg", "IMG_0042.jpg", "IMG_0043.jpg", "IMG_0044.jpg"]),
          "The reported images are exactly the unrecognized ones")
    try Store.save(outcome.schedule)
} catch {
    check(false, "Mixed-folder apply succeeds: \(error)")
}

// MARK: - Replacing a scene removes its old assets

do {
    let scenes = SceneImport.scenesDirectory
    let stale = scenes.appendingPathComponent("mixed")
    check(FileManager.default.fileExists(atPath: stale.path), "The previous scene's assets still exist")
    let latest = try SceneImport.apply(folder: numbered, to: Schedule(), name: "latest")
    check(FileManager.default.fileExists(atPath: stale.path),
          "Writing new assets does not delete old assets before the configuration is committed")
    try Store.save(latest.schedule)
    SceneImport.finalize(latest)
    check(!FileManager.default.fileExists(atPath: stale.path), "Importing a new scene removes old assets")
    check(FileManager.default.fileExists(atPath:
        scenes.appendingPathComponent("latest/sunrise_1.heic").path), "New assets are in place")
    let fresh = try SceneImport.apply(folder: numbered, to: Schedule(), name: "again")
    try Store.save(fresh.schedule)
    SceneImport.finalize(fresh)
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "Every image referenced by the timeline remains on disk after cleanup")

    // Reimporting the same name must not overwrite again/: if saving fails, the old configuration still uses it.
    // Write a unique directory first so the caller can discard it without affecting the old timeline.
    let replacement = FileManager.default.temporaryDirectory
        .appendingPathComponent("hourglow-scene-replacement-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: replacement) }
    touch(replacement.appendingPathComponent("sunrise_1.jpg"), bytes: 64)
    let pending = try SceneImport.apply(folder: replacement, to: fresh.schedule, name: "again")
    check(pending.destination.path != fresh.destination.path,
          "Same-name import uses a new directory instead of overwriting assets referenced by the old configuration")
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "All old timeline images remain before a same-name import is committed")
    SceneImport.discard(pending)
    check(!FileManager.default.fileExists(atPath: pending.destination.path),
          "A failed configuration save removes the new assets")
    check(fresh.schedule.slots.allSatisfy { slot in
        guard case .image(let path) = slot.wallpaper else { return false }
        return FileManager.default.fileExists(atPath: path)
    }, "Discarding a failed import leaves the old timeline usable")

    // Imports may run concurrently: A copies first, then B commits the authoritative configuration to disk.
    // A must reload that configuration during cleanup rather than deleting B's assets based on its own outcome.
    let raceA = try SceneImport.apply(folder: numbered, to: fresh.schedule, name: "race-a")
    let raceB = try SceneImport.apply(folder: numbered, to: fresh.schedule, name: "race-b")
    try Store.save(raceB.schedule)
    SceneImport.finalize(raceA)
    check(FileManager.default.fileExists(atPath: raceB.destination.path),
          "Cleanup by an older concurrent import preserves new assets referenced by the on-disk configuration")
    check(!FileManager.default.fileExists(atPath: raceA.destination.path),
          "Uncommitted assets from a concurrent import are removed")
    SceneImport.finalize(raceB)
} catch {
    check(false, "Old-asset cleanup succeeds: \(error)")
}

// MARK: - Only number x number identifies a resolution directory

let oddly = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-scene-odd-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: oddly) }
touch(oddly.appendingPathComponent("extra/sunrise_1.jpg"))
touch(oddly.appendingPathComponent("extras/sunrise_2.jpg"))
do {
    let files = try SceneImport.listImages(in: oddly)
    check(files.count == 2, "`extra` is not a resolution directory, so both images remain")
} catch {
    check(false, "The unusually named folder is readable: \(error)")
}

// External directory names must not overflow resolution-score multiplication; image extensions do not make directories images.
let extreme = sandbox.appendingPathComponent("extreme")
touch(extreme.appendingPathComponent("9223372036854775807x2/day.jpg"))
try? FileManager.default.createDirectory(at: extreme.appendingPathComponent("night.jpg"),
                                         withIntermediateDirectories: true)
do {
    let files = try SceneImport.listImages(in: extreme)
    check(files.count == 1 && files.first?.lastPathComponent == "day.jpg",
          "Huge resolution directories do not crash, and directories with image extensions are not assets")
} catch { check(false, "Extreme directory names can be scanned: \(error)") }

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) import checks failed\n".utf8))
    exit(1)
}
print("\nAll import checks passed")
