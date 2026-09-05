import SwiftUI

/// 今日天光条：状态区下面那条 24 小时的横带。
///
/// 时间轴那张列表只是一行行的「几点换哪张」，看不出这些时刻在一天里落在哪儿、
/// 白天黑夜各占多长。这条横带把同一份数据画成一天：底色按今天的天光渐变
/// （夜 → 晨光 → 白昼 → 晚霞 → 黄昏 → 夜），每个时段在它的触发时刻立一根标记，
/// 当前生效的那一段在底边描一根强调色，「现在」是一根竖着的游标。
///
/// 它是状态图形，不可点：点了该去哪儿说不清（一根标记 3 pt 宽，游标与标记又常常挤在一起），
/// 列表本身就在下面。颜色来自 `Sky`，和应用图标、指引顶栏是同一族。
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
            // 游标画在裁切之外：顶上的圆点要探出横带一点，不然与时段标记分不开。
            nowCursor(in: &context, bar: bar, day: day)
            ticks(in: &context, bar: bar)
        }
        .frame(height: Self.topInset + Panel.dayBarHeight + 3 + Panel.dayBarLabelHeight)
        .opacity(model.schedule.paused ? 0.5 : 1)
        .animation(Panel.animation, value: model.schedule.paused)
        .accessibilityLabel(accessibilityText)
    }

    /// 横带上方留给游标顶端那颗圆点探出来的空间。
    private static let topInset: CGFloat = 4

    // MARK: - 一天

    private struct Day {
        let start: Date
        let length: TimeInterval
        func x(_ date: Date, in bar: CGRect) -> CGFloat? {
            let t = date.timeIntervalSince(start) / length
            guard t >= 0, t <= 1 else { return nil }
            return bar.minX + bar.width * t
        }
    }

    /// 按日历取今天，夏令时切换的那天是 23 或 25 小时，不写死 86400。
    private static func today() -> Day {
        let now = AppModel.now()
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        return Day(start: interval.start, length: interval.duration)
    }

    // MARK: - 底色

    /// 没有坐标、或今天根本没有日出日落（极昼极夜）时铺一条中性灰：
    /// 不编造一个「大概的白天」，那和时间轴上的提示条说的话对不上。
    private func sky(_ day: Day) -> Gradient {
        guard let events = model.solarEventsToday else {
            return Gradient(colors: [Color.primary.opacity(0.10)])
        }
        // 晨昏算不出来（高纬夏天）时用日出日落各退 45 分钟当渐变的起止。
        // 只是画法上的兜底，求值那边（`TimeMap`）有自己的一套，别混为一谈。
        let fallback: TimeInterval = 45 * 60
        let dawn = events.nauticalDawn ?? events.sunrise.addingTimeInterval(-fallback)
        let dusk = events.civilDusk ?? events.sunset.addingTimeInterval(fallback)
        // 晨光与晚霞的橙色从日出日落往白天里铺一个多小时；铺得短了就是一道窄条纹，
        // 和横带上的时段标记混在一起。
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
        // 断点必须单调，赤道附近晨昏很短时相邻两点可能重合甚至倒过来。
        var last: CGFloat = 0
        for index in stops.indices {
            stops[index].location = max(stops[index].location, last)
            last = stops[index].location
        }
        return Gradient(stops: stops)
    }

    // MARK: - 标记

    /// 当前生效的那一段：从它开始生效到下一次切换，在横带底边描一根强调色。
    /// 与列表里行首那根 `Panel.nowBar` 是同一种颜色语言 —— 状态，不是选中。
    private func activeSpan(in context: inout GraphicsContext, bar: CGRect, day: Day) {
        guard let resolution = model.resolution, !model.schedule.paused else { return }
        let from = day.x(resolution.since, in: bar) ?? bar.minX
        let to = resolution.next.flatMap { day.x($0.at, in: bar) } ?? bar.maxX
        guard to > from else { return }
        let line = CGRect(x: from, y: bar.maxY - 2.5, width: to - from, height: 2.5)
        context.fill(Path(line), with: .color(.accentColor))
    }

    /// 每个时段在它今天的触发时刻立一根白色短线，带一点暗影，亮底暗底都看得见。
    /// 算不出时刻的（缺坐标的 solar 段）不画，停用的半透明。
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

    /// 「现在」：一根细竖线贯穿横带，顶上一个小圆点探出去。
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

    /// 刻度：0 / 6 / 12 / 18 / 24。纯数字，不进文案表。
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
