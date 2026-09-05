import Foundation

// Two engine decisions, neither of which touches the system wallpaper, so they can run offline:
//   1. shouldAssert — when to overwrite unconditionally and when to defer to the user's manual choice
//   2. wakeUpTarget — when to schedule the timer

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

private let slotA = Slot(trigger: .clock(hour: 9, minute: 0), wallpaper: .image(path: "/a"))
private let slotB = Slot(trigger: .clock(hour: 21, minute: 0), wallpaper: .image(path: "/b"))
private let schedule = Schedule(slots: [slotA, slotB])

private let nine = Date(timeIntervalSince1970: 1_700_000_000)
private let twentyOne = nine.addingTimeInterval(12 * 3600)

private func scheduler(firedAt: Date?, slot: Slot?) -> Scheduler {
    Scheduler(schedule: schedule,
              state: EngineState(lastWritten: slot?.wallpaper,
                                 lastSlotID: slot?.id,
                                 lastFiredAt: firedAt))
}

private func resolution(_ slot: Slot, since: Date) -> Resolution {
    Resolution(active: slot, since: since, next: nil)
}

// MARK: - Overwrite vs. defer

// First run: nothing has been written yet, so there is nothing to defer to.
check(scheduler(firedAt: nil, slot: nil)
        .shouldAssert(resolution(slotA, since: nine), reason: .launch),
      "Write unconditionally when there is no write history")

// If the system slept through the 21:00 trigger, waking must catch up — even if the user changed
// the wallpaper in between, since their manual choice only lasts until the next scheduled switch.
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotB, since: twentyOne), reason: .wake),
      "Write unconditionally after crossing a new trigger time")

// Reevaluating within the same slot (wake, launch, time zone change) does not force an overwrite.
// Let the caller compare the current wallpaper with the one we wrote.
check(!scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .wake),
      "Reevaluating within the same slot does not force an overwrite")
check(!scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .launch),
      "Restarting into the same slot does not force an overwrite either")

// The user edited the timeline and a different slot is now active — that itself is explicit intent.
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotB, since: nine), reason: .configChange),
      "Write when the currently active slot changes")

// Resuming after a pause or applying manually expresses explicit intent: correct immediately, ignoring manual changes.
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .resume),
      "Correct immediately on resume")
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .manual),
      "Manual apply writes unconditionally")

// The clock moved backward: since predates the recorded time, so this is not a new boundary crossing.
check(!scheduler(firedAt: twentyOne, slot: slotB)
        .shouldAssert(resolution(slotB, since: nine), reason: .clockChange),
      "Moving the clock backward is not treated as a new trigger boundary")

// MARK: - Timer scheduling

private let engine = scheduler(firedAt: nil, slot: nil)
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let sixHours: TimeInterval = 6 * 3600

private func seconds(_ target: Date) -> TimeInterval { target.timeIntervalSince(now) }

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(1800),
                                  resolved: true)) == 1801,
      "Schedule 1 second after the next trigger (a few milliseconds early would resolve to the previous slot)")

check(seconds(engine.wakeUpTarget(from: now, next: nil, resolved: true)) == sixHours,
      "Fall back to the 6-hour safety net when there is no next switch")

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(48 * 3600),
                                  resolved: true)) == sixHours,
      "Do not exceed the safety-net interval even when the next switch is far away")

check(seconds(engine.wakeUpTarget(from: now, next: nil, resolved: false)) == 15 * 60,
      "Retry after 15 minutes when resolution fails")

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(-3600),
                                  resolved: true)) == 1,
      "Wait at least 1 second when the trigger time has already passed, avoiding a busy loop")

// MARK: - Leader / follower takeover

do {
    let lockDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hourglow-lock-\(UUID().uuidString)")
    let previousHome = getenv("HOURGLOW_HOME").flatMap { String(validatingCString: $0) }
    setenv("HOURGLOW_HOME", lockDirectory.path, 1)
    defer {
        if let previousHome { setenv("HOURGLOW_HOME", previousHome, 1) }
        else { unsetenv("HOURGLOW_HOME") }
        try? FileManager.default.removeItem(at: lockDirectory)
    }

    let leader = EngineLock.acquire()
    check(leader != nil, "The first engine acquires the scheduling lock")
    check(EngineLock.acquire() == nil, "The second engine remains a follower while the leader is alive")
    leader?.release()
    let successor = EngineLock.acquire()
    check(successor != nil, "A follower engine can take over after the leader exits")
    successor?.release()
}

// MARK: - Configuration file monitoring

private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hourglow-watcher-\(UUID().uuidString)")
    let file = directory.appendingPathComponent("schedule.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("initial".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: directory) }

    var changes = 0
    let watcher = ConfigWatcher(fileURL: file) { changes += 1 }
    watcher.start()

    // Simulate echo > file / some editors: keep the inode and only truncate and rewrite the contents.
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("in-place".utf8))
    try handle.close()
    check(waitUntil { changes == 1 }, "Configuration monitoring catches in-place rewrites")

    // Store.save uses .atomic, which replaces the inode via rename.
    try Data("atomic".utf8).write(to: file, options: .atomic)
    check(waitUntil { changes == 2 }, "Configuration monitoring catches atomic replacements")

    // stop must also cancel events already queued for debouncing.
    try Data("after-stop".utf8).write(to: file, options: .atomic)
    watcher.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    check(changes == 2, "Configuration monitoring does not deliver delayed callbacks after stopping")
} catch {
    check(false, "The configuration monitoring integration test can complete: \(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) tests failed\n".utf8))
    exit(1)
}
print("\nAll engine tests passed")
