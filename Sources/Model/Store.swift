import Foundation

/// 配置的持久化。JSON，人类可读、可手改。
enum Store {

    /// 配置目录。`HOURGLOW_HOME` 可以把它整个挪走 —— 验证「首次启动写入预设」这类
    /// 一次性行为只能在一个空目录上做，而 `NSHomeDirectory()` 在 macOS 上取的是
    /// 账户的真实家目录，改 `$HOME` 也没用（非沙盒进程走的是 getpwuid）。
    /// 引擎状态与单实例锁都在这个目录下，所以换目录等于换出一整套干净的运行时环境。
    static var directoryURL: URL {
        // 用 getenv 而不是 ProcessInfo.environment：后者是进程启动时的快照，
        // 靶子里 setenv 之后再问它拿到的还是旧值。
        if let raw = getenv("HOURGLOW_HOME"), let override = String(validatingCString: raw),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/HourGlow")
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("schedule.json")
    }

    /// 读取配置。文件不存在时写入 Tahoe 预设并返回。
    static func load() throws -> Schedule {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let preset = Tahoe.preset
            try save(preset)
            return preset
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try decode(data)
        // 早期配置允许省略 slot.id。若只在内存里补 UUID，每次启动都会得到另一组 ID，
        // 引擎便会把同一个时段误认成“配置换了一段”并覆盖用户的手动壁纸。
        if decoded.needsIDMigration { try save(decoded.schedule) }
        return decoded.schedule
    }

    /// 解码并判断是否需要把自动生成的 slot ID 回写。拆成纯函数便于回归测试。
    static func decode(_ data: Data) throws -> (schedule: Schedule, needsIDMigration: Bool) {
        let schedule = try JSONDecoder().decode(Schedule.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawSlots = object?["slots"] as? [[String: Any]] ?? []
        return (schedule, rawSlots.contains { $0["id"] == nil || $0["id"] is NSNull })
    }

    static func save(_ schedule: Schedule) throws {
        try schedule.validate()
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(schedule).write(to: fileURL, options: .atomic)
    }
}
