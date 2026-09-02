import Foundation

// M2 的常驻入口。M3 起引擎也能跑在菜单栏 app 里（两边抢同一把 `EngineLock`，
// 谁先起谁排程），这个前台守护进程仍然留着：无头调试、以及不想开 UI 的场合。

private let stampFormat: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
}()

private func stamped(_ line: String) {
    FileHandle.standardOutput.write(Data("\(stampFormat.string(from: Date()))  \(line)\n".utf8))
}

// MARK: - run

/// 前台常驻。定时器 + 系统事件驱动，不轮询。Ctrl-C 退出。
func runDaemon() {
    // launchd 把 stdout 重定向到文件时它是全缓冲的，不改成行缓冲的话日志会积着不落盘。
    setvbuf(stdout, nil, _IOLBF, 0)

    // 菜单栏 app 与 CLI 都可能后退出。抢不到锁时进程不能直接失败：LaunchAgent 的
    // KeepAlive 会把失败退出当崩溃反复拉起；原领跑者退出后也需要由从属者接班。
    var lock: EngineLock?
    var scheduler: Scheduler?
    var promotionTimer: Timer?

    @discardableResult
    func becomeLeader() -> Bool {
        guard lock == nil, let acquired = EngineLock.acquire() else { return false }
        let schedule: Schedule
        do {
            schedule = try Store.load()
        } catch {
            acquired.release()
            stamped(L10n.t("cli.run.loadFailed", "\(error)"))
            return false
        }

        lock = acquired
        let engine = Scheduler(schedule: schedule)
        engine.onLog = { stamped($0) }
        scheduler = engine
        promotionTimer?.invalidate()
        promotionTimer = nil
        stamped(L10n.t("cli.run.leader", ProcessInfo.processInfo.processIdentifier))
        engine.start()
        return true
    }

    stamped(L10n.t("cli.run.started", ProcessInfo.processInfo.processIdentifier))
    stamped(labeled("cli.label.config", Store.fileURL.path))

    // 默认的 SIGINT/SIGTERM 处理会直接砍掉进程，DispatchSource 收不到；先忽略再自己接管。
    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            stamped(L10n.t("cli.run.signal"))
            promotionTimer?.invalidate()
            scheduler?.stop()
            lock?.release()
            exit(0)
        }
        source.resume()
        return source
    }

    if !becomeLeader() {
        stamped(L10n.t("cli.run.follower"))
        let timer = Timer(timeInterval: 10, repeats: true) { _ in becomeLeader() }
        RunLoop.main.add(timer, forMode: .common)
        promotionTimer = timer
    }

    // signal source 必须活到 run loop 退出；空的 withExtendedLifetime 会立刻结束，
    // 编译器随后可以释放 sources，导致 Ctrl-C / SIGTERM 不再走清理逻辑。
    withExtendedLifetime(sources) {
        RunLoop.main.run()
    }
}

// MARK: - pause / resume / status

func runPause() {
    do {
        var schedule = try Store.load()
        guard !schedule.paused else { print(L10n.t("cli.pause.already")); return }
        schedule.paused = true
        try Store.save(schedule)
        print(L10n.t("cli.pause.done"))
    } catch { fail("\(error)") }
}

func runResume() {
    do {
        var schedule = try Store.load()
        if schedule.paused {
            schedule.paused = false
            try Store.save(schedule)
        }
        // 恢复是明确的用户意图，无视中途的手动改动直接校正。
        let scheduler = Scheduler(schedule: schedule)
        scheduler.onLog = { print($0) }
        scheduler.evaluate(reason: .resume)
    } catch { fail("\(error)") }
}

/// 引擎视角的状态：上次写了什么、当前壁纸是不是还是那一张。
func runStatus() {
    let state = EngineState.load()
    let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    let schedule = (try? Store.load()) ?? Schedule()
    print(L10n.t("cli.status.schedule",
                 L10n.t(schedule.paused ? "cli.state.paused" : "cli.status.enabled")))
    print(L10n.t("cli.status.engine",
                 L10n.t(EngineLock.isHeldByAnotherProcess ? "cli.status.engine.running"
                                                          : "cli.status.engine.stopped")))
    print(L10n.t("cli.status.agent",
                 L10n.t(LaunchAgentInstaller.isLoaded ? "cli.status.agent.installed"
                                                      : "cli.status.agent.missing")))

    guard let written = state.lastWritten else {
        print(L10n.t("cli.status.neverWrote", EngineState.fileURL.path))
        return
    }
    print(L10n.t("cli.status.lastWrite",
                 Scheduler.describe(written),
                 state.lastFiredAt.map(clock.string(from:)) ?? "—",
                 state.lastAppliedAt.map(clock.string(from:)) ?? "—"))

    if let actual = try? WallpaperWriter.current() {
        let same = WallpaperWriter.normalized(actual) == WallpaperWriter.normalized(written)
        print(L10n.t(same ? "cli.status.stillOurs" : "cli.status.overridden",
                     Scheduler.describe(actual)))
    }
}

// MARK: - agent

// LaunchAgent 的安装本身在 `Engine/LaunchAgentInstaller.swift` —— 菜单栏 app 的设置页
// 也要读它的状态、也要能卸载它，所以它不能只活在 CLI 里。这里只剩下命令行的外壳。
func runAgent(_ subcommand: String?) {
    switch subcommand {
    case "install":
        // 用当前可执行文件的真实路径，这样从 build/ 直接装也能用。
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        do {
            try LaunchAgentInstaller.install(binary: URL(fileURLWithPath: binary.path).standardizedFileURL)
        } catch { fail("\(error.localizedDescription)") }
        print(L10n.t("cli.agent.installed", LaunchAgentInstaller.plistURL.path))
        print(labeled("cli.label.log", LaunchAgentInstaller.logURL.path))
    case "uninstall":
        if let note = LaunchAgentInstaller.uninstall() { print(note) }
        print(L10n.t("cli.agent.uninstalled", LaunchAgentInstaller.label))
    case "status", nil:
        print(LaunchAgentInstaller.isLoaded ? L10n.t("cli.agent.loaded", LaunchAgentInstaller.label)
                                            : L10n.t("cli.agent.notLoaded"))
        print(labeled("cli.label.plist", LaunchAgentInstaller.plistURL.path))
        print(labeled("cli.label.log", LaunchAgentInstaller.logURL.path))
    case let other?:
        fail(L10n.t("cli.unknownSubcommand", other))
    }
}
