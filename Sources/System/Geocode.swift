import CoreLocation
import Foundation
import MapKit

/// Resolves a user-entered place name to coordinates.
///
/// Tries system MapKit geocoding first (`MKGeocodingRequest`, no API key required), then OpenStreetMap
/// Nominatim if no result is found. Sunrise and sunset remain local calculations; only place selection uses the network.
enum PlaceSearch {

    static func remote(_ query: String) async -> [City] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let apple = await apple(q)
        if !apple.isEmpty { return apple }
        return await nominatim(q)
    }

    static func apple(_ query: String) async -> [City] {
        guard let request = MKGeocodingRequest(addressString: query) else { return [] }
        do {
            return try await request.mapItems.compactMap(city(from:))
        } catch {
            return []
        }
    }

    static func nominatim(_ query: String) async -> [City] {
        guard let request = nominatimRequest(query) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return parseNominatim(data, query: query)
        } catch {
            return []
        }
    }

    /// Stores network results safely: a callback can still write after timeout, racing the caller's read of an unprotected var.
    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var cities: [City] = []

        func put(_ value: [City]) {
            lock.lock(); defer { lock.unlock() }
            cities = value
        }

        func take() -> [City] {
            lock.lock(); defer { lock.unlock() }
            return cities
        }
    }

    /// CLI path that avoids the main thread to prevent mutual waits with the RunLoop.
    static func nominatimBlocking(_ query: String) -> [City] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single-character queries match too many unrelated places to justify a network request.
        guard q.count >= 2, let request = nominatimRequest(q) else { return [] }
        let mailbox = Mailbox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { mailbox.put(parseNominatim(data, query: q)) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 9)
        return mailbox.take()
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

    private static func nominatimRequest(_ query: String) -> URLRequest? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&q=\(encoded)")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // Nominatim requires an identifiable User-Agent; anonymous requests receive 403.
        request.setValue("HourGlow/1.1 (https://github.com/bobbyhuang-dev/hourglow)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private static func parseNominatim(_ data: Data, query: String) -> [City] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var cities: [City] = []
        for row in rows {
            guard let lat = (row["lat"] as? String).flatMap(Double.init),
                  let lon = (row["lon"] as? String).flatMap(Double.init) else { continue }
            let display = row["display_name"] as? String
            let name = (row["name"] as? String)
                ?? display?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
                ?? query
            cities.append(City(
                name: name,
                detail: display ?? "OpenStreetMap",
                coordinate: Coordinate(latitude: lat, longitude: lon, name: name),
                keys: [name, query]
            ))
        }
        return cities
    }
}
