import Foundation

// Run localized city-name scenarios explicitly in English, independent of source language.
// Language selection itself is covered separately by l10ncheck.
setenv("HOURGLOW_LANG", "en", 1)
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
        fatalError("Invalid test date: \(text)")
    }
    return date
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let coordinate = Coordinate(latitude: 31.2333, longitude: 121.4667)

// After midnight, clock triggers carry over the previous day's final slot and find today's first switch.
let morning = Slot(trigger: .clock(hour: 9, minute: 0), wallpaper: .image(path: "/morning"))
let night = Slot(trigger: .clock(hour: 21, minute: 0), wallpaper: .image(path: "/night"))
let clockSchedule = Schedule(slots: [morning, night], location: coordinate)
let afterMidnight = localDate("2026-08-22 01:00", calendar: calendar)
let clockResolution = clockSchedule.resolve(at: afterMidnight, calendar: calendar)
check(clockResolution?.active.id == night.id, "Clock triggers carry over the previous day after midnight")
check(clockResolution?.next?.slot.id == morning.id, "Clock triggers find the next switch today")

// Simultaneous slots need a stable winner, and the next-switch preview must match the eventual active slot.
// Sorting only by Date left ties unspecified; next also chose the first while active chose the last.
let sameTimeFirst = Slot(trigger: .clock(hour: 9, minute: 0),
                         wallpaper: .image(path: "/same-first"))
let sameTimeLast = Slot(trigger: .clock(hour: 9, minute: 0),
                        wallpaper: .image(path: "/same-last"))
let sameTimeSchedule = Schedule(slots: [sameTimeFirst, sameTimeLast])
let beforeSameTime = localDate("2026-08-22 08:00", calendar: calendar)
let afterSameTime = localDate("2026-08-22 10:00", calendar: calendar)
check(sameTimeSchedule.resolve(at: beforeSameTime, calendar: calendar)?.next?.slot.id
      == sameTimeLast.id,
      "The next-switch preview selects the later configured slot when trigger times tie")
check(sameTimeSchedule.resolve(at: afterSameTime, calendar: calendar)?.active.id
      == sameTimeLast.id,
      "The later configured slot consistently wins when trigger times tie")

// Offsets can span multiple calendar days. Expanding only ±1 day around now
// previously made '48 hours after sunrise' fail to resolve on its trigger day.
let delayed = Slot(trigger: .solar(event: .sunrise, offsetMinutes: 48 * 60),
                   wallpaper: .image(path: "/delayed"))
let delayedSchedule = Schedule(slots: [delayed], location: coordinate)
let noon = localDate("2026-08-22 12:00", calendar: calendar)
let delayedResolution = delayedSchedule.resolve(at: noon, calendar: calendar)
check(delayedResolution?.active.id == delayed.id, "Solar triggers support positive offsets longer than a day")
check(delayedResolution.map { $0.since <= noon } ?? false, "A positive-offset active trigger is not in the future")
check((delayedResolution?.next?.at ?? .distantPast) > noon, "Positive offsets still find the next switch")

let advanced = Slot(trigger: .solar(event: .sunset, offsetMinutes: -48 * 60),
                    wallpaper: .image(path: "/advanced"))
let advancedSchedule = Schedule(slots: [advanced], location: coordinate)
let advancedResolution = advancedSchedule.resolve(at: noon, calendar: calendar)
check(advancedResolution?.active.id == advanced.id, "Solar triggers support negative offsets longer than a day")
check((advancedResolution?.next?.at ?? .distantPast) > noon, "Negative offsets still find the next switch")

let homeImage = Wallpaper.image(path: "~/Pictures/hour glow.jpg")
let absoluteImage = Wallpaper.image(
    path: ("~/Pictures/hour glow.jpg" as NSString).expandingTildeInPath)
check(WallpaperWriter.normalized(homeImage) == WallpaperWriter.normalized(absoluteImage),
      "Image paths expand tildes before comparison")

let relativeImage = Wallpaper.image(path: "Pictures/../Pictures/hour glow.jpg")
let workingDirectoryImage = Wallpaper.image(
    path: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Pictures/hour glow.jpg").path)
check(WallpaperWriter.normalized(relativeImage) == WallpaperWriter.normalized(workingDirectoryImage),
      "Image paths become normalized absolute paths before comparison")

do {
    let legacy = Data("""
        {"slots":[{"trigger":{"type":"clock","hour":9},
                    "wallpaper":{"type":"image","path":"/legacy.jpg"}}]}
        """.utf8)
    let migrated = try Store.decode(legacy)
    check(migrated.needsIDMigration, "Legacy configurations without slot IDs are marked for migration")

    let encoded = try JSONEncoder().encode(migrated.schedule)
    let reloaded = try Store.decode(encoded)
    check(!reloaded.needsIDMigration, "A saved configuration does not migrate again")
    check(reloaded.schedule.slots.first?.id == migrated.schedule.slots.first?.id,
          "Generated slot IDs remain stable after saving")
} catch {
    check(false, "Legacy configuration migration completes: \(error)")
}

check(ApproxLocation.parseISO6709("+3114+12128")
      == Coordinate(latitude: 31 + 14.0 / 60, longitude: 121 + 28.0 / 60),
      "ISO 6709 degree-minute coordinates parse correctly")
check(ApproxLocation.parseISO6709("+513030-0000731")
      == Coordinate(latitude: 51 + 30.0 / 60 + 30.0 / 3600,
                    longitude: -(7.0 / 60 + 31.0 / 3600)),
      "ISO 6709 degree-minute-second coordinates parse correctly")
check(ApproxLocation.parseISO6709("+3199+12128") == nil,
      "ISO 6709 parsing rejects invalid minutes")
check(ApproxLocation.parseISO6709("+31xx+12128") == nil,
      "ISO 6709 parsing rejects nonnumeric fields")
check(ApproxLocation.parseISO6709("+9001+12128") == nil,
      "ISO 6709 parsing rejects out-of-range latitudes")

// MARK: - Saving the preset on first launch
//
// This requires an empty directory: the branch does not run when the file already exists.
// HOURGLOW_HOME enables this isolation (NSHomeDirectory() uses the account's real home on macOS;
// changing $HOME has no effect). All writes stay in temporary directories, away from real configuration.

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-modelcheck-\(UUID().uuidString)")
setenv("HOURGLOW_HOME", sandbox.path, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

check(Store.directoryURL == sandbox, "HOURGLOW_HOME redirects the entire configuration directory")
check(!FileManager.default.fileExists(atPath: Store.fileURL.path), "The scenario starts in an empty directory")

let firstRun = (try? Store.load()) ?? Schedule()
check(FileManager.default.fileExists(atPath: Store.fileURL.path),
      "First launch saves the preset to disk")
check(firstRun.slots.count == 4, "The preset has four slots")
check(firstRun.slots.map(\.trigger) == [
        .solar(event: .sunrise, offsetMinutes: 0),
        .clock(hour: 9, minute: 0),
        .solar(event: .sunset, offsetMinutes: -30),
        .solar(event: .sunset, offsetMinutes: 60),
      ], "The preset triggers at sunrise / 09:00 / 30 minutes before sunset / 60 minutes after sunset")
check(firstRun.slots.map(\.wallpaper) == [
        .aerial(assetID: Tahoe.morning), .aerial(assetID: Tahoe.day),
        .aerial(assetID: Tahoe.evening), .aerial(assetID: Tahoe.night),
      ], "The preset uses the four Tahoe wallpapers")
// Changing IDs on each launch would look like a slot change and override the user's manual wallpaper.
check((try? Store.load())?.slots.map(\.id) == firstRun.slots.map(\.id),
      "Reloading preserves the slot IDs saved on first launch")

// Empty searches sort by distance: near Huiyang, Huizhou (its parent city) precedes the catalog's Zhangjiajie.
let nearHuiyang = Cities.search("", near: Coordinate(latitude: 22.7984, longitude: 114.6784))
check(nearHuiyang.first?.name == "Huizhou", "An empty search near Huiyang puts Huizhou first")
check(nearHuiyang.count == Cities.nearbyCount, "An empty search returns only \(Cities.nearbyCount) nearby cities")
check(nearHuiyang.filter { $0.name == "Hong Kong" }.count == 1, "The curated catalog and zone.tab deduplicate Hong Kong")
check(!nearHuiyang.contains { $0.name == "London" }, "London is not in the nearby list for Huiyang")
let nearPortland = Cities.search("", near: Coordinate(latitude: 45.5152, longitude: -122.6784))
check(nearPortland.first?.name == "Seattle", "Seattle comes first near Portland")
check(Cities.search("").first?.name == "Zhangjiajie", "Without coordinates, search retains catalog order")
check(Cities.search("深圳", near: Coordinate(latitude: 45.5, longitude: -122.7)).first?.name == "Shenzhen",
      "Coordinates do not affect results for a nonempty Chinese query")
// Substring fallback could silently select a distant city for a typo (lookup("a") → Abidjan).
check(Cities.lookup("a") == nil, "A single letter does not use fuzzy fallback")
check(Cities.lookup("深")?.name == "Shenzhen", "A matching Chinese prefix still finds the city")
check(Cities.lookup("shenzhen")?.name == "Shenzhen", "Pinyin finds Shenzhen")

// MARK: - Solar phases

let shenzhen = Coordinate(latitude: 22.543, longitude: 114.058, name: "深圳")
let solstice = localDate("2026-12-21 12:00", calendar: calendar)
guard let windows = TimeMap.windows(on: solstice, coordinate: shenzhen, calendar: calendar) else {
    check(false, "Solar phase windows resolve on the winter solstice")
    fatalError("no windows")
}
check(windows.sunrise.start < windows.sunrise.end, "The sunrise window has positive duration")
check(windows.sunrise.end == windows.day.start, "Sunrise connects to day")
check(windows.day.end == windows.sunset.start, "Day connects to sunset")
check(windows.sunset.end == windows.night.start, "Sunset connects to night")
check(windows.night.end > windows.night.start, "The night window has positive duration across midnight")

let three = TimeMap.fireDate(phase: .sunrise, index: 0, count: 3,
                             on: solstice, coordinate: shenzhen, calendar: calendar)
let five = TimeMap.fireDate(phase: .sunrise, index: 0, count: 5,
                            on: solstice, coordinate: shenzhen, calendar: calendar)
check(three == five, "The first sunrise image starts at the same boundary for three or five images")

let sunriseLast3 = TimeMap.fireDate(phase: .sunrise, index: 2, count: 3,
                                    on: solstice, coordinate: shenzhen, calendar: calendar)
let sunriseMid3 = TimeMap.fireDate(phase: .sunrise, index: 1, count: 3,
                                   on: solstice, coordinate: shenzhen, calendar: calendar)
if let a = three, let b = sunriseMid3, let c = sunriseLast3 {
    let step = b.timeIntervalSince(a)
    check(abs(c.timeIntervalSince(b) - step) < 1, "Images are evenly spaced within a phase")
    check(c < windows.sunrise.end, "The last image stays inside its window without reaching the next phase")
} else {
    check(false, "All three sunrise images have trigger times")
}

let nightLast = TimeMap.fireDate(phase: .night, index: 2, count: 3,
                                 on: solstice, coordinate: shenzhen, calendar: calendar)
if let nightLast {
    check(!calendar.isDate(nightLast, inSameDayAs: solstice)
          || nightLast >= windows.night.start,
          "The final night images may fall early the following day")
} else {
    check(false, "The last night image has a trigger time")
}

// MARK: - High latitudes: days without dawn or dusk
//
// Solar.events returns nil when the sun never drops below −12°/−6°. Falling back to sunrise/sunset
// made the dawn-to-sunrise window zero-length, then max(_, 60) stretched it to just 60 seconds.
// Three wallpapers switched 20 seconds apart, also running killall on WallpaperAgent three times.

var arctic = Calendar(identifier: .gregorian)
arctic.timeZone = TimeZone(identifier: "Europe/Oslo")!
let tromso = Coordinate(latitude: 69.65, longitude: 18.96, name: "Tromsø")
let august = localDate("2026-08-20 12:00", calendar: arctic)
let arcticEvents = Solar.events(on: august, at: tromso, calendar: arctic)
check(arcticEvents?.nauticalDawn == nil, "Tromsø has no nautical dawn on August 20")
if let arcticWindows = TimeMap.windows(on: august, coordinate: tromso, calendar: arctic) {
    let span = arcticWindows.sunrise.end.timeIntervalSince(arcticWindows.sunrise.start)
    check(span > 30 * 60, "Missing dawn uses a nominal duration instead of shrinking sunrise to seconds")
    let first = TimeMap.fireDate(phase: .sunrise, index: 0, count: 3,
                                 on: august, coordinate: tromso, calendar: arctic)
    let second = TimeMap.fireDate(phase: .sunrise, index: 1, count: 3,
                                  on: august, coordinate: tromso, calendar: arctic)
    if let first, let second {
        check(second.timeIntervalSince(first) > 5 * 60, "Sunrise images remain several minutes apart")
    } else {
        check(false, "Trigger times still resolve after the fallback")
    }
    check(arcticWindows.day.start < arcticWindows.day.end, "The fallback leaves the day window positive")
    check(arcticWindows.night.start < arcticWindows.night.end, "The fallback leaves the night window positive")
} else {
    check(false, "Solar phase windows resolve in Tromsø in August")
}

let midnightSun = localDate("2026-06-21 12:00", calendar: arctic)
check(TimeMap.windows(on: midnightSun, coordinate: tromso, calendar: arctic) == nil,
      "Polar day has no windows, so solar phase slots are skipped entirely")

let phaseSlot = Slot(trigger: .solarPhase(phase: .sunset, index: 1, count: 3),
                     wallpaper: .image(path: "/sunset_2.heic"))
let phaseSchedule = Schedule(slots: [phaseSlot], location: shenzhen)
let dusk = localDate("2026-12-21 23:00", calendar: calendar)
let phaseResolution = phaseSchedule.resolve(at: dusk, calendar: calendar)
check(phaseResolution?.active.id == phaseSlot.id, "solarPhase resolves")
check((phaseResolution?.next?.at ?? .distantPast) > dusk, "solarPhase finds the next switch")

do {
    let encoded = try JSONEncoder().encode(phaseSlot.trigger)
    let decoded = try JSONDecoder().decode(Trigger.self, from: encoded)
    check(decoded == phaseSlot.trigger, "solarPhase survives a JSON round trip")
    let legacy = Data(#"{"type":"solarPhase","phase":"sunrise","index":0,"count":3}"#.utf8)
    let loaded = try JSONDecoder().decode(Trigger.self, from: legacy)
    check(loaded == .solarPhase(phase: .sunrise, index: 0, count: 3),
          "Handwritten solarPhase JSON decodes")
} catch {
    check(false, "solarPhase Codable: \(error)")
}

// MARK: - Pre-release input boundaries

for trigger in [
    #"{"type":"clock","hour":24}"#,
    #"{"type":"clock","hour":-1}"#,
    #"{"type":"clock","hour":12,"minute":60}"#,
    #"{"type":"clock","hour":12,"minute":-1}"#,
] {
    check((try? JSONDecoder().decode(Trigger.self, from: Data(trigger.utf8))) == nil,
          "Invalid clock times cannot decode: \(trigger)")
}
for (latitude, longitude) in [(91.0, 0.0), (-91, 0), (0, 181), (0, -181)] {
    let json = "{\"latitude\":\(latitude),\"longitude\":\(longitude)}"
    check((try? JSONDecoder().decode(Coordinate.self, from: Data(json.utf8))) == nil,
          "Out-of-range coordinates are rejected: \(latitude), \(longitude)")
}
check(Coordinate(latitude: 90, longitude: -180).isValid, "The poles and date-line endpoints are valid")
check(!Coordinate(latitude: .nan, longitude: 0).isValid, "NaN coordinates are rejected")
check(!Coordinate(latitude: 0, longitude: .infinity).isValid, "Infinite coordinates are rejected")
check(Trigger.solar(event: .sunrise, offsetMinutes: Int.min).description
      .contains(String(Int.min.magnitude)), "Displaying the minimum integer offset neither overflows nor truncates")
check(Trigger.solar(event: .sunset, offsetMinutes: Int.max).description
      .contains(String(Int.max)), "Displaying the maximum integer offset does not truncate")

do {
    let nullID = Data(#"{"slots":[{"id":null,"trigger":{"type":"clock","hour":9},"wallpaper":{"type":"image","path":"/null.jpg"}}]}"#.utf8)
    try nullID.write(to: Store.fileURL)
    let first = try Store.load()
    let second = try Store.load()
    check(first.slots.first?.id == second.slots.first?.id,
          "Explicit null IDs are saved back and remain stable across repeated loads")
    let saved = try Data(contentsOf: Store.fileURL)
    for invalid in [
        Schedule(slots: first.slots, location: Coordinate(latitude: 91, longitude: 0)),
        Schedule(slots: [morning, morning]),
        Schedule(slots: [Slot(trigger: .clock(hour: 25, minute: 0), wallpaper: .image(path: "/bad"))]),
    ] {
        do {
            try Store.save(invalid)
            check(false, "Invalid configurations cannot overwrite the original file")
        } catch {
            let afterFailure = try Data(contentsOf: Store.fileURL)
            check(afterFailure == saved, "A failed invalid save leaves the original configuration unchanged")
        }
    }
    let damaged = Data("{broken".utf8)
    try damaged.write(to: Store.fileURL)
    check((try? Store.load()) == nil, "Damaged configuration reports an error instead of falling back to a preset")
    let afterLoad = try Data(contentsOf: Store.fileURL)
    check(afterLoad == damaged, "Failed reads preserve the original configuration for repair")
} catch {
    check(false, "Configuration boundary checks complete: \(error)")
}

var newYork = Calendar(identifier: .gregorian)
newYork.timeZone = TimeZone(identifier: "America/New_York")!
let skippedClock = Trigger.clock(hour: 2, minute: 30)
let springDay = localDate("2026-03-08 12:00", calendar: newYork)
check(skippedClock.fireDate(on: springDay, coordinate: nil, calendar: newYork)
      == localDate("2026-03-08 03:00", calendar: newYork),
      "The skipped 02:30 during spring DST fires at 03:00")
let repeatedClock = Trigger.clock(hour: 1, minute: 30)
let autumnDay = localDate("2026-11-01 12:00", calendar: newYork)
check(repeatedClock.fireDate(on: autumnDay, coordinate: nil, calendar: newYork)
      == ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"),
      "The repeated 01:30 during autumn DST uses only the first occurrence")
for slot in [morning, night] {
    let instant = slot.trigger.fireDate(on: noon, coordinate: nil, calendar: calendar)!
    check(clockSchedule.resolve(at: instant, calendar: calendar)?.active.id == slot.id,
          "A new slot becomes active exactly at the boundary")
    check(clockSchedule.resolve(at: instant.addingTimeInterval(-0.001), calendar: calendar)?.active.id != slot.id,
          "One millisecond before the boundary still belongs to the previous slot")
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
    FileHandle.standardError.write(Data("\n\(failures) checks failed\n".utf8))
    exit(1)
}
print("\nAll model checks passed")
