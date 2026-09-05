import Foundation

/// Configuration persistence in human-readable, hand-editable JSON.
enum Store {

    /// Configuration directory. `HOURGLOW_HOME` relocates it entirely: one-time behavior such as
    /// writing the preset on first launch requires an empty directory. On macOS, `NSHomeDirectory()`
    /// returns the account's actual home even if `$HOME` changes (non-sandboxed processes use getpwuid).
    /// Engine state and the single-instance lock also live here, so relocation gives a clean runtime.
    static var directoryURL: URL {
        // Use getenv, not ProcessInfo.environment, which snapshots the environment at process launch
        // and still returns old values after a check target calls setenv.
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

    /// Loads the configuration, writing and returning the Tahoe preset if the file does not exist.
    static func load() throws -> Schedule {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let preset = Tahoe.preset
            try save(preset)
            return preset
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try decode(data)
        // Early configurations allowed missing slot.id values. Generating UUIDs only in memory
        // changes IDs on every launch, making the engine overwrite manual wallpaper as if the slot changed.
        if decoded.needsIDMigration { try save(decoded.schedule) }
        return decoded.schedule
    }

    /// Decodes and checks whether generated slot IDs need persisting. A pure function for regression checks.
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
