import Foundation

/// 某一时刻的求值结果。
struct Resolution {
    /// 当前应当生效的时段。
    var active: Slot
    /// 它是从什么时候开始生效的。
    var since: Date
    /// 下一次切换。全部时段都被禁用时为 nil。
    var next: (slot: Slot, at: Date)?
}

extension Trigger {
    /// 把触发条件解析成 `day` 那一天的绝对时刻。
    /// solar 类型在缺少坐标、或该日为极昼极夜时返回 nil。
    func fireDate(on day: Date, coordinate: Coordinate?, calendar: Calendar) -> Date? {
        switch self {
        case .clock(let hour, let minute):
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        case .solar(let event, let offsetMinutes):
            guard let coordinate,
                  let base = Solar.time(of: event, on: day, at: coordinate, calendar: calendar)
            else { return nil }
            return base.addingTimeInterval(Double(offsetMinutes) * 60)
        case .solarPhase(let phase, let index, let count):
            guard let coordinate else { return nil }
            return TimeMap.fireDate(phase: phase,
                                    index: index,
                                    count: count,
                                    on: day,
                                    coordinate: coordinate,
                                    calendar: calendar)
        }
    }
}

extension Schedule {

    /// 每个时段以其触发偏移反推基准日，再前后各展开一天。
    ///
    /// 不能统一围绕 `now` 展开：例如“日出后 48 小时”在今天触发时，
    /// 对应的太阳事件实际发生在前天。统一只看昨天、今天、明天会漏掉它。
    func firings(around now: Date,
                 coordinate: Coordinate?,
                 calendar: Calendar = .current) -> [(date: Date, slot: Slot)] {
        var result: [(date: Date, slot: Slot, order: Int)] = []
        // Every image in a phase uses the same day's solar windows. Cache only within this
        // evaluation so location, time zone, and date changes can never reuse stale results.
        // Store nil results too: polar days must not repeat the same unsuccessful calculation.
        var phaseWindows: [Date: TimeMap.DayWindows?] = [:]
        func windows(on day: Date) -> TimeMap.DayWindows? {
            if let cached = phaseWindows[day] { return cached }
            let computed = coordinate.flatMap {
                TimeMap.windows(on: day, coordinate: $0, calendar: calendar)
            }
            phaseWindows.updateValue(computed, forKey: day)
            return computed
        }
        for (order, slot) in slots.enumerated() where slot.enabled {
            let anchor: Date
            switch slot.trigger {
            case .clock, .solarPhase:
                // solarPhase 的触发点都落在当天窗口内（夜晚可跨过午夜），
                // 用 now 当锚、前后各展开一天就够接到跨午夜的那几张。
                anchor = now
            case .solar(_, let offsetMinutes):
                // fireDate 会把相同的偏移加回来；先减掉它，便能找到真正的太阳事件日。
                anchor = now.addingTimeInterval(-Double(offsetMinutes) * 60)
            }

            for dayOffset in -1...1 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: anchor) else {
                    continue
                }
                let date: Date?
                if case .solarPhase(let phase, let index, let count) = slot.trigger {
                    date = windows(on: day)?.fireDate(phase: phase, index: index, count: count)
                } else {
                    date = slot.trigger.fireDate(on: day, coordinate: coordinate, calendar: calendar)
                }
                if let date {
                    result.append((date, slot, order))
                }
            }
        }
        // 用户可以手写两个完全相同的触发时刻。Swift 的 sort 不保证相等元素稳定，
        // 不补第二排序键的话，重启之后谁胜出可能改变；这里明确让配置中靠后的时段胜出。
        return result.sorted {
            $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date
        }.map { (date: $0.date, slot: $0.slot) }
    }

    /// 取「不晚于此刻」的最后一次触发；若全都在未来，说明还没轮到今天的第一段，
    /// 由前一天展开出的条目兜底。
    func resolve(at now: Date = Date(),
                 coordinate: Coordinate? = nil,
                 calendar: Calendar = .current) -> Resolution? {
        let coord = coordinate ?? effectiveCoordinate
        let all = firings(around: now, coordinate: coord, calendar: calendar)
        guard let current = all.last(where: { $0.date <= now }) else { return nil }
        // 同一时刻有多个时段时，`current` 会取配置中靠后的一个；“下一次切换”也必须
        // 报同一个胜出者，不能先预告 A，到点后却解析成 B。
        let upcoming: (date: Date, slot: Slot)?
        if let nextDate = all.first(where: { $0.date > now })?.date {
            upcoming = all.last(where: { $0.date == nextDate })
        } else {
            upcoming = nil
        }
        return Resolution(active: current.slot,
                          since: current.date,
                          next: upcoming.map { (slot: $0.slot, at: $0.date) })
    }
}
