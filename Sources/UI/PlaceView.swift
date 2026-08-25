import SwiftUI

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
    @State private var remote: [City] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "选择地区", back: { open(backPage) })
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
        .onChange(of: query) { _, _ in scheduleRemoteSearch() }
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
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(sunLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let twilight = twilightLine {
                Text(twilight)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let hint = locatingHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Panel.inset)
        .padding(.bottom, 10)
    }

    private var sunLine: String {
        guard model.schedule.effectiveCoordinate != nil else {
            return "没有坐标，日出日落的时段会被跳过"
        }
        guard let times = model.solarToday else { return "今天是极昼或极夜" }
        return "今天 日出 \(Clock.string(times.sunrise)) · 日落 \(Clock.string(times.sunset))"
    }

    private var twilightLine: String? {
        guard let events = model.solarEventsToday else { return nil }
        return "航海晨光 \(Clock.string(events.nauticalDawn)) · 民用黄昏 \(Clock.string(events.civilDusk))"
    }

    private var locatingHint: String? {
        switch model.locating {
        case .denied: return "定位权限被拒，搜一个城市或在下面手填"
        case .failed(let reason): return reason
        default: return nil
        }
    }

    // MARK: - 搜索

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("城市名，中英文或拼音", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if searching {
                ProgressView().controlSize(.mini)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    remote = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35),
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
                    Text(model.locating == .requesting ? "正在定位…" : "使用当前位置")
                        .font(.system(size: 12.5))
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
                    Text("跟随系统时区")
                        .font(.system(size: 12.5))
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

    private var displayed: [City] {
        var seen = Set<String>()
        var result: [City] = []
        for city in Cities.search(query) + remote {
            let key = String(format: "%.2f,%.2f",
                             city.coordinate.latitude, city.coordinate.longitude)
            if seen.insert(key).inserted { result.append(city) }
        }
        return result
    }

    private var sections: [Section] {
        let items = displayed
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [Section(id: "hits", title: "搜索结果", cities: items)]
        }
        let china = items.filter(\.isChina)
        let world = items.filter { !$0.isChina }
        var result: [Section] = []
        if !china.isEmpty { result.append(Section(id: "cn", title: "中国", cities: china)) }
        if !world.isEmpty { result.append(Section(id: "world", title: "海外", cities: world)) }
        return result
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(section.cities) { city in
                        row(city)
                    }
                }
                if displayed.isEmpty, !query.isEmpty, !searching {
                    Text("找不到这个地方")
                        .font(.system(size: 12))
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
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(city.detail)
                        .font(.system(size: 11))
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
            Text("纬度").font(.system(size: 11)).foregroundStyle(.secondary)
            CoordinateField(text: $latitude)
            Text("经度").font(.system(size: 11)).foregroundStyle(.secondary)
            CoordinateField(text: $longitude)
            Spacer(minLength: 0)
            Button("使用") {
                if let typed { model.setManualLocation(typed) }
            }
            .controlSize(.small)
            .disabled(typed == nil || typed == model.schedule.location)
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

    private func seedFields() {
        guard let c = model.schedule.effectiveCoordinate else {
            latitude = ""
            longitude = ""
            return
        }
        latitude = String(format: "%.4f", c.latitude)
        longitude = String(format: "%.4f", c.longitude)
    }

    private func scheduleRemoteSearch() {
        searchTask?.cancel()
        remote = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            searching = false
            return
        }
        searching = true
        let task = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let hits = await PlaceSearch.remote(q)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                remote = hits
                searching = false
            }
        }
        searchTask = task
    }
}
