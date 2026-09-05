import Foundation

/// Registers hourglow-cli run as a LaunchAgent so the headless engine survives restarts.
///
/// Since M4 the menu-bar app has its own login item (LaunchAtLogin via SMAppService).
/// This path remains for running the engine without the UI. Enabling both is safe but unnecessary:
/// EngineLock makes the second process a follower. Settings therefore exposes status and one-click
/// removal; isLoaded and uninstall moved here from the CLI to support that.
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

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func install(binary: URL) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path, "run"],
            "RunAtLoad": true,
            // Restart only after abnormal exits so hourglow-cli agent uninstall can actually stop it.
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
        } catch { throw Failure(message: L10n.t("agent.error.write", "\(error)")) }

        _ = launchctl(["bootout", "\(domain)/\(label)"])   // May not be loaded; failure is harmless.
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            throw Failure(message: L10n.t("agent.error.bootstrap", result.status, result.output))
        }
    }

    /// Uninstalls, returning an optional explanation. Already stopped is normal, not a failure.
    @discardableResult
    static func uninstall() -> String? {
        let result = launchctl(["bootout", "\(domain)/\(label)"])
        var note: String?
        if result.status != 0, FileManager.default.fileExists(atPath: plistURL.path) {
            note = L10n.t("agent.bootout.note", result.status)
        }
        try? FileManager.default.removeItem(at: plistURL)
        return note
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
