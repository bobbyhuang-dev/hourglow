import SwiftUI

/// 选地点：常用城市离线可搜，其余走地理编码。
///
/// 中国全境都是 `Asia/Shanghai`，时区推断永远落在上海，深圳 / 张家界的日出会差
/// 十几到四十分钟。菜单栏面板里弹系统定位对话框还能用，因为面板本来就会在失焦时收起；
/// 选完城市直接写进 `schedule.location`，不依赖面板还开着。
struct PlacePage: View {
    @Environment(AppModel.self) private var model
    var open: (Page) -> Void

    @State private var query = ""
    @State private var remote: [City] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "地点", back: { open(.settings) })
            current
            search
            actions
            Divider()
            list
        }
        .frame(height: Panel.height)
        .onChange(of: query) { _, _ in scheduleRemoteSearch() }
    }

    // MARK: - 当前

    private var current: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.placeLabel)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(todaySunLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Panel.inset)
        .padding(.bottom, 8)
    }

    private var todaySunLine: String {
        guard let coordinate = model.schedule.effectiveCoordinate,
              let times = Solar.times(on: Date(), at: coordinate) else {
            return "算不出今天的日出日落"
        }
        return "今天日出 \(Clock.string(times.sunrise)) · 日落 \(Clock.string(times.sunset))"
    }

    // MARK: - 搜索 / 操作

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

    private var actions: some View {
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(displayed) { city in
                    row(city)
                }
                if displayed.isEmpty, !query.isEmpty, !searching {
                    Text("找不到这个地方")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, Panel.rowInset)
            .padding(.vertical, 6)
        }
    }

    private func row(_ city: City) -> some View {
        let selected = isSelected(city)
        return Button {
            model.setPlace(city)
            open(.settings)
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
