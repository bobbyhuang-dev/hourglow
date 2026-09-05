import Foundation

/// The evaluation result at a particular instant.
struct Resolution {
    /// The slot that should currently be active.
    var active: Slot
    /// When it became active.
    var since: Date
    /// The next transition. Nil when all slots are disabled.
    var next: (slot: Slot, at: Date)?
}

extension Trigger {
    /// Resolves the trigger to an absolute instant on `day`.
    /// Solar triggers return nil without coordinates or during polar day or night.
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

    /// Backtracks each slot's offset to its base day, then expands one day in either direction.
    ///
    /// Expanding around `now` uniformly would miss events: "48 hours after sunrise" firing
    /// today refers to sunrise two days ago, outside a yesterday/today/tomorrow window.
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
                // solarPhase triggers fall within the day's windows (night can cross midnight).
                // Anchoring on now and expanding one day each way includes those overnight images.
                anchor = now
            case .solar(_, let offsetMinutes):
                // fireDate adds this offset back; subtract it first to find the actual solar event day.
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
        // Users can specify identical trigger times. Swift's sort is not stable for equal elements;
        // use configuration order as a tie-breaker so the later slot consistently wins after restarts.
        return result.sorted {
            $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date
        }.map { (date: $0.date, slot: $0.slot) }
    }

    /// Takes the last firing no later than now. Before today's first slot,
    /// the entries expanded from the previous day provide the fallback.
    func resolve(at now: Date = Date(),
                 coordinate: Coordinate? = nil,
                 calendar: Calendar = .current) -> Resolution? {
        let coord = coordinate ?? effectiveCoordinate
        let all = firings(around: now, coordinate: coord, calendar: calendar)
        guard let current = all.last(where: { $0.date <= now }) else { return nil }
        // At a shared trigger time, `current` picks the later slot in configuration order.
        // The next transition must report that same winner, not announce A and then resolve to B.
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
