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

    /// 收网络结果的信箱。超时返回后回调还可能再写一次，裸 `var` 会和调用方的读并发。
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

    /// CLI 用：不经过主线程，避免和 RunLoop 互相等。
    static func nominatimBlocking(_ query: String) -> [City] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 一个字的查询在任何地名库里都能命中一堆不相干的东西，不值得为它跑一趟网络。
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

    /// 反查只用来给坐标起个名字。查不到就返回 nil —— 调用方该留住手里那个精确坐标，
    /// 而不是拿一个编出来的地名把它换掉。
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
