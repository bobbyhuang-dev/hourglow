import CoreLocation
import Foundation
import MapKit

/// Resolves a user-entered place name to coordinates.
///
/// Uses Apple's MapKit for searches missing from the offline city list and for reverse lookups.
/// Public Nominatim does not permit client-side autocomplete, so it is not used by the app or CLI.
enum PlaceSearch {
    static func needsRemoteSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= 2 && Cities.search(q).isEmpty
    }

    static func remote(_ query: String) async -> [City] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !Task.isCancelled,
              let request = MKGeocodingRequest(addressString: q) else { return [] }
        do {
            return try await request.mapItems.compactMap(city(from:))
        } catch {
            return []
        }
    }

    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var cities: [City]?

        func put(_ value: [City]) {
            lock.lock(); defer { lock.unlock() }
            cities = value
        }

        func take() -> [City]? {
            lock.lock(); defer { lock.unlock() }
            return cities
        }
    }

    /// The synchronous CLI must keep servicing the main run loop for MapKit callbacks.
    /// A timeout cancels the task; its mailbox remains alive for a late system callback.
    static func remoteBlocking(_ query: String, timeout: TimeInterval = 9,
                               lookup: @escaping @Sendable (String) async -> [City] = { await remote($0) }) -> [City] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let mailbox = Mailbox()
        let task = Task.detached { mailbox.put(await lookup(query)) }
        defer { task.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let cities = mailbox.take() { return cities }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return []
    }

    /// Reverse lookup only names coordinates. Returns nil on failure so the caller preserves
    /// the precise coordinates rather than replacing them with a fabricated place.
    static func reverse(_ location: CLLocation) async -> City? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return city(from: item)
    }

    static func city(from item: MKMapItem) -> City? {
        let loc = item.location
        let name = item.name
            ?? item.address?.shortAddress
        guard let name, !name.isEmpty else { return nil }
        let detail = item.address?.fullAddress ?? L10n.t("geocode.result")
        return City(
            name: name,
            detail: detail,
            coordinate: Coordinate(latitude: loc.coordinate.latitude,
                                   longitude: loc.coordinate.longitude,
                                   name: name),
            keys: [name]
        )
    }

}
