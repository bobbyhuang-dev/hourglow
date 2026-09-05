import Darwin
import Foundation

/// Replace `.app` only after the HourGlow main process exits. This executable is first copied
/// from the bundle into the cache, so moving the old bundle does not remove its own backing files.
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
    // Tests redirect logs to a temporary directory rather than adding entries to the real user's log.
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
                      userInfo: [NSLocalizedDescriptionKey:
                                    L10n.t("updater.open.failed", process.terminationStatus)])
    }
}

// Normal shutdown takes less than a second. Allow 30 seconds for logout or a stuck app,
// then report a definite outcome instead of leaving the helper waiting forever.
private let deadline = Date().addingTimeInterval(30)
while kill(parentPID, 0) == 0, Date() < deadline {
    usleep(100_000)
}
guard kill(parentPID, 0) != 0 else {
    log(L10n.t("updater.wait.timeout"))
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
                      userInfo: [NSLocalizedDescriptionKey: L10n.t("updater.missingPayload")])
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
    log(L10n.t("updater.installed", target.path))
    try? manager.removeItem(at: helper)
    exit(0)
} catch {
    log(L10n.t("updater.failed", error.localizedDescription))
    // If relaunch fails after installing the new version, remove it and restore the old bundle unchanged.
    if newMoved, manager.fileExists(atPath: target.path) { try? manager.removeItem(at: target) }
    if oldMoved, manager.fileExists(atPath: backup.path) {
        try? manager.moveItem(at: backup, to: target)
    }
    if manager.fileExists(atPath: target.path) { try? relaunch(target) }
    try? manager.removeItem(at: helper)
    exit(1)
}
