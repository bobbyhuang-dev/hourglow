import Foundation

/// 日出日落计算。
///
/// NOAA 太阳位置算法，含均时差与黄赤交角修正，纯本地计算，不联网。
///
/// 太阳赤纬在一天之内会变化，所以这里不是用当天 0 点的参数一把算完，
/// 而是先估算真太阳时正午，再分别在日出、日落的估计时刻上重新求解，各迭代两轮。
///
/// 实测（`Tests/verify-solar.py`，以 ephem 星历为参考，10 个案例含南北半球、
/// 夏令时切换日、换日线、极昼）：迭代两轮后最大偏差 4 秒；完全不迭代是 21 秒。
/// 两者都够用，迭代只是让它更稳。
enum Solar {

    /// 官方日出日落：太阳几何中心到地平线 −50′（16′ 日面半径 + 34′ 大气折射）。
    static let officialZenith = 90.833
    /// 民用晨昏：太阳中心 −6°。
    static let civilZenith = 96.0
    /// 航海晨昏：太阳中心 −12°。
    static let nauticalZenith = 102.0

    /// 一天里天光分段要用的四个时刻。
    ///
    /// 航海晨光 / 民用黄昏在高纬可能不存在（太阳掉不到那么深），此时为 nil。
    /// 不要在这里回退到日出 / 日落 —— 那会让「晨光到日出」这段长度变成 0，
    /// 天光分段就把一整段壁纸挤进几十秒里放完（`TimeMap` 里有对应的名义时长兜底）。
    struct Events {
        var nauticalDawn: Date?
        var sunrise: Date
        var sunset: Date
        var civilDusk: Date?
    }

    /// 指定日期、指定坐标的日出与日落。极昼或极夜返回 nil。
    static func times(on day: Date,
                      at coord: Coordinate,
                      calendar: Calendar = .current) -> (sunrise: Date, sunset: Date)? {
        guard let events = events(on: day, at: coord, calendar: calendar) else { return nil }
        return (events.sunrise, events.sunset)
    }

    static func events(on day: Date,
                       at coord: Coordinate,
                       calendar: Calendar = .current) -> Events? {

        guard let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: day)
        else { return nil }

        let zoneOffset = Double(calendar.timeZone.secondsFromGMT(for: midnight)) / 60

        /// 用 `instant` 处的均时差反推当天的真太阳时正午。
        func solarNoon(estimatedAt instant: Date) -> Date {
            let minutes = 720 - 4 * coord.longitude
                        - parameters(at: instant).equationOfTime + zoneOffset
            return midnight.addingTimeInterval(minutes * 60)
        }

        /// 日出时角，单位度。太阳达不到该天顶距时（极昼极夜 / 不够深的晨昏）为 nil。
        func hourAngle(estimatedAt instant: Date, zenith: Double) -> Double? {
            let declination = parameters(at: instant).declination
            let phi = coord.latitude * .pi / 180
            let cosH = cos(zenith * .pi / 180) / (cos(phi) * cos(declination))
                     - tan(phi) * tan(declination)
            guard cosH >= -1, cosH <= 1 else { return nil }
            return acos(cosH) * 180 / .pi
        }

        var noon = midnight.addingTimeInterval(12 * 3600)
        for _ in 0..<2 { noon = solarNoon(estimatedAt: noon) }

        /// `direction` 为 -1 求升起、+1 求落下。
        func refine(direction: Double, zenith: Double) -> Date? {
            guard let initialAngle = hourAngle(estimatedAt: noon, zenith: zenith) else { return nil }
            var event = noon.addingTimeInterval(direction * 4 * initialAngle * 60)
            for _ in 0..<2 {
                guard let angle = hourAngle(estimatedAt: event, zenith: zenith) else { return nil }
                event = solarNoon(estimatedAt: event)
                    .addingTimeInterval(direction * 4 * angle * 60)
            }
            return event
        }

        guard let sunrise = refine(direction: -1, zenith: officialZenith),
              let sunset = refine(direction: 1, zenith: officialZenith) else {
            return nil
        }

        return Events(
            nauticalDawn: refine(direction: -1, zenith: nauticalZenith),
            sunrise: sunrise,
            sunset: sunset,
            civilDusk: refine(direction: 1, zenith: civilZenith)
        )
    }

    static func time(of event: SolarEvent,
                     on day: Date,
                     at coord: Coordinate,
                     calendar: Calendar = .current) -> Date? {
        guard let t = times(on: day, at: coord, calendar: calendar) else { return nil }
        return event == .sunrise ? t.sunrise : t.sunset
    }

    // MARK: - 太阳位置

    private struct Parameters {
        /// 赤纬，弧度。
        let declination: Double
        /// 均时差，分钟。
        let equationOfTime: Double
    }

    private static func parameters(at instant: Date) -> Parameters {
        let julianDay = instant.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545.0) / 36_525.0        // 儒略世纪

        let meanLongitude = mod360(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let M = meanAnomaly * .pi / 180
        let center = sin(M) * (1.914602 - t * (0.004817 + 0.000014 * t))
                   + sin(2 * M) * (0.019993 - 0.000101 * t)
                   + sin(3 * M) * 0.000289

        // 视黄经：真黄经扣掉章动与光行差
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = meanLongitude + center
                              - 0.00569 - 0.00478 * sin(omega * .pi / 180)

        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(omega * .pi / 180)

        let declination = asin(sin(obliquity * .pi / 180) * sin(apparentLongitude * .pi / 180))

        let y = pow(tan(obliquity * .pi / 360), 2)
        let L = meanLongitude * .pi / 180
        let equationOfTime = 4 * (180 / Double.pi) * (
              y * sin(2 * L)
            - 2 * eccentricity * sin(M)
            + 4 * eccentricity * y * sin(M) * cos(2 * L)
            - 0.5 * y * y * sin(4 * L)
            - 1.25 * eccentricity * eccentricity * sin(2 * M)
        )

        return Parameters(declination: declination, equationOfTime: equationOfTime)
    }

    private static func mod360(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
