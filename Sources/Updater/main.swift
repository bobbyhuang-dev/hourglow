import Darwin
import Foundation

/// HourGlow 主进程退出之后再替换 `.app`。这个可执行文件会先从 bundle 复制到缓存目录，
/// 所以挪走旧 bundle 时不会把自己脚下的文件一起抽掉。
private let arguments = CommandLine.arguments
guard arguments.count == 6,
      let parentPID = pid_t(arguments[1]) else {
    exit(2)
}

private let source = URL(fileURLWithPath: arguments[2]).standardizedFileURL
private let target = URL(fileURLWithPath: arguments[3]).standardizedFileURL
private let helper = URL(fileURLWithPath: arguments[4]).standardizedFileURL
private let stageRoot = URL(fileURLWithPath: arguments[5]).standardizedFileURL
private let manager = FileManager.default
private let logURL: URL = {
    // 测试把日志也指进临时目录，别为了验证 helper 往真实用户日志里留一行。
    if let override = ProcessInfo.processInfo.environment["HOURGLOW_UPDATER_LOG"] {
        return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/HourGlow-Updater.log")
}()

private func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let data = Data("[\(stamp)] \(line)\n".utf8)
    if !manager.fileExists(atPath: logURL.path) {
        manager.createFile(atPath: logURL.path, contents: data)
        return
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch { }
}

private func relaunch(_ app: URL) throws {
    guard getenv("HOURGLOW_UPDATER_NO_RELAUNCH") == nil else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [app.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "HourGlowUpdater", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "open 返回 \(process.terminationStatus)"])
    }
}

// 正常退出通常不到一秒；给足 30 秒是为了系统正在注销或应用被卡住时仍能留下明确结果，
// 而不是 helper 永久挂着。
private let deadline = Date().addingTimeInterval(30)
while kill(parentPID, 0) == 0, Date() < deadline {
    usleep(100_000)
}
guard kill(parentPID, 0) != 0 else {
    log("等待 HourGlow 退出超时")
    exit(1)
}

private let backup = target.deletingLastPathComponent()
    .appendingPathComponent(".HourGlow-backup-\(UUID().uuidString).app")
private var oldMoved = false
private var newMoved = false

do {
    guard source.pathExtension == "app", target.pathExtension == "app",
          manager.fileExists(atPath: source.path) else {
        throw NSError(domain: "HourGlowUpdater", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "待安装的 app 不存在"])
    }
    if manager.fileExists(atPath: target.path) {
        try manager.moveItem(at: target, to: backup)
        oldMoved = true
    }
    try manager.moveItem(at: source, to: target)
    newMoved = true
    try relaunch(target)
    if oldMoved { try? manager.removeItem(at: backup) }
    try? manager.removeItem(at: stageRoot)
    log("已安装 \(target.path)")
    try? manager.removeItem(at: helper)
    exit(0)
} catch {
    log("安装失败：\(error.localizedDescription)")
    // 新版本挪到位之后如果重启失败，先把它撤掉，再把旧 bundle 原样放回。
    if newMoved, manager.fileExists(atPath: target.path) { try? manager.removeItem(at: target) }
    if oldMoved, manager.fileExists(atPath: backup.path) {
        try? manager.moveItem(at: backup, to: target)
    }
    if manager.fileExists(atPath: target.path) { try? relaunch(target) }
    try? manager.removeItem(at: helper)
    exit(1)
}
