import Foundation

/// Sunrise and sunset calculations.
///
/// NOAA solar position algorithm with equation-of-time and obliquity corrections, computed entirely offline.
///
/// Solar declination changes throughout the day. Rather than solve once using midnight's parameters,
/// estimate solar noon, then refine sunrise and sunset at their estimated instants with two iterations each.
///
/// Measured by Tests/verify-solar.py against ephem across ten cases covering both hemispheres,
/// DST transitions, the date line, and polar day: maximum error is 4 seconds after two iterations,
/// versus 21 seconds without refinement. Both suffice; iteration improves robustness.
enum Solar {

    /// Official sunrise/sunset: solar center at −50′ (16′ solar radius + 34′ atmospheric refraction).
    static let officialZenith = 90.833
    /// Civil twilight: solar center at −6°.
    static let civilZenith = 96.0
    /// Nautical twilight: solar center at −12°.
    static let nauticalZenith = 102.0

    /// The four daily instants needed for daylight phases.
    ///
    /// Nautical dawn or civil dusk may be absent at high latitudes if the sun never falls that low; then nil.
    /// Do not substitute sunrise/sunset here: a zero-length dawn-to-sunrise span would squeeze a whole
    /// phase's wallpapers into seconds. TimeMap supplies a nominal-duration fallback instead.
    struct Events {
        var nauticalDawn: Date?
        var sunrise: Date
        var sunset: Date
        var civilDusk: Date?
    }

    /// Sunrise and sunset for the given date and coordinates. Returns nil during polar day or night.
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

        /// Derives the day's solar noon using the equation of time at instant.
        func solarNoon(estimatedAt instant: Date) -> Date {
            let minutes = 720 - 4 * coord.longitude
                        - parameters(at: instant).equationOfTime + zoneOffset
            return midnight.addingTimeInterval(minutes * 60)
        }

        /// Sunrise hour angle in degrees; nil if the zenith is unreachable (polar day/night or absent twilight).
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

        /// direction is −1 for rising and +1 for setting.
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

    // MARK: - Solar position

    private struct Parameters {
        /// Declination in radians.
        let declination: Double
        /// Equation of time in minutes.
        let equationOfTime: Double
    }

    private static func parameters(at instant: Date) -> Parameters {
        let julianDay = instant.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545.0) / 36_525.0        // Julian centuries

        let meanLongitude = mod360(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let M = meanAnomaly * .pi / 180
        let center = sin(M) * (1.914602 - t * (0.004817 + 0.000014 * t))
                   + sin(2 * M) * (0.019993 - 0.000101 * t)
                   + sin(3 * M) * 0.000289

        // Apparent longitude: true longitude corrected for nutation and aberration.
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
