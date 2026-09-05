import Foundation

/// Daily refresh policy shared by the app and offline checks. No continuous tracking.
enum LocationRefresh {
    static let retryInterval: TimeInterval = 60 * 60
    static let movementThreshold: Double = 5_000

    static func isDue(_ schedule: Schedule, now: Date, lastAttempt: Date?,
                      calendar: Calendar = .current) -> Bool {
        guard schedule.automaticLocation else { return false }
        if let lastAttempt, now >= lastAttempt,
           now.timeIntervalSince(lastAttempt) < retryInterval { return false }
        guard let checked = schedule.locationCheckedAt else { return true }
        return checked > now || !calendar.isDate(checked, inSameDayAs: now)
            || schedule.locationCheckedTimeZone != calendar.timeZone.identifier
    }

    static func shouldReplace(_ old: Coordinate?, with new: Coordinate) -> Bool {
        guard let old else { return true }
        let radians = Double.pi / 180
        let lat = (new.latitude - old.latitude) * radians
        let lon = (new.longitude - old.longitude) * radians
        let a = pow(sin(lat / 2), 2) + cos(old.latitude * radians)
            * cos(new.latitude * radians) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a)))) >= movementThreshold
    }

    /// Reject cached or imprecise fixes instead of marking an old city as freshly checked.
    static func isUsable(_ coordinate: Coordinate, accuracy: Double,
                         timestamp: Date, now: Date) -> Bool {
        coordinate.isValid && accuracy.isFinite && accuracy >= 0 && accuracy <= movementThreshold
            && now.timeIntervalSince(timestamp) >= -60 && now.timeIntervalSince(timestamp) <= 300
    }
}
