import AppKit
import SwiftUI

// 面板的固定尺寸与共用零件。所有页面共享同一套度量，换页时不跳尺寸。

enum Panel {
    static let width: CGFloat = 360
    /// 选壁纸那页固定这么高（网格要铺得开）；时间轴与时段页按内容收，收到这个上限为止。
    static let height: CGFloat = 470
    /// 时间轴列表最多这么高，再多就滚动。约等于 7 行。
    static let listMaxHeight: CGFloat = 300
    /// 左右留白。行的圆角背景要比它再往外一点，所以行自己用 `rowInset`。
    static let inset: CGFloat = 12
    static let rowInset: CGFloat = 8
    static let rowHeight: CGFloat = 44
    static let corner: CGFloat = 7
    static let animation: Animation = .snappy(duration: 0.22)
}

// MARK: - 页头

/// 统一的页头：左侧返回、居中标题、右侧附件。三页都用它，标题位置不会左右跳。
struct PanelHeader<Trailing: View>: View {
    var title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 0) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Spacer(minLength: 0)
                trailing()
            }
        }
        .padding(.horizontal, Panel.rowInset)
        .frame(height: 38)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.init(title: title, back: back, trailing: { EmptyView() })
    }
}

// MARK: - 分区

/// 「系统设置」那种分组：小标题 + 一块浅底圆角卡片。
struct PanelSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - 行

/// 列表行的按钮样式：悬停时一层淡底，按下再深一点。菜单栏面板里最像原生的做法。
struct PanelRowStyle: ButtonStyle {
    var tinted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, tinted: tinted)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let tinted: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: Panel.corner, style: .continuous))
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return .primary.opacity(0.12) }
            if tinted { return .accentColor.opacity(hovering ? 0.20 : 0.13) }
            return hovering ? .primary.opacity(0.06) : .clear
        }
    }
}

// MARK: - 缩略图

/// 缩略图解码不在主线程做，结果按 URL 缓存。
/// 156 张 aerial 缩略图各约 50 KB，滚动时逐张同步解码会明显掉帧。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            ThumbnailCache.decode(url, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// 走 ImageIO 直接出缩略图：本地图片可能是几十 MB 的 HEIC，
    /// 整张解码进内存只为了画 100 pt 宽的一格并不值得。
    private static func decode(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 一格壁纸缩略图。读不到（未下载的本地图、缺文件）时退化成一个占位方块。
struct Thumbnail: View {
    var url: URL?
    var size: CGSize
    var corner: CGFloat = 5

    @State private var image: NSImage?

    init(url: URL?, size: CGSize, corner: CGFloat = 5) {
        self.url = url
        self.size = size
        self.corner = corner
        // 缓存里已经有就直接拿：翻回上一页、重新滚回来时不该再闪一下占位方块。
        _image = State(initialValue: url.flatMap { ThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: min(size.height, size.width) * 0.4))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
            }
            .task(id: url) {
                image = ThumbnailCache.shared.cached(url ?? URL(fileURLWithPath: "/"))
                guard let url else { image = nil; return }
                image = await ThumbnailCache.shared.image(for: url,
                                                          maxPixel: Int(size.width * 3))
            }
    }
}

// MARK: - 提示条

/// 页面顶部的一行说明（缺坐标、被手动换过、谁在排程）。始终一行高，不撑版面。
struct PanelNotice: View {
    var symbol: String
    var text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09))
    }
}

// MARK: - 量内容高度

extension View {
    /// 把自己的高度报给外面。用来让列表按内容收——面板宽度是固定的，
    /// 但只有四个时段却撑出一屏空白并不好看。
    func measureHeight(into height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height.wrappedValue = $0 }
    }
}

// MARK: - 时刻格式

enum Clock {
    static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func string(_ date: Date?) -> String {
        date.map { hourMinute.string(from: $0) } ?? "—:—"
    }

    /// 「还有 2 小时 12 分」。倒计时只给到分钟，秒级精度在这里没有意义。
    static func remaining(until date: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSinceNow / 60).rounded()))
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return "\(rest) 分钟后" }
        return rest == 0 ? "\(hours) 小时后" : "\(hours) 小时 \(rest) 分后"
    }
}
