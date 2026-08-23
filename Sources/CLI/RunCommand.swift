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

    // 单实例锁见 `Engine/EngineLock.swift`：菜单栏 app 也来抢同一把。
    guard let lock = EngineLock.acquire() else {
        fail("已经有一个 HourGlow 引擎在跑了（\(EngineLock.fileURL.path)）")
    }
    // 持有到进程结束；这里只是让编译器别把它当成没用的局部变量。
    defer { lock.release() }

    let schedule: Schedule
    do { schedule = try Store.load() } catch { fail("读取配置失败: \(error)") }

    let scheduler = Scheduler(schedule: schedule)
    scheduler.onLog = { stamped($0) }

    stamped("HourGlow 引擎启动  pid \(ProcessInfo.processInfo.processIdentifier)")
    stamped("配置  \(Store.fileURL.path)")

    // 默认的 SIGINT/SIGTERM 处理会直接砍掉进程，DispatchSource 收不到；先忽略再自己接管。
    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            stamped("收到信号，退出")
            scheduler.stop()
            exit(0)
        }
        source.resume()
        return source
    }
    scheduler.start()
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
        guard !schedule.paused else { print("已经是暂停状态"); return }
        schedule.paused = true
        try Store.save(schedule)
        print("已暂停。壁纸停在当前这张，恢复时会立刻校正。")
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
    print("调度  \(schedule.paused ? "已暂停" : "启用")")
    print("引擎  \(EngineLock.isHeldByAnotherProcess ? "在跑" : "没在跑（hourglow-cli run 或 HourGlow.app）")")
    print("常驻  \(LaunchAgentInstaller.isLoaded ? "已注册 LaunchAgent" : "未注册（hourglow-cli agent install）")")

    guard let written = state.lastWritten else {
        print("引擎还没有写过壁纸（\(EngineState.fileURL.path) 不存在或为空）")
        return
    }
    print("上次写入  \(Scheduler.describe(written))"
          + "   触发于 \(state.lastFiredAt.map(clock.string(from:)) ?? "—")"
          + "   落地于 \(state.lastAppliedAt.map(clock.string(from:)) ?? "—")")

    if let actual = try? WallpaperWriter.current() {
        if WallpaperWriter.normalized(actual) == WallpaperWriter.normalized(written) {
            print("当前壁纸  \(Scheduler.describe(actual))   ✓ 仍是我们写的那张")
        } else {
            print("当前壁纸  \(Scheduler.describe(actual))   ✗ 被手动换过"
                  + " —— 原地重新求值时会让位，下一个触发点才接管")
        }
    }
}

// MARK: - LaunchAgent

/// 把守护进程注册成 LaunchAgent。M4 的 `.app` 会改用 `SMAppService`，
/// 在那之前这是让引擎重启后仍然活着的办法。
enum LaunchAgentInstaller {

    static let label = "app.hourglow.agent"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/HourGlow.log")
    }

    private static var domain: String { "gui/\(getuid())" }

    static var isLoaded: Bool {
        launchctl(["print", "\(domain)/\(label)"]).status == 0
    }

    static func install(binary: URL) {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path, "run"],
            "RunAtLoad": true,
            // 只在异常退出时拉起来。这样 `hourglow-cli agent uninstall` 能真的停掉它。
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch { fail("写 LaunchAgent 失败: \(error)") }

        _ = launchctl(["bootout", "\(domain)/\(label)"])   // 可能没加载过，失败不算错
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            fail("launchctl bootstrap 失败 (\(result.status)): \(result.output)")
        }
        print("已安装  \(plistURL.path)")
        print("日志    \(logURL.path)")
    }

    static func uninstall() {
        let result = launchctl(["bootout", "\(domain)/\(label)"])
        if result.status != 0, FileManager.default.fileExists(atPath: plistURL.path) {
            print("launchctl bootout 返回 \(result.status)（可能本来就没在跑）")
        }
        try? FileManager.default.removeItem(at: plistURL)
        print("已卸载 \(label)")
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func runAgent(_ subcommand: String?) {
    switch subcommand {
    case "install":
        // 用当前可执行文件的真实路径，这样从 build/ 直接装也能用。
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        LaunchAgentInstaller.install(binary: URL(fileURLWithPath: binary.path).standardizedFileURL)
    case "uninstall":
        LaunchAgentInstaller.uninstall()
    case "status", nil:
        print(LaunchAgentInstaller.isLoaded ? "已加载 \(LaunchAgentInstaller.label)" : "未加载")
        print("plist  \(LaunchAgentInstaller.plistURL.path)")
        print("日志   \(LaunchAgentInstaller.logURL.path)")
    case let other?:
        fail("未知子命令 \(other)，可用: install / uninstall / status")
    }
}
