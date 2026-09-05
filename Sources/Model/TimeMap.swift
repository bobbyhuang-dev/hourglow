import Foundation

/// 把一组壁纸均分到当天的四段天光里。
///
/// 对齐 24 Hour Wallpaper / Sunshift 的 ProTime 窗口，而不是「正好日出到正好日落」：
/// 日出段从航海晨光开始，越过日出后再走三分之一段晨光；日落段提前三分之一
/// 段黄昏开始，到民用黄昏结束。这样黄金时刻的几张照片不会被压在日出那一分钟上。
///
/// 每一段再按该段的张数等分。3 张日出和 5 张日出占同一段太阳时间，只是切得更细。
/// 窗口本身每天按当地太阳位置重算，所以冬夏的切换时刻会跟着走，不把钟点写死。
enum TimeMap {

    /// 高纬夏天太阳掉不到 −12°/−6°，航海晨光与民用黄昏根本不存在。
    /// 这时用一个名义时长顶上：既不能取 0（几张日出会挤在几十秒里连着刷过去，
    /// 还会连着 killall 三次 WallpaperAgent），也不能拿它去覆盖真实存在的晨昏
    /// （赤道的民用黄昏本来就只有二十来分钟）—— 所以只在「算不出来」时才用。
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

        // 仍留一个下限：极端情况下算出来的晨昏也可能贴到日出上，避免除零。
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

    /// 该段第 `index` 张（0-based）在 `day` 这一天的触发时刻。
    /// 夜晚最后几张可能落在次日凌晨，这是窗口跨午夜的自然结果。
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
