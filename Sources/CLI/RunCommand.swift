import Foundation

// M2's resident entry point. Since M3, the menu bar app can also host the engine; both compete
// for `EngineLock`, and the first to start schedules. Keep this foreground daemon for headless debugging and use without a UI.

private let stampFormat: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
}()

private func stamped(_ line: String) {
    FileHandle.standardOutput.write(Data("\(stampFormat.string(from: Date()))  \(line)\n".utf8))
}

// MARK: - run

/// Run in the foreground, driven by timers and system events rather than polling. Ctrl-C exits.
func runDaemon() {
    // launchd redirects stdout to a fully buffered file; use line buffering so logs do not remain unwritten.
    setvbuf(stdout, nil, _IOLBF, 0)

    // Either the app or CLI may outlive the other. Failure to acquire the lock must not exit:
    // LaunchAgent KeepAlive would repeatedly restart it as a crash, and followers must take over when the leader exits.
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

    // Default SIGINT/SIGTERM handling terminates before DispatchSource receives them; ignore it and handle signals ourselves.
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

    // Signal sources must survive until the run loop exits. An empty withExtendedLifetime ends
    // immediately, allowing the compiler to release sources and bypass cleanup on Ctrl-C / SIGTERM.
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
        // Resume expresses explicit user intent: correct immediately, ignoring intervening manual changes.
        let scheduler = Scheduler(schedule: schedule)
        scheduler.onLog = { print($0) }
        scheduler.evaluate(reason: .resume)
    } catch { fail("\(error)") }
}

/// State from the engine's perspective: what it last wrote and whether that wallpaper is still current.
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

// LaunchAgent installation lives in `Engine/LaunchAgentInstaller.swift`: app settings also need
// status and uninstall support, so it cannot live only in the CLI. This is just the command-line wrapper.
func runAgent(_ subcommand: String?) {
    switch subcommand {
    case "install":
        // Use the executable's resolved path so installation directly from build/ also works.
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
