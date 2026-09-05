import Foundation

/// Engine runtime state, persisted separately from user configuration.
///
/// Exists to answer one question: **did we write the current wallpaper, or did the user change it?**
/// This enables deferring to manual choices (see Scheduler's documentation).
struct EngineState: Codable, Equatable {
    /// The wallpaper we last successfully wrote to the system.
    var lastWritten: Wallpaper?
    /// Its slot, used to decide whether to reapply after slots are edited or deleted.
    var lastSlotID: UUID?
    /// The slot's **trigger time** (Resolution.since), not the write time.
    /// Comparing this determines whether a new trigger boundary has been crossed.
    var lastFiredAt: Date?
    /// Actual write time, for diagnostics only.
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

    /// Unreadable state becomes empty: this regenerable cache must not prevent engine startup.
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
