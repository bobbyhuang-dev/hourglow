import CoreLocation
import Foundation
import MapKit

/// 把用户打的地名变成坐标。
///
/// 先走系统 MapKit 地理编码（`MKGeocodingRequest`，不用自己申请 key），
/// 没结果再问 OpenStreetMap Nominatim。日出日落仍然本地算，网络只在选地点时用一次。
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

    /// CLI 用：不经过主线程，避免和 RunLoop 互相等。
    static func nominatimBlocking(_ query: String) -> [City] {
        guard let request = nominatimRequest(query) else { return [] }
        let lock = DispatchSemaphore(value: 0)
        var cities: [City] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { cities = parseNominatim(data, query: query) }
            lock.signal()
        }.resume()
        _ = lock.wait(timeout: .now() + 9)
        return cities
    }

    static func reverse(_ location: CLLocation) async -> City {
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first,
           let city = city(from: item) {
            return city
        }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let name = String(format: "%.3f, %.3f", lat, lon)
        return City(name: name,
                    detail: "当前位置",
                    coordinate: Coordinate(latitude: lat, longitude: lon, name: "当前位置"),
                    keys: [name])
    }

    static func city(from item: MKMapItem) -> City? {
        let loc = item.location
        let name = item.name
            ?? item.address?.shortAddress
        guard let name, !name.isEmpty else { return nil }
        let detail = item.address?.fullAddress ?? "搜索结果"
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
        // Nominatim 要求可识别的 UA，匿名会 403。
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
