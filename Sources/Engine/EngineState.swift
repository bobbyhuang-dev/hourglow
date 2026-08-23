import Foundation

/// 引擎的运行时状态，与用户配置分开存。
///
/// 存在的唯一理由是回答一个问题：**现在屏幕上这张，是我们写的，还是用户自己换的？**
/// 有了它才能实现「让位给手动选择」（见 `Scheduler` 的注释）。
struct EngineState: Codable, Equatable {
    /// 我们最后一次成功写入系统的那张。
    var lastWritten: Wallpaper?
    /// 它属于哪个时段。时段被删改后用来判断是否需要重新落地。
    var lastSlotID: UUID?
    /// 该时段的**触发时刻**（`Resolution.since`），不是写入时刻。
    /// 判断「是否跨过了新的触发边界」全靠比较它。
    var lastFiredAt: Date?
    /// 实际写入时刻，纯诊断用。
    var lastAppliedAt: Date?

    private enum Key: String, CodingKey { case lastWritten, lastSlotID, lastFiredAt, lastAppliedAt }

    init(lastWritten: Wallpaper? = nil,
         lastSlotID: UUID? = nil,
         lastFiredAt: Date? = nil,
         lastAppliedAt: Date? = nil) {
        self.lastWritten = lastWritten
        self.lastSlotID = lastSlotID
        self.lastFiredAt = lastFiredAt
        self.lastAppliedAt = lastAppliedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        lastWritten = try c.decodeIfPresent(Wallpaper.self, forKey: .lastWritten)
        lastSlotID = try c.decodeIfPresent(UUID.self, forKey: .lastSlotID)
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastAppliedAt = try c.decodeIfPresent(Date.self, forKey: .lastAppliedAt)
    }
}

extension EngineState {

    static var fileURL: URL {
        Store.directoryURL.appendingPathComponent("state.json")
    }

    /// 读不出来就当空状态 —— 状态文件是可再生的缓存，不该让引擎起不来。
    static func load() -> EngineState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(EngineState.self, from: data)
        else { return EngineState() }
        return state
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Store.directoryURL,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: EngineState.fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
