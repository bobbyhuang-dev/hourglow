import Foundation

/// 配置的持久化。JSON，人类可读、可手改。
enum Store {

    static var directoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
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
        return (schedule, rawSlots.contains { $0["id"] == nil })
    }

    static func save(_ schedule: Schedule) throws {
        try FileManager.default.createDirectory(at: directoryURL,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(schedule).write(to: fileURL, options: .atomic)
    }
}
