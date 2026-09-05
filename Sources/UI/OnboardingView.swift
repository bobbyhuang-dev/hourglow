import AppKit
import SwiftUI

/// Onboarding: five steps, each with one task users can complete before moving on.
///
/// **Why a standalone window, not a sixth panel page:** HourGlow is an `LSUIElement`, so nothing
/// appears onscreen at first launch except a 16 pt hourglass in the menu bar. `MenuBarExtra` has
/// no API to open it on the user's behalf. A guide inside the panel would only reach users who
/// already found that entry point, excluding those who need it most. The first step must show
/// users where to open the app, and that explanation has to appear outside the panel.
///
/// Otherwise follow the panel's conventions: fixed layout (metrics in `PanelKit.Guide`),
/// native styling, and one topic at a time.
///
/// Step copy lives in `App/Onboarding.swift`, not here: content must remain independently checkable.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    /// Close this window for either Skip or Get Started; the window centrally records that it has been seen.
    var finish: () -> Void

    @State private var flow: OnboardingFlow
    /// Forward/backward navigation chooses the transition edge, matching the panel.
    @State private var forward = true
    @State private var query = ""
    @State private var finder = CitySearch()

    /// Only `panelshot` uses `initialStep` to capture all five steps rather than just the first.
    /// Normal presentation always starts at the beginning.
    init(initialStep: OnboardingStep = .welcome, finish: @escaping () -> Void) {
        self.finish = finish
        var flow = OnboardingFlow()
        flow.jump(to: initialStep)
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            content
            Divider()
            footer
        }
        .frame(width: Guide.width, height: Guide.height)
        .background(Color(nsColor: .windowBackgroundColor))
        // Ask the system for login startup state on entry and page changes, not on every redraw.
        .onAppear { model.refreshSettings() }
        .onChange(of: flow.index) { model.refreshSettings() }
    }

    // MARK: - Header illustration

    /// Share one sky gradient across all five steps, changing only the illustration so the background does not flash.
    private var hero: some View {
        ZStack {
            Guide.sky
            art
                .transition(.opacity)
                .id(flow.step)
        }
        .frame(height: Guide.heroHeight)
        .clipped()
        .animation(Panel.animation, value: flow.index)
    }

    @ViewBuilder
    private var art: some View {
        switch flow.step {
        case .welcome:  MenuBarArt(badge: nil)
        case .place:    SunArcArt(sunrise: model.solarToday?.sunrise,
                                  sunset: model.solarToday?.sunset)
        case .resident: MenuBarArt(badge: "checkmark")
        case .timeline: FilmstripArt(frames: filmstrip)
        case .done:     DoneArt()
        }
    }

    /// Step four's filmstrip: the first five slots from the user's own timeline.
    private var filmstrip: [FilmstripArt.Frame] {
        let active = model.resolution?.active.id
        return model.entries.prefix(5).map { entry in
            FilmstripArt.Frame(id: entry.slot.id,
                               url: model.thumbnailURL(for: entry.slot.wallpaper),
                               time: entry.time,
                               isActive: entry.slot.id == active)
        }
    }

    // MARK: - Body

    private var content: some View {
        // Stack pages in a ZStack: both are present during a horizontal transition,
        // and laying them out separately would double this area's height.
        ZStack {
            page
                .id(flow.step)
                .transition(slide)
        }
        .frame(width: Guide.width, height: Guide.contentHeight)
        .clipped()
        .animation(Panel.animation, value: flow.index)
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(flow.caption)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(flow.step.title)
                        .font(.system(size: 19, weight: .semibold))
                    Text(flow.step.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail
            }
            .padding(.horizontal, Guide.inset)
            .padding(.vertical, 18)
            .frame(width: Guide.width, alignment: .leading)
        }
        .frame(width: Guide.width, height: Guide.contentHeight)
    }

    @ViewBuilder
    private var detail: some View {
        switch flow.step {
        case .welcome:  welcomeDetail
        case .place:    placeDetail
        case .resident: residentDetail
        case .timeline: timelineDetail
        case .done:     doneDetail
        }
    }

    // MARK: - Step one: Where the app lives

    private var welcomeDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("cursorarrow.rays", L10n.t("guide.welcome.open.title"),
                   L10n.t("guide.welcome.open.body"))
            bullet("clock.arrow.circlepath", L10n.t("guide.welcome.background.title"),
                   L10n.t("guide.welcome.background.body"))
            bullet("hand.raised", L10n.t("guide.welcome.manual.title"),
                   L10n.t("guide.welcome.manual.body"))
            Text(L10n.t("guide.welcome.footnote"))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Step two: Location (the only permission requiring Allow)

    private var placeDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.placeLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(sunLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.locating == .requesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.t("place.useCurrent")) { model.requestPreciseLocation() }
                            .controlSize(.small)
                    }
                }

                // Explain permission beside the button: what happens, what macOS asks, and which response to choose.
                Text(L10n.t("guide.place.permission"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.locating == .denied {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Text(L10n.t("guide.place.denied"))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L10n.t("common.openSettings")) { PreciseLocation.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                if case .failed(let reason) = model.locating {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("guide.place.search.title"))
                    .font(.system(size: 12, weight: .medium))
                citySearchField
                cityResults
            }

            Text(L10n.t("guide.place.footnote"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sunLine: String {
        guard model.schedule.effectiveCoordinate != nil else {
            return L10n.t("place.sun.noCoordinate")
        }
        guard let times = model.solarToday else { return L10n.t("place.sun.polar") }
        return L10n.t("place.sun.today", Clock.string(times.sunrise), Clock.string(times.sunset))
    }

    private var citySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L10n.t("place.search"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if finder.searching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: query) { _, _ in finder.update(query: query) }
    }

    /// Show results only after a real query, limited to four.
    ///
    /// An empty `Cities.search` query returns common cities. They fit the full location page, not here:
    /// a default list would push searching itself offscreen. Further browsing belongs in the panel.
    @ViewBuilder
    private var cityResults: some View {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hits = typed ? Array(finder.results(for: query).prefix(4)) : []
        if hits.isEmpty {
            if typed, !finder.searching {
                Text(L10n.t("place.notFound"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        } else {
            VStack(spacing: 1) {
                ForEach(hits) { city in
                    Button { model.setPlace(city) } label: {
                        HStack(spacing: 6) {
                            Text(city.name)
                                .font(.system(size: 12))
                            Text(city.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isCurrent(city) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                    }
                    .buttonStyle(PanelRowStyle())
                }
            }
        }
    }

    private func isCurrent(_ city: City) -> Bool {
        guard let current = model.schedule.location else { return false }
        return abs(current.latitude - city.coordinate.latitude) < 0.02
            && abs(current.longitude - city.coordinate.longitude) < 0.02
    }

    // MARK: - Step three: Staying resident

    private var residentDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                if model.canLaunchAtLogin {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("settings.launchAtLogin"))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(L10n.t("settings.launchAtLogin.note"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(get: { model.launchAtLogin == .enabled },
                                                 set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }

                    if let note = model.launchAtLoginNote {
                        HStack(alignment: .top, spacing: 8) {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(L10n.t("common.openSettings")) { model.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }

                    // Login items store the bundle path. Enabling startup in Downloads and then moving
                    // the app to Applications leaves the login item pointing to a nonexistent app.
                    if !model.runsFromApplicationsFolder {
                        Divider()
                        Text(L10n.t("guide.resident.folder", model.enclosingFolderName))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L10n.t("guide.resident.unavailable"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            bullet("menubar.arrow.up.rectangle", L10n.t("guide.resident.menubar.title"),
                   L10n.t("guide.resident.menubar.body"))
            bullet("bolt.slash", L10n.t("guide.resident.quit.title"),
                   L10n.t("guide.resident.quit.body"))
        }
    }

    // MARK: - Step four: Timeline

    private var timelineDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("hand.tap", L10n.t("guide.timeline.edit.title"),
                   L10n.t("guide.timeline.edit.body"))
            bullet("plus", L10n.t("guide.timeline.add.title"),
                   L10n.t("guide.timeline.add.body"))
            bullet("photo.stack", L10n.t("guide.timeline.import.title"),
                   L10n.t("guide.timeline.import.body"))
            bullet("pause.circle", L10n.t("guide.timeline.pause.title"),
                   L10n.t("guide.timeline.pause.body"))
        }
    }

    // MARK: - Step five: Checklist

    private var doneDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                checklist(done: model.schedule.location != nil,
                          title: L10n.t("guide.done.place"),
                          detail: model.schedule.location != nil
                              ? model.placeLabel
                              : (model.schedule.effectiveCoordinate != nil
                                 ? L10n.t("guide.done.place.rough", model.placeLabel)
                                 : L10n.t("place.sun.noCoordinate")))
                Divider()
                checklist(done: model.launchAtLogin == .enabled,
                          title: L10n.t("guide.done.launch"),
                          detail: model.canLaunchAtLogin
                              ? L10n.t(model.launchAtLogin == .enabled ? "guide.done.launch.on"
                                                                      : "guide.done.launch.off")
                              : L10n.t("guide.done.launch.unavailable"))
                Divider()
                checklist(done: !model.schedule.slots.isEmpty,
                          title: L10n.t("guide.done.timeline"),
                          detail: L10n.t(count: model.schedule.slots.count,
                                         "guide.done.timeline.count", model.schedule.slots.count)
                              + (model.resolution.map {
                                    L10n.t("guide.done.timeline.active",
                                           model.name(for: $0.active.wallpaper))
                                 } ?? L10n.t("guide.done.timeline.none")))
            }

            bullet("menubar.rectangle", L10n.t("guide.done.entry.title"),
                   L10n.t("guide.done.entry.body"))
            bullet("questionmark.circle", L10n.t("guide.done.again.title"),
                   L10n.t("guide.done.again.body"))
        }
    }

    private func checklist(done: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        ZStack {
            dots
            HStack(spacing: 8) {
                if !flow.isLast {
                    Button(L10n.t("guide.skip")) { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !flow.isFirst {
                    Button(L10n.t("guide.back")) {
                        forward = false
                        flow.back()
                    }
                    .controlSize(.regular)
                }
                Button(L10n.t(flow.isLast ? "guide.start" : "guide.next")) {
                    if flow.isLast {
                        finish()
                    } else {
                        forward = true
                        flow.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Guide.inset)
        }
        .frame(height: Guide.footerHeight)
    }

    /// Five progress dots, with the current step filled, show how much remains so users can decide whether to skip.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<flow.count, id: \.self) { index in
                Circle()
                    .fill(index == flow.index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(Panel.animation, value: flow.index)
    }

    // MARK: - Components

    /// A body item: icon, one sentence, and supporting detail. These carry the guide's explanations.
    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// An interactive area styled like the settings page's grouped cards.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}

// MARK: - Illustrations

extension Guide {
    /// Night → dawn glow, sharing the app icon's gradient so the guide and icon feel related.
    static var sky: LinearGradient {
        LinearGradient(colors: [Sky.night, Sky.dusk, Sky.glow],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A stylized Mac: menu bar at the top, with the hourglass circled on the right.
///
/// Step one explains where to open the app; a picture communicates that much faster than prose.
/// Step three reuses the image with a checkmark on the hourglass to show it returns after login,
/// avoiding the need to interpret an unfamiliar illustration.
private struct MenuBarArt: View {
    var badge: String?

    /// Stylized Mac dimensions. Exaggerate the menu bar because it is the subject of the illustration:
    /// realistic proportions would leave only two or three pixels of height and an unrecognizable hourglass.
    private static let screen = CGSize(width: 344, height: 88)
    private static let barHeight: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.23),
                                          Color(red: 0.31, green: 0.22, blue: 0.28)],
                                 startPoint: .top, endPoint: .bottom))
            // Include wallpaper in the screen; an empty dark rectangle looks like a failed image load.
            .overlay(alignment: .bottom) { wallpaper }
            .overlay(alignment: .top) { menuBar }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .frame(width: Self.screen.width, height: Self.screen.height)
    }

    /// Schematic wallpaper: a faint glow brightening from the center toward the bottom.
    /// The former glowing sun in the center was removed: this step points to the menu bar,
    /// and a bright central object draws attention away from the hourglass at the top right.
    private var wallpaper: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.13)],
                       startPoint: .center, endPoint: .bottom)
            .frame(height: Self.screen.height - Self.barHeight)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9,
                                              style: .continuous))
    }

    private var menuBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
            Text("Finder").font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "switch.2")
            hourglass
            Text("9:41").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 11)
        .frame(height: Self.barHeight)
        .background(.white.opacity(0.14))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9,
                                          style: .continuous))
    }

    /// Circle the hourglass: a dashed ring is a familiar "look here" cue that needs no extra words.
    private var hourglass: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(.white.opacity(0.22), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    .frame(width: 27, height: 27)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Color.green, in: Circle())
                        .offset(x: 6, y: 5)
                }
            }
    }
}

/// Today's sun position: a horizon, an arc, and a sun placed along it using the current time.
///
/// Calculate the position rather than decorating arbitrarily: step two explains location-based solar times,
/// and an accurate picture is more convincing than a promise. Without coordinates, gray the sun at the horizon.
private struct SunArcArt: View {
    var sunrise: Date?
    var sunset: Date?

    /// 0 = sunrise, 1 = sunset; nil without coordinates.
    private var progress: Double? {
        guard let sunrise, let sunset else { return nil }
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return nil }
        return min(max(Date().timeIntervalSince(sunrise) / total, 0), 1)
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let base = size.height - 22
                let radius = min(size.width / 2 - 26, base - 10)
                let center = CGPoint(x: size.width / 2, y: base)

                var arc = Path()
                arc.addArc(center: center, radius: radius,
                           startAngle: .degrees(180), endAngle: .degrees(360),
                           clockwise: false)
                context.stroke(arc, with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - radius - 16, y: base))
                horizon.addLine(to: CGPoint(x: center.x + radius + 16, y: base))
                context.stroke(horizon, with: .color(.white.opacity(0.55)), lineWidth: 1)

                let t = progress ?? 0.0
                let sun = CGPoint(x: center.x - radius * cos(.pi * t),
                                  y: base - radius * sin(.pi * t))
                let known = progress != nil
                let glow = CGRect(x: sun.x - 11, y: sun.y - 11, width: 22, height: 22)
                context.fill(Path(ellipseIn: glow),
                             with: .color(.white.opacity(known ? 0.22 : 0.1)))
                let disc = CGRect(x: sun.x - 6, y: sun.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: disc),
                             with: .color(known
                                          ? Color(red: 1, green: 0.85, blue: 0.45)
                                          : .white.opacity(0.4)))
            }
            .frame(width: 300, height: 104)
        }
        .frame(width: 300, height: 104)
        .overlay(alignment: .bottomLeading) { label(L10n.t("sun.sunrise"), sunrise) }
        .overlay(alignment: .bottomTrailing) { label(L10n.t("sun.sunset"), sunset) }
    }

    private func label(_ name: String, _ date: Date?) -> some View {
        Text("\(name) \(Clock.string(date))")
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
}

/// Filmstrip of the user's timeline: thumbnails with today's actual times and an outline around the active frame.
///
/// Step four explains that the panel's central list represents a day. Show the user's own images
/// rather than a mock example, so they recognize the same set when they open the panel.
private struct FilmstripArt: View {
    struct Frame: Identifiable {
        let id: UUID
        let url: URL?
        let time: Date?
        let isActive: Bool
    }

    var frames: [Frame]

    var body: some View {
        HStack(spacing: 8) {
            if frames.isEmpty {
                Text(L10n.t("guide.timeline.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(frames) { frame in
                    VStack(spacing: 5) {
                        Thumbnail(url: frame.url, size: CGSize(width: 66, height: 41))
                            .overlay {
                                if frame.isActive {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 1.5)
                                }
                            }
                        Text(Clock.string(frame.time))
                            .font(.system(size: 9, weight: frame.isActive ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(frame.isActive ? 1 : 0.7))
                    }
                }
            }
        }
        .frame(height: 104)
    }
}

/// Finish: an hourglass with a checkmark.
private struct DoneArt: View {
    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.white)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, Color.green)
                    .offset(x: 12, y: 4)
            }
            .frame(height: 104)
    }
}
