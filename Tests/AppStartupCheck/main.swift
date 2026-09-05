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
}
print("All startup recovery tests passed")
