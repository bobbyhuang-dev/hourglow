import SwiftUI

/// Today's daylight bar: the 24-hour strip below the status area.
///
/// The timeline lists when each wallpaper changes, but not where those times fall in the day
/// or how long day and night last. This strip renders the same data as a day: its background
/// follows today's sky (night → dawn glow → daylight → sunset glow → dusk → night),
/// with a marker at each slot's trigger, an accent underline for the active span, and a "now" cursor.
///
/// This is a noninteractive status graphic: a 3 pt marker beside the cursor is an ambiguous click
/// target, and the list is right below. Colors come from `Sky`, shared with the app icon and guide header.
struct DayBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { context, size in
            let day = Self.today()
            let bar = CGRect(x: 0, y: Self.topInset, width: size.width, height: Panel.dayBarHeight)
            let clip = Path(roundedRect: bar, cornerRadius: Panel.dayBarCorner, style: .continuous)

            context.fill(clip, with: .linearGradient(sky(day), startPoint: bar.origin,
                                                     endPoint: CGPoint(x: bar.maxX, y: bar.minY)))
            context.stroke(clip, with: .color(.black.opacity(0.10)), lineWidth: 0.5)

            context.drawLayer { layer in
                layer.clip(to: clip)
                activeSpan(in: &layer, bar: bar, day: day)
                markers(in: &layer, bar: bar, day: day)
            }
            // Draw outside the clip so the cursor's top dot protrudes and stays distinct from slot markers.
            nowCursor(in: &context, bar: bar, day: day)
            ticks(in: &context, bar: bar)
        }
        .frame(height: Self.topInset + Panel.dayBarHeight + 3 + Panel.dayBarLabelHeight)
        .opacity(model.schedule.paused ? 0.5 : 1)
        .animation(Panel.animation, value: model.schedule.paused)
        .accessibilityLabel(accessibilityText)
    }

    /// Space above the strip for the cursor's top dot.
    private static let topInset: CGFloat = 4

    // MARK: - Day

    private struct Day {
        let start: Date
        let length: TimeInterval
        func x(_ date: Date, in bar: CGRect) -> CGFloat? {
            let t = date.timeIntervalSince(start) / length
            guard t >= 0, t <= 1 else { return nil }
            return bar.minX + bar.width * t
        }
    }

    /// Use calendar boundaries: daylight-saving transitions make a day 23 or 25 hours, not always 86400 seconds.
    private static func today() -> Day {
        let now = AppModel.now()
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        return Day(start: interval.start, length: interval.duration)
    }

    // MARK: - Background

    /// Use neutral gray without coordinates or sunrise/sunset (polar day or night).
    /// Inventing an approximate daytime would contradict the timeline notice.
    private func sky(_ day: Day) -> Gradient {
        guard let events = model.solarEventsToday else {
            return Gradient(colors: [Color.primary.opacity(0.10)])
        }
        // If twilight cannot be calculated (high-latitude summer), extend sunrise/sunset by 45 minutes.
        // This is only a drawing fallback; `TimeMap` has separate evaluation rules.
        let fallback: TimeInterval = 45 * 60
        let dawn = events.nauticalDawn ?? events.sunrise.addingTimeInterval(-fallback)
        let dusk = events.civilDusk ?? events.sunset.addingTimeInterval(fallback)
        // Spread the warm sunrise/sunset orange over more than an hour into daytime.
        // A shorter transition looks like a narrow stripe and blends into the slot markers.
        let warm: TimeInterval = 100 * 60
        let lead: TimeInterval = 30 * 60

        func at(_ date: Date) -> CGFloat {
            CGFloat(min(max(date.timeIntervalSince(day.start) / day.length, 0), 1))
        }
        var stops: [Gradient.Stop] = [
            .init(color: Sky.night, location: 0),
            .init(color: Sky.night, location: at(dawn.addingTimeInterval(-lead))),
            .init(color: Sky.dusk, location: at(dawn)),
            .init(color: Sky.glow, location: at(events.sunrise)),
            .init(color: Sky.day, location: at(events.sunrise.addingTimeInterval(warm))),
            .init(color: Sky.day, location: at(events.sunset.addingTimeInterval(-warm))),
            .init(color: Sky.glow, location: at(events.sunset)),
            .init(color: Sky.dusk, location: at(dusk)),
            .init(color: Sky.night, location: at(dusk.addingTimeInterval(lead))),
            .init(color: Sky.night, location: 1),
        ]
        // Stops must be monotonic: short twilight near the equator can make neighbors coincide or reverse.
        var last: CGFloat = 0
        for index in stops.indices {
            stops[index].location = max(stops[index].location, last)
            last = stops[index].location
        }
        return Gradient(stops: stops)
    }

    // MARK: - Markers

    /// Underline the active span in the accent color, from its start to the next change.
    /// Like the list's leading `Panel.nowBar`, this color indicates status, not selection.
    private func activeSpan(in context: inout GraphicsContext, bar: CGRect, day: Day) {
        guard let resolution = model.resolution, !model.schedule.paused else { return }
        let from = day.x(resolution.since, in: bar) ?? bar.minX
        let to = resolution.next.flatMap { day.x($0.at, in: bar) } ?? bar.maxX
        guard to > from else { return }
        let line = CGRect(x: from, y: bar.maxY - 2.5, width: to - from, height: 2.5)
        context.fill(Path(line), with: .color(.accentColor))
    }

    /// Mark each slot's trigger today with a short white line and shadow, visible on light or dark backgrounds.
    /// Omit unresolved times (solar slots without coordinates); disabled slots are translucent.
    private func markers(in context: inout GraphicsContext, bar: CGRect, day: Day) {
        for entry in model.entries {
            guard let time = entry.time, let x = day.x(time, in: bar) else { continue }
            let size = Panel.dayBarMarker
            let rect = CGRect(x: x - size.width / 2, y: bar.midY - size.height / 2,
                              width: size.width, height: size.height)
            let path = Path(roundedRect: rect, cornerRadius: size.width / 2)
            let alpha: CGFloat = entry.slot.enabled ? 1 : 0.4
            context.fill(Path(roundedRect: rect.insetBy(dx: -0.75, dy: -0.75),
                              cornerRadius: size.width),
                         with: .color(.black.opacity(0.28 * alpha)))
            context.fill(path, with: .color(.white.opacity(0.95 * alpha)))
        }
    }

    /// "Now": a thin vertical line through the strip, with a small dot protruding above it.
    private func nowCursor(in context: inout GraphicsContext, bar: CGRect, day: Day) {
        guard let x = day.x(AppModel.now(), in: bar) else { return }
        var line = Path()
        line.move(to: CGPoint(x: x, y: bar.minY - 1))
        line.addLine(to: CGPoint(x: x, y: bar.maxY + 1))
        context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 3)
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        let dot = CGRect(x: x - 2.5, y: bar.minY - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(.white.opacity(0.9)))
        context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
    }

    /// Ticks: 0 / 6 / 12 / 18 / 24. Bare numbers need no localization entries.
    private func ticks(in context: inout GraphicsContext, bar: CGRect) {
        let baseline = bar.maxY + 3 + Panel.dayBarLabelHeight / 2
        for hour in stride(from: 0, through: 24, by: 6) {
            let x = bar.minX + bar.width * CGFloat(hour) / 24
            let text = Text(String(hour))
                .font(Panel.Font.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            let anchor: UnitPoint = hour == 0 ? .leading : (hour == 24 ? .trailing : .center)
            context.draw(text, at: CGPoint(x: x, y: baseline), anchor: anchor)
        }
    }

    private var accessibilityText: String {
        guard let next = model.resolution?.next else { return L10n.t("timeline.subtitle.single") }
        return L10n.t("timeline.subtitle.next", Clock.string(next.at),
                      model.name(for: next.slot.wallpaper), Clock.remaining(until: next.at))
    }
}
