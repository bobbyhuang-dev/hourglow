import Foundation

// 引擎的两处判断逻辑，都不碰系统壁纸，可以离线跑：
//   1. shouldAssert —— 什么时候无条件覆盖，什么时候让位给用户的手动选择
//   2. wakeUpTarget —— 定时器排到哪一刻

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

// MARK: - 覆盖 vs 让位

// 首次运行：还没写过任何东西，谈不上「让位」。
check(scheduler(firedAt: nil, slot: nil)
        .shouldAssert(resolution(slotA, since: nine), reason: .launch),
      "没有写入记录时无条件写入")

// 睡过了 21:00 这个触发点，醒来必须补切 —— 哪怕用户中途换过壁纸，
// 他的手动选择本来就只保到下一次排定的切换为止。
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotB, since: twentyOne), reason: .wake),
      "跨过新的触发时刻后无条件写入")

// 同一个时段内原地重新求值（唤醒、启动、时区变更）：不强制，
// 交给调用方比对当前壁纸是不是我们写的那张。
check(!scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .wake),
      "同一时段内重新求值不强制覆盖")
check(!scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .launch),
      "重启后落回同一时段也不强制覆盖")

// 用户改了时间轴，当前生效的已经换了一段 —— 这本身就是明确意图。
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotB, since: nine), reason: .configChange),
      "当前生效的时段变了就写入")

// 暂停后恢复、手动 apply：明确意图，无视手动改动直接校正。
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .resume),
      "恢复时立即校正")
check(scheduler(firedAt: nine, slot: slotA)
        .shouldAssert(resolution(slotA, since: nine), reason: .manual),
      "手动 apply 无条件写入")

// 时钟被往回拨：since 比记录的还早，不该当成跨过了新边界。
check(!scheduler(firedAt: twentyOne, slot: slotB)
        .shouldAssert(resolution(slotB, since: nine), reason: .clockChange),
      "时钟回拨不会被当成新的触发边界")

// MARK: - 定时器排期

private let engine = scheduler(firedAt: nil, slot: nil)
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let sixHours: TimeInterval = 6 * 3600

private func seconds(_ target: Date) -> TimeInterval { target.timeIntervalSince(now) }

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(1800),
                                  resolved: true)) == 1801,
      "排到下一个触发时刻之后 1 秒（早几毫秒会求值到上一段）")

check(seconds(engine.wakeUpTarget(from: now, next: nil, resolved: true)) == sixHours,
      "没有下一次切换时靠 6 小时安全网兜底")

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(48 * 3600),
                                  resolved: true)) == sixHours,
      "下一次切换太远时也不超过安全网")

check(seconds(engine.wakeUpTarget(from: now, next: nil, resolved: false)) == 15 * 60,
      "求不出值时 15 分钟后重试")

check(seconds(engine.wakeUpTarget(from: now,
                                  next: now.addingTimeInterval(-3600),
                                  resolved: true)) == 1,
      "触发时刻已经过去时至少等 1 秒，不空转")

// MARK: - 配置文件监听

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

    // 模拟 echo > file / 某些编辑器：inode 不变，只截断重写内容。
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("in-place".utf8))
    try handle.close()
    check(waitUntil { changes == 1 }, "配置监听能接住原地重写")

    // Store.save 的 .atomic 会用 rename 替换 inode。
    try Data("atomic".utf8).write(to: file, options: .atomic)
    check(waitUntil { changes == 2 }, "配置监听能接住原子替换")

    // 已排进防抖队列的事件也必须被 stop 取消。
    try Data("after-stop".utf8).write(to: file, options: .atomic)
    watcher.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    check(changes == 2, "配置监听停止后不会补发延迟回调")
} catch {
    check(false, "配置监听集成测试可以完成：\(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项测试失败\n".utf8))
    exit(1)
}
print("\n全部引擎测试通过")
