import Foundation

// 编入真实 AppModel，验证启动与恢复链路；恢复的配置保持暂停，绝不写系统壁纸。
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
                 "损坏配置启动不能回退 Tahoe 或取得排程锁")
    precondition(!model.setManualLocation(Coordinate(latitude: 22.543, longitude: 114.058)),
                 "修复前设置动作不能覆盖原文件")
    precondition((try? Data(contentsOf: Store.fileURL)) == damaged,
                 "损坏原文件必须保留")
    model.start()
    precondition(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("state.json").path),
                 "启动失败不能写入引擎状态")
    print("✓ 损坏配置启动不使用预设、不排程、不允许设置动作覆盖原文件")

    let repaired = Schedule(slots: [Slot(trigger: .clock(hour: 9, minute: 0),
                                       wallpaper: .image(path: "/fixture"))], paused: true)
    try! Store.save(repaired)
    let deadline = Date().addingTimeInterval(35)
    while model.isFollower && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    precondition(!model.isFollower && model.schedule.paused
                 && model.schedule.slots == repaired.slots,
                 "修复配置后自动接管最新的暂停时间轴")
    precondition(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("state.json").path),
                 "暂停配置恢复不能写壁纸")
    print("✓ 修复后监听并自动接管最新配置，保留暂停状态")

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
print("全部启动恢复测试通过")
