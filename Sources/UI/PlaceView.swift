import SwiftUI

/// Shared city-search state: immediate offline results, supplemented by geocoding after a 400 ms debounce.
///
/// The location page and onboarding have different layouts, but the same query must use the same
/// search logic, especially deduplication: offline and geocoded results often describe the same city.
/// Key by coordinates, not names, since localized and English names can identify the same place.
@MainActor
@Observable
final class CitySearch {
    private(set) var remote: [City] = []
    private(set) var searching = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Cities to display: offline matches first, then remote results.
    /// `near` only affects an empty query, sorting nearby cities by distance.
    func results(for query: String, near: Coordinate? = nil) -> [City] {
        var seen = Set<String>()
        var result: [City] = []
        for city in Cities.search(query, near: near) + remote {
            let key = String(format: "%.2f,%.2f",
                             city.coordinate.latitude, city.coordinate.longitude)
            if seen.insert(key).inserted { result.append(city) }
        }
        return result
    }

    /// Call on every input change. Require two characters and debounce rather than requesting each keystroke.
    func update(query: String) {
        task?.cancel()
        remote = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searching = false
            return
        }
        searching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let hits = await PlaceSearch.remote(trimmed)
            guard !Task.isCancelled else { return }
            self?.remote = hits
            self?.searching = false
        }
    }

    func clear() {
        task?.cancel()
        remote = []
        searching = false
    }
}

/// Choose a location: common cities are searchable offline; others use geocoding.
///
/// All of China uses `Asia/Shanghai`, so time-zone inference always picks Shanghai; sunrise in Shenzhen
/// or Zhangjiajie can differ by over ten to forty minutes. Location determines solar scheduling, not just preferences.
/// Write selections directly to `schedule.location`; the menu bar panel closes on focus loss, so do not depend on it staying open.
struct PlacePage: View {
    @Environment(AppModel.self) private var model
    var open: (Page) -> Void
    var backPage: Page = .timeline

    @State private var query = ""
    @State private var finder = CitySearch()
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.t("place.title"), back: { open(backPage) })
            current
            search
            sources
            Divider()
            list
            Divider()
            coordinates
        }
        .frame(height: Panel.height)
        .onAppear { seedFields() }
        .onChange(of: query) { _, _ in finder.update(query: query) }
        .onChange(of: model.schedule.location) { seedFields() }
    }

    // MARK: - Current location

    /// Show today's calculated times before offering location changes; locals can spot incorrect times immediately.
    private var current: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.placeLabel)
                    .font(Panel.Font.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(sunLine)
                .font(Panel.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let twilight = twilightLine {
                Text(twilight)
                    .font(Panel.Font.secondary)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            locatingHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Panel.inset)
        .padding(.bottom, 10)
    }

    private var sunLine: String {
        guard model.schedule.effectiveCoordinate != nil else {
            return L10n.t("place.sun.noCoordinate")
        }
        guard let times = model.solarToday else { return L10n.t("place.sun.polar") }
        return L10n.t("place.sun.today", Clock.string(times.sunrise), Clock.string(times.sunset))
    }

    /// These times can be absent in high-latitude summers; explain the nominal-duration daylight fallback honestly.
    private var twilightLine: String? {
        guard let events = model.solarEventsToday else { return nil }
        let dawn = events.nauticalDawn.map(Clock.string) ?? L10n.t("common.none")
        let dusk = events.civilDusk.map(Clock.string) ?? L10n.t("common.none")
        return L10n.t("place.twilight", dawn, dusk)
    }

    @ViewBuilder
    private var locatingHint: some View {
        switch model.locating {
        case .denied:
            // After denial, macOS will not prompt again. Link directly to the settings where permission can be restored.
            HStack(spacing: 6) {
                Text(L10n.t("place.denied"))
                    .font(Panel.Font.secondary)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.t("common.openSettings")) { PreciseLocation.openPrivacySettings() }
                    .controlSize(.small)
            }
        case .failed(let reason):
            Text(reason)
                .font(Panel.Font.secondary)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Panel.Font.secondary)
                .foregroundStyle(.secondary)
            TextField(L10n.t("place.search"), text: $query)
                .textFieldStyle(.plain)
                .font(Panel.Font.control)
            if finder.searching {
                ProgressView().controlSize(.mini)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    finder.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Panel.fieldFill,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, Panel.inset)
        .padding(.bottom, 8)
    }

    // MARK: - Sources

    private var sources: some View {
        VStack(spacing: 2) {
            Button {
                model.requestPreciseLocation()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.locating == .requesting ? "location.fill" : "location")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18)
                    Text(L10n.t(model.locating == .requesting ? "place.locating"
                                                              : "place.useCurrent"))
                        .font(Panel.Font.body)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
            }
            .buttonStyle(PanelRowStyle())
            .disabled(model.locating == .requesting)

            Button {
                model.setManualLocation(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe.asia.australia")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18)
                    Text(L10n.t("place.followTimeZone"))
                        .font(Panel.Font.body)
                    Spacer(minLength: 0)
                    if model.schedule.location == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
            }
            .buttonStyle(PanelRowStyle())
        }
        .padding(.horizontal, Panel.rowInset)
        .padding(.bottom, 6)
    }

    // MARK: - List

    private struct Section: Identifiable {
        var id: String
        var title: String
        var cities: [City]
    }

    /// An empty query shows one nearby section sorted by distance from the current coordinate.
    /// The old China/international split always put China first, reflecting the developer's location rather than the user's.
    private var sections: [Section] {
        let items = finder.results(for: query, near: model.schedule.effectiveCoordinate)
        guard !items.isEmpty else { return [] }
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return [Section(id: typed ? "hits" : "nearby",
                        title: L10n.t(typed ? "place.section.results" : "place.section.nearby"),
                        cities: items)]
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    Text(section.title)
                        .font(Panel.Font.section)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(section.cities) { city in
                        row(city)
                    }
                }
                if sections.isEmpty, !query.isEmpty, !finder.searching {
                    Text(L10n.t("place.notFound"))
                        .font(Panel.Font.control)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, Panel.rowInset)
            .padding(.bottom, 6)
            .background(VerticalOnlyScroll())
        }
    }

    private func row(_ city: City) -> some View {
        let selected = isSelected(city)
        return Button {
            model.setPlace(city)
            open(.timeline)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(city.name)
                        .font(Panel.Font.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(city.detail)
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Panel.rowHeight)
        }
        .buttonStyle(PanelRowStyle())
    }

    private func isSelected(_ city: City) -> Bool {
        guard let current = model.schedule.location else { return false }
        return abs(current.latitude - city.coordinate.latitude) < 0.02
            && abs(current.longitude - city.coordinate.longitude) < 0.02
    }

    // MARK: - Manual coordinates

    private var coordinates: some View {
        HStack(spacing: 6) {
            Text(L10n.t("place.latitude")).font(Panel.Font.secondary).foregroundStyle(.secondary)
            CoordinateField(text: $latitude)
            Text(L10n.t("place.longitude")).font(Panel.Font.secondary).foregroundStyle(.secondary)
            CoordinateField(text: $longitude)
            Spacer(minLength: 0)
            Button(L10n.t("place.use")) {
                if let typed { model.setManualLocation(typed) }
            }
            .controlSize(.small)
            // Compare coordinates only: `Coordinate` equality also includes the city name.
            // Otherwise identical coordinates enable this action and replace the city name with raw numbers.
            .disabled(typed == nil || sameSpotAsCurrent)
        }
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 8)
    }

    private var typed: Coordinate? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    private var sameSpotAsCurrent: Bool {
        guard let typed, let current = model.schedule.location else { return false }
        return typed.latitude == current.latitude && typed.longitude == current.longitude
    }

    private func seedFields() {
        guard let c = model.schedule.effectiveCoordinate else {
            latitude = ""
            longitude = ""
            return
        }
        latitude = String(format: "%.4f", c.latitude)
        longitude = String(format: "%.4f", c.longitude)
    }
}
