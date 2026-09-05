import Foundation

// Compile in the real AppModel to verify startup and recovery; the recovered configuration stays paused and never writes system wallpaper.
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hourglow-startupcheck-\(UUID().uuidString)")
setenv("HOURGLOW_HOME", sandbox.path, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }
try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
let damaged = Data("{broken".utf8)
try damaged.write(to: Store.fileURL)

MainActor.assumeIsolated {
    let model = AppModel.shared
    precondition(model.schedule.slots.isEmpty && model.resolution == nil && model.isFollower,
                 "Starting with damaged configuration must not fall back to Tahoe or acquire the scheduling lock")
    precondition(!model.setManualLocation(Coordinate(latitude: 22.543, longitude: 114.058)),
                 "Settings actions must not overwrite the original file before repair")
    precondition((try? Data(contentsOf: Store.fileURL)) == damaged,
                 "The damaged original file must be preserved")
    model.start()
    precondition(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("state.json").path),
                 "Failed startup must not write engine state")
    print("✓ Startup with damaged configuration uses no preset, does not schedule, and prevents settings actions from overwriting the original file")

    let repaired = Schedule(slots: [Slot(trigger: .clock(hour: 9, minute: 0),
                                       wallpaper: .image(path: "/fixture"))], paused: true)
    try! Store.save(repaired)
    let deadline = Date().addingTimeInterval(35)
    while model.isFollower && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    precondition(!model.isFollower && model.schedule.paused
                 && model.schedule.slots == repaired.slots,
                 "Automatically take over the latest paused timeline after configuration repair")
    precondition(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("state.json").path),
                 "Recovering paused configuration must not write wallpaper")
    print("✓ Monitor and automatically take over the latest configuration after repair, preserving the paused state")

    // The test keeps the schedule paused and observes display-clock reads, so no
    // wallpaper writes or changes to the user's defaults are needed.
    var clockReads = 0
    var displayNow = Date()
    AppModel.now = { clockReads += 1; return displayNow }
    defer { AppModel.now = { Date() } }
    model.start() // Starting twice must not install duplicate timers or observers.
    RunLoop.main.run(until: Date().addingTimeInterval(31))
    precondition(clockReads == 0, "A hidden leader must stop periodic display refresh after promotion")
    print("✓ Hidden leader performs no periodic display-clock reads over 31 seconds")

    model.setPanelVisible(true)
    precondition(clockReads > 0, "Opening the panel refreshes immediately")
    precondition(model.resolution?.since == repaired.resolve(at: displayNow)?.since,
                 "Opening the panel shows the current resolution")
    let openingReads = clockReads
    model.setPanelVisible(true)
    precondition(clockReads == openingReads, "Repeated appearance does not duplicate refresh work")
    displayNow = displayNow.addingTimeInterval(24 * 3600)
    RunLoop.main.run(until: Date().addingTimeInterval(31))
    precondition(clockReads > openingReads && model.resolution?.since == repaired.resolve(at: displayNow)?.since,
                 "A visible panel continues refreshing as time advances")
    print("✓ Panel opens with fresh state and keeps its 30-second refresh")

    model.setPanelVisible(false)
    clockReads = 0
    RunLoop.main.run(until: Date().addingTimeInterval(31))
    precondition(clockReads == 0, "Closing the panel cancels periodic refresh")
    displayNow = displayNow.addingTimeInterval(24 * 3600)
    model.setPanelVisible(true)
    precondition(model.resolution?.since == repaired.resolve(at: displayNow)?.since,
                 "Reopening catches up immediately after hidden time")
    model.setPanelVisible(false)
    precondition(!FileManager.default.fileExists(atPath: EngineState.fileURL.path),
                 "Display refresh never applies wallpaper while paused")
    print("✓ Closing stops refresh; reopening catches up without changing wallpaper")

    // Use the real app persistence path with injected system boundaries: no permission prompts or network.
    model.canRefreshLocation = { true }
    model.reverseLocationName = { _ in nil }
    var pendingFixes: [(PreciseLocation.Outcome) -> Void] = []
    model.requestLocationFix = { pendingFixes.append($0) }
    var locationNow = Date()
    AppModel.now = { locationNow }
    model.setAutomaticLocation(true)
    precondition(model.schedule.automaticLocation && pendingFixes.count == 1,
                 "Enabling automatic location immediately requests a fix")
    let shenzhen = Coordinate(latitude: 22.543, longitude: 114.058, name: "Shenzhen")
    pendingFixes.removeFirst()(.coordinate(shenzhen))
    precondition(model.schedule.location == shenzhen && model.schedule.locationCheckedAt == locationNow,
                 "A successful fix records coordinates and the successful check time")
    model.refreshAutomaticLocation()
    precondition(pendingFixes.isEmpty, "The same day does not request another fix")
    locationNow = locationNow.addingTimeInterval(86400)
    model.refreshAutomaticLocation()
    pendingFixes.removeFirst()(.coordinate(Coordinate(latitude: 22.544, longitude: 114.058)))
    precondition(model.schedule.location == shenzhen && model.schedule.locationCheckedAt == locationNow,
                 "Daily checks preserve names and coordinates for small drift")
    locationNow = locationNow.addingTimeInterval(86400)
    model.refreshAutomaticLocation()
    pendingFixes.removeFirst()(.failed("offline fixture"))
    let lastSuccess = model.schedule.locationCheckedAt
    precondition(model.locating == .idle && model.schedule.location == shenzhen
                 && lastSuccess != locationNow, "Background failure preserves the last successful fix silently")
    model.refreshAutomaticLocation()
    precondition(pendingFixes.isEmpty, "Failed requests do not retry immediately")
    locationNow = locationNow.addingTimeInterval(3601)
    model.refreshAutomaticLocation()
    precondition(pendingFixes.count == 1, "An expired retry interval permits another attempt")
    let beijing = Coordinate(latitude: 39.904, longitude: 116.407, name: "Beijing")
    var external = try! Store.load()
    external.slots.append(Slot(trigger: .clock(hour: 13, minute: 0), wallpaper: .image(path: "/external")))
    try! Store.save(external)
    pendingFixes.removeFirst()(.coordinate(beijing))
    precondition(model.schedule.location == beijing && model.schedule.slots == external.slots,
                 "Travel refresh preserves concurrent timeline edits from disk")
    locationNow = locationNow.addingTimeInterval(86400)
    model.refreshAutomaticLocation()
    precondition(model.setManualLocation(shenzhen), "Selecting a fixed city succeeds")
    pendingFixes.removeFirst()(.coordinate(beijing))
    precondition(!model.schedule.automaticLocation && model.schedule.location == shenzhen,
                 "A late fix cannot replace a manually selected city")
    model.setAutomaticLocation(true)
    external = try! Store.load()
    external.automaticLocation = false
    external.location = beijing
    try! Store.save(external)
    pendingFixes.removeFirst()(.coordinate(shenzhen))
    precondition((try! Store.load()).location == beijing,
                 "A late fix cannot overwrite CLI location changes before the watcher fires")
    model.setAutomaticLocation(true)
    model.setAutomaticLocation(false)
    pendingFixes.removeFirst()(.coordinate(shenzhen))
    precondition(!model.schedule.automaticLocation && model.schedule.location == beijing,
                 "Turning automatic location off invalidates an in-flight request")
    // A reverse lookup may finish after the user has already selected the same coordinates manually.
    var finishName: CheckedContinuation<String?, Never>?
    model.reverseLocationName = { _ in
        await withCheckedContinuation { finishName = $0 }
    }
    model.setAutomaticLocation(true)
    pendingFixes.removeFirst()(.coordinate(shenzhen))
    let nameDeadline = Date().addingTimeInterval(2)
    while finishName == nil && Date() < nameDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(finishName != nil, "A successful new fix starts the readable-name lookup")
    let fixedName = Coordinate(latitude: shenzhen.latitude, longitude: shenzhen.longitude, name: "My fixed place")
    precondition(model.setManualLocation(fixedName), "Selecting a named fixed coordinate succeeds")
    finishName?.resume(returning: "Late geocoder name")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.schedule.location == fixedName && !model.schedule.automaticLocation,
                 "A late reverse lookup never renames a newly selected fixed location")
    external = try! Store.load()
    external.automaticLocation = true
    try! Store.save(external)
    model.canRefreshLocation = { false }
    model.refreshAutomaticLocation()
    precondition(pendingFixes.isEmpty, "Background refresh never requests missing system permission")
    precondition(!FileManager.default.fileExists(atPath: EngineState.fileURL.path),
                 "Location changes preserve pause and never write real wallpaper in these checks")
    print("✓ Automatic location refresh, retry, travel, concurrent edits, and fixed-location protection")

}
print("All startup recovery tests passed")
