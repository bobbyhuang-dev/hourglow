import Foundation

/// 从系统时区反查一个近似坐标。
///
/// `/usr/share/zoneinfo/zone.tab` 为每个时区标注了代表城市的经纬度。
/// 对日出日落而言这个精度完全够用，且不需要任何定位权限。
/// M4 会加上 CoreLocation 做精确定位，这里是它的回退路径。
enum ApproxLocation {

    static func fromTimeZone(_ tz: TimeZone = .current) -> Coordinate? {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab",
                                      encoding: .utf8) else { return nil }
        for line in table.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] == tz.identifier else { continue }
            return parseISO6709(String(fields[1]))
        }
        return nil
    }

    /// 解析 `+3114+12128`（度分）或 `+513030-0000731`（度分秒）两种写法。
    static func parseISO6709(_ s: String) -> Coordinate? {
        let chars = Array(s)
        guard chars.count > 1 else { return nil }

        var split = -1
        for i in 1..<chars.count where chars[i] == "+" || chars[i] == "-" {
            split = i
            break
        }
        guard split > 0 else { return nil }

        guard let lat = degrees(String(chars[0..<split]), degreeDigits: 2, limit: 90),
              let lon = degrees(String(chars[split...]), degreeDigits: 3, limit: 180) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    private static func degrees(_ field: String, degreeDigits: Int, limit: Int) -> Double? {
        guard field.hasPrefix("+") || field.hasPrefix("-") else { return nil }
        let sign: Double = field.hasPrefix("-") ? -1 : 1
        let body = Array(field.dropFirst())
        // ISO 6709 zone.tab 只使用 DDMM / DDMMSS（经度多一位度数）。
        guard body.count == degreeDigits + 2 || body.count == degreeDigits + 4,
              body.allSatisfy(\.isNumber),
              let d = Int(String(body[0 ..< degreeDigits])),
              let m = Int(String(body[degreeDigits ..< degreeDigits + 2])),
              m < 60
        else { return nil }

        var seconds = 0
        if body.count == degreeDigits + 4 {
            guard let parsed = Int(String(body[degreeDigits + 2 ..< degreeDigits + 4])),
                  parsed < 60 else { return nil }
            seconds = parsed
        }
        guard d < limit || (d == limit && m == 0 && seconds == 0) else { return nil }
        return sign * (Double(d) + Double(m) / 60 + Double(seconds) / 3600)
    }
}
