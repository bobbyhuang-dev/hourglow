import Foundation

// MARK: - Coordinate

struct Coordinate: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double
    /// City name recorded when choosing a location. Older configurations decode this as nil.
    var name: String? = nil

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private enum Key: String, CodingKey { case latitude, longitude, name }

    init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        guard isValid else { throw ScheduleError.invalidCoordinate }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

// MARK: - Trigger

enum SolarEvent: String, Codable {
    case sunrise, sunset
}

/// Four daylight phases. Imported wallpapers are grouped by filename, then evenly spaced by count.
enum DayPhase: String, Codable, CaseIterable {
    case sunrise, day, sunset, night

    var name: String { L10n.t("phase.\(rawValue)") }
}

/// The condition that activates a slot.
enum Trigger: Equatable {
    /// A fixed time in the local time zone.
    case clock(hour: Int, minute: Int)
    /// Relative to sunrise or sunset; negative `offsetMinutes` means earlier.
    case solar(event: SolarEvent, offsetMinutes: Int)
    /// Divides the day's solar window into `count` equal parts and selects image `index` (zero-based).
    /// Stores an image index and count, not a fixed clock time, so image counts and seasons stay aligned.
    case solarPhase(phase: DayPhase, index: Int, count: Int)

    /// Whether evaluating this trigger requires coordinates.
    var dependsOnSun: Bool {
        switch self {
        case .clock: return false
        case .solar, .solarPhase: return true
        }
    }
}

extension Trigger: Codable {
    private enum Key: String, CodingKey { case type, hour, minute, event, offsetMinutes, phase, index, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "clock":
            let hour = try c.decode(Int.self, forKey: .hour)
            let minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
            guard (0..<24).contains(hour), (0..<60).contains(minute) else {
                throw ScheduleError.invalidClock
            }
            self = .clock(hour: hour, minute: minute)
        case "solar":
            self = .solar(event: try c.decode(SolarEvent.self, forKey: .event),
                          offsetMinutes: try c.decodeIfPresent(Int.self, forKey: .offsetMinutes) ?? 0)
        case "solarPhase":
            let count = try c.decode(Int.self, forKey: .count)
            let index = try c.decode(Int.self, forKey: .index)
            if count <= 0 || index < 0 || index >= count {
                throw DecodingError.dataCorruptedError(
                    forKey: .index, in: c,
                    debugDescription: "Invalid solarPhase index/count: \(index)/\(count)")
            }
            self = .solarPhase(phase: try c.decode(DayPhase.self, forKey: .phase),
                               index: index,
                               count: count)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown trigger type: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .clock(let h, let m):
            try c.encode("clock", forKey: .type)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        case .solar(let e, let off):
            try c.encode("solar", forKey: .type)
            try c.encode(e, forKey: .event)
            try c.encode(off, forKey: .offsetMinutes)
        case .solarPhase(let phase, let index, let count):
            try c.encode("solarPhase", forKey: .type)
            try c.encode(phase, forKey: .phase)
            try c.encode(index, forKey: .index)
            try c.encode(count, forKey: .count)
        }
    }
}

extension Trigger: CustomStringConvertible {
    var description: String {
        switch self {
        case .clock(let h, let m):
            return String(format: "%02d:%02d", h, m)
        case .solar(let e, let off):
            let name = L10n.t("sun.\(e.rawValue)")
            if off == 0 { return name }
            // Int.min cannot be negated; decimal strings also avoid %d truncating 64-bit offsets to 32 bits.
            return off > 0 ? L10n.t("trigger.solar.after", name, String(off.magnitude))
                           : L10n.t("trigger.solar.before", name, String(off.magnitude))
        case .solarPhase(let phase, let index, let count):
            return L10n.t("trigger.phase", phase.name, index + 1, count)
        }
    }
}

// MARK: - Wallpaper

enum Wallpaper: Equatable {
    case aerial(assetID: String)
    case image(path: String)
}

extension Wallpaper: Codable {
    private enum Key: String, CodingKey { case type, assetID, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "aerial": self = .aerial(assetID: try c.decode(String.self, forKey: .assetID))
        case "image":  self = .image(path: try c.decode(String.self, forKey: .path))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown wallpaper type: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .aerial(let id):
            try c.encode("aerial", forKey: .type)
            try c.encode(id, forKey: .assetID)
        case .image(let path):
            try c.encode("image", forKey: .type)
            try c.encode(path, forKey: .path)
        }
    }
}

// MARK: - Slot & Schedule

struct Slot: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: Trigger
    var wallpaper: Wallpaper
    var enabled: Bool = true

    private enum Key: String, CodingKey { case id, trigger, wallpaper, enabled }

    init(id: UUID = UUID(), trigger: Trigger, wallpaper: Wallpaper, enabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.wallpaper = wallpaper
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        wallpaper = try c.decode(Wallpaper.self, forKey: .wallpaper)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct Schedule: Codable {
    var slots: [Slot] = []
    var paused: Bool = false
    /// Manually supplied coordinates. Falls back to time-zone inference when absent (see `ApproxLocation`).
    var location: Coordinate? = nil

    private enum Key: String, CodingKey { case slots, paused, location }

    init(slots: [Slot] = [], paused: Bool = false, location: Coordinate? = nil) {
        self.slots = slots
        self.paused = paused
        self.location = location
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        slots = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        location = try c.decodeIfPresent(Coordinate.self, forKey: .location)
        try validate()
    }

    /// Shared boundary for hand-edited JSON and UI/CLI saves, rejecting invalid values before evaluation silently skips them.
    func validate() throws {
        if let location, !location.isValid { throw ScheduleError.invalidCoordinate }
        guard Set(slots.map(\.id)).count == slots.count else { throw ScheduleError.duplicateID }
        for slot in slots {
            switch slot.trigger {
            case .clock(let hour, let minute):
                guard (0..<24).contains(hour), (0..<60).contains(minute) else {
                    throw ScheduleError.invalidClock
                }
            case .solar: break
            case .solarPhase(_, let index, let count):
                guard count > 0, index >= 0, index < count else {
                    throw ScheduleError.invalidPhase
                }
            }
        }
    }

    /// Coordinates used for calculations: explicit coordinates first, otherwise inferred from the system time zone.
    var effectiveCoordinate: Coordinate? {
        location ?? ApproxLocation.fromTimeZone()
    }
}

enum ScheduleError: LocalizedError {
    case invalidCoordinate, invalidClock, invalidPhase, duplicateID

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return L10n.t("config.error.coordinate")
        case .invalidClock: return L10n.t("config.error.clock")
        case .invalidPhase: return L10n.t("config.error.phase")
        case .duplicateID: return L10n.t("config.error.duplicateID")
        }
    }
}

// MARK: - Tahoe preset

enum Tahoe {
    static let morning = "B2FC91ED-6891-4DEB-85A1-268B2B4160B6"
    static let day     = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    static let evening = "52ACB9B8-75FC-4516-BC60-4550CFF3B661"
    static let night   = "CF6347E2-4F81-4410-8892-4830991B6C5A"

    static var preset: Schedule {
        Schedule(slots: [
            Slot(trigger: .solar(event: .sunrise, offsetMinutes: 0),   wallpaper: .aerial(assetID: morning)),
            Slot(trigger: .clock(hour: 9, minute: 0),                  wallpaper: .aerial(assetID: day)),
            Slot(trigger: .solar(event: .sunset, offsetMinutes: -30),  wallpaper: .aerial(assetID: evening)),
            Slot(trigger: .solar(event: .sunset, offsetMinutes: 60),   wallpaper: .aerial(assetID: night)),
        ])
    }
}
