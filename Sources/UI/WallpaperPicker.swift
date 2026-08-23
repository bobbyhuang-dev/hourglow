import AppKit
import SwiftUI

/// aerial 分类名。`entries.json` 里是英文键，面板上给中文。
/// 遇到没见过的分类原样显示 —— 系统更新加了新分类也不至于露出空白。
enum Category {
    static let order = ["Landscapes", "Cities", "Underwater", "Space", "Mac"]

    private static let names = [
        "Landscapes": "风景",
        "Cities": "城市",
        "Underwater": "水下",
        "Space": "太空",
        "Mac": "Mac",
    ]

    static func localized(_ raw: String) -> String { names[raw] ?? raw }
}

/// 壁纸选择器：156 张系统 aerial 的缩略图网格，外加本地图片。
///
/// 缩略图全部已缓存在本地（`aerials/thumbnails/`），所以网格是秒开的；
/// 未下载的那些照样能选，系统会自己去拉视频，这里只把它标出来。
struct WallpaperPicker: View {
    @Environment(AppModel.self) private var model
    let slotID: UUID
    var open: (Page) -> Void

    @State private var query = ""
    @State private var category: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "选择壁纸", back: { open(.slot(slotID)) })
            search
            chips
            Divider()
            grid
            Divider()
            footer
        }
    }

    // MARK: - 筛选

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
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
        .padding(.bottom, 6)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(title: "全部", value: nil)
                ForEach(availableCategories, id: \.self) { name in
                    chip(title: Category.localized(name), value: name)
                }
            }
            .padding(.horizontal, Panel.inset)
        }
        .scrollIndicators(.never)
        .padding(.bottom, 8)
    }

    private func chip(title: String, value: String?) -> some View {
        let selected = category == value
        return Button {
            category = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var availableCategories: [String] {
        let present = Set(model.catalog.flatMap(\.categories))
        return Category.order.filter(present.contains)
            + present.subtracting(Category.order).sorted()
    }

    private var filtered: [AerialAsset] {
        model.catalog.filter { asset in
            if let category, !asset.categories.contains(category) { return false }
            guard !query.isEmpty else { return true }
            return asset.name.localizedCaseInsensitiveContains(query)
                || asset.shotID.localizedCaseInsensitiveContains(query)
                || asset.categories.contains { Category.localized($0).contains(query)
                                               || $0.localizedCaseInsensitiveContains(query) }
        }
    }

    // MARK: - 网格

    private var grid: some View {
        ScrollView {
            if filtered.isEmpty {
                Text("没有匹配的壁纸")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filtered) { asset in
                    cell(asset)
                }
            }
            .padding(.horizontal, Panel.rowInset)
            .padding(.vertical, 8)
        }
        // 156 张，网格固定铺满：翻分类、搜关键词时面板不该跟着一跳一跳。
        .frame(height: 330)
    }

    private func cell(_ asset: AerialAsset) -> some View {
        let selected = model.editing(slotID).map { $0.wallpaper == .aerial(assetID: asset.id) } ?? false

        return Button {
            choose(.aerial(assetID: asset.id))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Thumbnail(url: asset.thumbnailURL, size: CGSize(width: 104, height: 64), corner: 6)
                    // 未下载的压暗一点。156 张里绝大多数都没下载，压太狠整个网格都是灰的。
                    .opacity(asset.isDownloaded ? 1 : 0.7)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(3)
                        } else if !asset.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white, .black.opacity(0.45))
                                .padding(3)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                    }

                Text(asset.name)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 104, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tooltip(asset))
    }

    private func tooltip(_ asset: AerialAsset) -> String {
        if let size = asset.sizeMB { return "\(asset.name) · 已下载 \(size) MB" }
        // 未下载的拿不到确切体积（manifest 里没有这一项），给个量级就够决策了。
        return "\(asset.name) · 未下载，切换时由系统自行拉取，每张约 400 MB"
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button("选择本地图片…") { chooseLocalImage() }
            Spacer(minLength: 0)
            Text("\(filtered.count) 张 · 已下载 \(filtered.filter(\.isDownloaded).count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 9)
    }

    // MARK: -

    /// 只改草稿，回时段页等用户点「应用」。
    private func choose(_ wallpaper: Wallpaper) {
        model.editDraft { $0.wallpaper = wallpaper }
        open(.slot(slotID))
    }

    /// 面板会在打开系统对话框时收起（菜单栏面板一失焦就关），选完时面板已经不在了。
    /// 草稿活在 `AppModel` 里不受影响，面板再打开时 `PanelRoot` 会回到这一段继续编辑。
    private func chooseLocalImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        panel.message = "选一张图片作为这个时段的壁纸"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(.image(path: url.standardizedFileURL.path))
    }
}
