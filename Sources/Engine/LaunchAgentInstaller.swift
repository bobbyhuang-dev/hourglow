import Foundation

/// 把 `hourglow-cli run` 注册成 LaunchAgent，让无头引擎在重启后仍然活着。
///
/// M4 起菜单栏 app 有了自己的开机自启（`LaunchAtLogin`，走 `SMAppService`），
/// 这条路仍然留着：不想开 UI、或者要在没登录界面的场合跑引擎时用它。
/// 两条路同时开着不会打架（`EngineLock` 会让后起的那个退成从属），但也没有必要 ——
/// 设置页因此要能看见它、能一键卸载它，`isLoaded` / `uninstall` 就是为此从 CLI 挪过来的。
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
        } catch { throw Failure(message: "写 LaunchAgent 失败: \(error)") }

        _ = launchctl(["bootout", "\(domain)/\(label)"])   // 可能没加载过，失败不算错
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            throw Failure(message: "launchctl bootstrap 失败 (\(result.status)): \(result.output)")
        }
    }

    /// 卸载。返回一句可有可无的说明 —— 本来就没在跑不算失败，那不是错误，是常态。
    @discardableResult
    static func uninstall() -> String? {
        let result = launchctl(["bootout", "\(domain)/\(label)"])
        var note: String?
        if result.status != 0, FileManager.default.fileExists(atPath: plistURL.path) {
            note = "launchctl bootout 返回 \(result.status)（可能本来就没在跑）"
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
