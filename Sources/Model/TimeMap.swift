import Foundation

/// Evenly distributes wallpapers across the day's four daylight phases.
///
/// Uses the ProTime windows from 24 Hour Wallpaper / Sunshift, not exact sunrise-to-sunset bounds:
/// sunrise runs from nautical dawn until one-third of that dawn span past sunrise; sunset begins
/// one-third of the dusk span early and ends at civil dusk, keeping golden-hour images from bunching at sunrise.
///
/// Each phase is subdivided by its image count: three or five sunrise images share the same window.
/// Windows are recalculated daily from the local solar position, following the seasons rather than fixed times.
enum TimeMap {

    /// At high latitudes in summer the sun may never reach −12°/−6°, so nautical dawn or civil dusk is absent.
    /// Use a nominal duration only then: zero would cycle several sunrise images within seconds
    /// and run killall on WallpaperAgent three times in succession. Do not replace real twilight
    /// with this fallback; equatorial civil dusk can legitimately last only about twenty minutes.
    static let nominalTwilight: TimeInterval = 45 * 60

    struct Window {
        var start: Date
        var end: Date
    }

    struct DayWindows {
        var sunrise: Window
        var day: Window
        var sunset: Window
        var night: Window

        func window(for phase: DayPhase) -> Window {
            switch phase {
            case .sunrise: return sunrise
            case .day:     return day
            case .sunset:  return sunset
            case .night:   return night
            }
        }

        func fireDate(phase: DayPhase, index: Int, count: Int) -> Date? {
            guard count > 0, index >= 0, index < count else { return nil }
            let window = window(for: phase)
            guard window.end > window.start else { return nil }
            let step = window.end.timeIntervalSince(window.start) / Double(count)
            return window.start.addingTimeInterval(step * Double(index))
        }
    }

    static func windows(on day: Date,
                        coordinate: Coordinate,
                        calendar: Calendar = .current) -> DayWindows? {
        guard let today = Solar.events(on: day, at: coordinate, calendar: calendar),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
              let next = Solar.events(on: tomorrow, at: coordinate, calendar: calendar)
        else { return nil }

        let sunrise = today.sunrise
        let sunset = today.sunset
        let dawn = today.nauticalDawn ?? sunrise.addingTimeInterval(-nominalTwilight)
        let dusk = today.civilDusk ?? sunset.addingTimeInterval(nominalTwilight)
        let nextDawn = next.nauticalDawn
            ?? next.sunrise.addingTimeInterval(-nominalTwilight)

        // Keep a lower bound even for real twilight that nearly coincides with sunrise, avoiding division by zero.
        let sunriseSpan = max(sunrise.timeIntervalSince(dawn), 60)
        let sunriseEnd = sunrise.addingTimeInterval(sunriseSpan / 3)
        let sunsetSpan = max(dusk.timeIntervalSince(sunset), 60)
        let sunsetStart = sunset.addingTimeInterval(-sunsetSpan / 3)

        return DayWindows(
            sunrise: Window(start: dawn, end: sunriseEnd),
            day:     Window(start: sunriseEnd, end: sunsetStart),
            sunset:  Window(start: sunsetStart, end: dusk),
            night:   Window(start: dusk, end: nextDawn)
        )
    }

    /// Trigger time for image `index` (zero-based) in this phase on `day`.
    /// The last night images may fall early the next day because the window crosses midnight.
    static func fireDate(phase: DayPhase,
                         index: Int,
                         count: Int,
                         on day: Date,
                         coordinate: Coordinate,
                         calendar: Calendar = .current) -> Date? {
        guard count > 0, index >= 0, index < count else { return nil }
        guard let windows = windows(on: day, coordinate: coordinate, calendar: calendar) else {
            return nil
        }
        return windows.fireDate(phase: phase, index: index, count: count)
    }
}
