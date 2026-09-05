import SwiftUI

/// 城市搜索的共用状态：离线表立刻出结果，联网的地理编码去抖 400 毫秒后补进来。
///
/// 地点页和新手指引的版式完全不同，但「同一个词搜出来的是哪几个城市」必须是同一套
/// 逻辑 —— 尤其是去重：离线表和地理编码经常给出同一个城市，键是坐标而不是名字
/// （「深圳」和「Shenzhen」是同一处）。
@MainActor
@Observable
final class CitySearch {
    private(set) var remote: [City] = []
    private(set) var searching = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// 当前该显示的城市。离线表在前，联网结果补在后面。
    func results(for query: String) -> [City] {
        var seen = Set<String>()
        var result: [City] = []
        for city in Cities.search(query) + remote {
            let key = String(format: "%.2f,%.2f",
                             city.coordinate.latitude, city.coordinate.longitude)
            if seen.insert(key).inserted { result.append(city) }
        }
        return result
    }

    /// 输入框每变一次调一次。一个字母就发一次网络请求没有意义，所以两字起、去抖。
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

/// 选地区：常用城市离线可搜，其余走地理编码。
///
/// 中国全境都是 `Asia/Shanghai`，时区推断永远落在上海，深圳 / 张家界的日出会差
/// 十几到四十分钟。日出日落按这个点算，所以地区是调度的一部分，不是设置里的附录。
/// 选完城市直接写进 `schedule.location`；菜单栏面板失焦会收起，不依赖它还开着。
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

    // MARK: - 当前

    /// 先报「算出来的今天」，再让人改地方。数字对不对，本地人一眼知道。
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

    /// 高纬夏天这两个时刻可能不存在，此时天光分段按名义时长兜底，如实说清楚。
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
            // 被拒之后系统不会再弹第二次框，只能自己去开。说了在哪儿改，就得能点过去。
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

    // MARK: - 搜索

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

    // MARK: - 来源

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

    // MARK: - 列表

    private struct Section: Identifiable {
        var id: String
        var title: String
        var cities: [City]
    }

    private var sections: [Section] {
        let items = finder.results(for: query)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [Section(id: "hits", title: L10n.t("place.section.results"), cities: items)]
        }
        let china = items.filter(\.isChina)
        let world = items.filter { !$0.isChina }
        var result: [Section] = []
        if !china.isEmpty {
            result.append(Section(id: "cn", title: L10n.t("place.section.china"), cities: china))
        }
        if !world.isEmpty {
            result.append(Section(id: "world", title: L10n.t("place.section.world"), cities: world))
        }
        return result
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
                if finder.results(for: query).isEmpty, !query.isEmpty, !finder.searching {
                    Text(L10n.t("place.notFound"))
                        .font(Panel.Font.control)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, Panel.rowInset)
            .padding(.bottom, 6)
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

    // MARK: - 手填

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
            // 只比坐标：`Coordinate` 的相等还包含城市名，拿它判断会让「和当前城市
            // 一模一样的经纬度」也可点，点下去把城市名抹成一串裸数字。
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
