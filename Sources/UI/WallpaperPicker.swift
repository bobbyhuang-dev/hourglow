import AppKit
import SwiftUI

/// Aerial category names: English keys in `entries.json`, displayed in the current language.
/// Preserve unknown names so categories added by system updates do not appear blank.
enum Category {
    static let order = ["Landscapes", "Cities", "Underwater", "Space", "Mac"]

    static func localized(_ raw: String) -> String {
        L10n.value(forKey: "category.\(raw.lowercased())") ?? raw
    }
}

/// Wallpaper picker: a thumbnail grid of 156 system aerials, plus local images.
///
/// All thumbnails are cached locally in `aerials/thumbnails/`, so the grid opens immediately.
/// Undownloaded aerials remain selectable; macOS downloads their videos, while this view only marks them.
struct WallpaperPicker: View {
    @Environment(AppModel.self) private var model
    let slotID: UUID
    var open: (Page) -> Void

    @State private var query = ""
    @State private var category: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.t("picker.title"), back: { open(.slot(slotID)) })
            search
            chips
            Divider()
            grid
            Divider()
            footer
        }
    }

    // MARK: - Filtering

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L10n.t("picker.search"), text: $query)
                .textFieldStyle(.plain)
                .font(Panel.Font.control)
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
        .background(Panel.fieldFill,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, Panel.inset)
        .padding(.bottom, 6)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(title: L10n.t("picker.all"), value: nil)
                ForEach(availableCategories, id: \.self) { name in
                    chip(title: Category.localized(name), value: name)
                }
            }
            .padding(.horizontal, Panel.scrollInset)
        }
        .scrollIndicators(.never)
        // Fade both ends of the horizontally scrolling chips; a hard-clipped "Mac" looks like broken layout.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Panel.scrollInset)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Panel.scrollInset)
            }
        }
        .padding(.bottom, 8)
    }

    private func chip(title: String, value: String?) -> some View {
        let selected = category == value
        return Button {
            category = value
        } label: {
            Text(title)
                .font(Panel.Font.secondary.weight(selected ? .semibold : .regular))
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

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            if filtered.isEmpty {
                Text(L10n.t("picker.empty"))
                    .font(Panel.Font.control)
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filtered) { asset in
                    cell(asset)
                }
            }
            .padding(.horizontal, Panel.scrollInset)
            .padding(.vertical, 8)
            .background(VerticalOnlyScroll())
        }
        // Keep the 156-item grid at full height so category and search changes do not resize the panel.
        .frame(height: 330)
    }

    private func cell(_ asset: AerialAsset) -> some View {
        let selected = model.editing(slotID).map { $0.wallpaper == .aerial(assetID: asset.id) } ?? false
        return GridCell(asset: asset, selected: selected, tooltip: tooltip(asset)) {
            choose(.aerial(assetID: asset.id))
        }
    }

    /// A grid cell. Hover restores the name's primary color and darkens its border to locate the pointer among 156 items.
    /// Each cell owns its hover `@State`; managing 156 booleans in the parent would be unwieldy.
    private struct GridCell: View {
        let asset: AerialAsset
        let selected: Bool
        let tooltip: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Thumbnail(url: asset.thumbnailURL, size: CGSize(width: 104, height: 64), corner: 6)
                    // Dim undownloaded items only slightly: most of the 156 are undownloaded, so stronger dimming grays out the grid.
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
                            .strokeBorder(selected ? Color.accentColor
                                                   : Color.primary.opacity(hovering ? 0.35 : 0),
                                          lineWidth: selected ? 2 : 1)
                    }

                Text(asset.name)
                    .font(Panel.Font.caption)
                    .foregroundStyle(selected ? Color.accentColor
                                              : (hovering ? Color.primary : Color.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 104, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        }
    }

    private func tooltip(_ asset: AerialAsset) -> String {
        if let size = asset.sizeMB {
            return L10n.t("picker.tooltip.downloaded", asset.name, size)
        }
        // The manifest omits undownloaded sizes; an order-of-magnitude estimate is enough to inform the choice.
        return L10n.t("picker.tooltip.notDownloaded", asset.name)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.t("picker.chooseImage")) { chooseLocalImage() }
            Spacer(minLength: 0)
            Text(L10n.t(count: filtered.count, "picker.count",
                        filtered.count, filtered.filter(\.isDownloaded).count))
                .font(Panel.Font.caption)
                .foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 9)
    }

    // MARK: -

    /// Update only the draft; return to the slot page and wait for Apply.
    private func choose(_ wallpaper: Wallpaper) {
        model.editDraft { $0.wallpaper = wallpaper }
        open(.slot(slotID))
    }

    /// Opening a system dialog closes the menu bar panel on focus loss, so it is gone when selection finishes.
    /// The draft survives in `AppModel`; `PanelRoot` returns to this slot for editing when the panel reopens.
    private func chooseLocalImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L10n.t("picker.open.prompt")
        panel.message = L10n.t("picker.open.message")

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(.image(path: url.standardizedFileURL.path))
    }
}
