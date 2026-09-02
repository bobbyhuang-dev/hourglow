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
    /// 底部操作条（时间轴的三个操作、时段页的「应用」）的高度。
    static let footerHeight: CGFloat = 42
    static let corner: CGFloat = 7
    /// 时间轴上标「现在正在跑的是这一段」的那根竖条。
    /// 它是状态，不是选中 —— 所以只在行首立一根，绝不给整行铺强调色底。
    static let nowBar = CGSize(width: 3, height: 18)
    static let animation: Animation = .snappy(duration: 0.22)
}

/// 新手指引那扇窗的度量。和 `Panel` 分开，因为它不是同一块画布 ——
/// 菜单栏面板锁死 360 pt 是为了贴着状态项挂下来，而指引是一扇独立的窗，
/// 360 pt 宽讲不清一段话。度量仍旧集中在这里，视图里不散写数字。
enum Guide {
    static let width: CGFloat = 480
    /// 高度按内容最满的那一步定（第五步的清单 + 两条说明），不是随手取的整数。
    static let height: CGFloat = 566
    /// 顶部那条插图带。五步共用同一片天光渐变，只换上面的图。
    static let heroHeight: CGFloat = 140
    /// 底部：跳过 / 进度点 / 上一步 · 继续。
    static let footerHeight: CGFloat = 54
    static let inset: CGFloat = 24
    /// 正文区。固定这么高，翻页时标题不会上下跳；内容多了自己滚。
    /// 减 1 是那条分隔线。
    static var contentHeight: CGFloat { height - heroHeight - footerHeight - 1 }
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
///
/// 底色只表示「鼠标在这儿」和「正在按」这两件事，任何行都一样 —— 常驻的底色是列表
/// 「选中项」的语言，而这个面板里的行点下去是翻页，从来没有选中态。
struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: Panel.corner, style: .continuous))
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return .primary.opacity(0.12) }
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

// MARK: - 时刻输入

/// 「每天 09:00」里那个时刻输入框，只有小时和分钟。
///
/// 为什么不用 SwiftUI 的 `DatePicker(.stepperField)`：数字几乎贴着 AppKit 画的框线，
/// 而那点横向内边距从 SwiftUI 这一层够不到 —— 给它宽度它不撑（只把控件在盒子里居中），
/// 换 `controlSize` 只长高不长宽。所以这里自己包一层 `NSDatePicker`，关掉它自带的
/// 边框与底色，留白改由外面的 padding 决定；点小时/分钟分别改、上下键、步进器
/// 这些编辑行为仍旧是系统原生那一套。
///
/// 代价是没了系统的聚焦光晕；正在改哪一段仍然靠数字本身的高亮看得出来。
///
/// 底色与留白也一起包在这里，不留给调用方：上下两边**不等**，散在视图里只会被当成笔误。
struct TimeField: View {
    @Binding var date: Date

    var body: some View {
        Field(date: $date)
            .fixedSize()
            .padding(.horizontal, 8)
            // 上下差半点是补出来的，不是随手写的：`NSDatePicker` 的内容贴着自己盒子的
            // 底边画，下面固定留着字体的降部空间（12 pt 字体是 6.5 pt），上面把余下的
            // 高度全吃掉。而时刻只有数字和冒号，一个降部都用不上 —— 上下给一样的
            // padding，看上去就是「上 8.5 下 10」的偏上。补这半点之后数字与右边的
            // 步进器同时正好居中。字号跟着改成 12（与左边的「每天」一齐），
            // 13 pt 时这个差额是 1.5 pt，补平数字就会把步进器顶歪。
            .padding(.top, 3.5)
            .padding(.bottom, 3)
            .background(.quaternary.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct Field: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.font = .systemFont(ofSize: 12)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.change(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        // 正在输入时别把光标顶回开头。
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func change(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

// MARK: - 提示条

/// 页面顶部的一行说明（缺坐标、被手动换过、谁在排程）。始终一行高，不撑版面。
///
/// 给了 `action` 就变成可点的一条 —— 说的是「哪儿不对」，点进去就该是「在哪儿改」。
/// 末尾多一个尖括号，好让它看起来确实能点，不然一条提示条上的点击是猜出来的。
struct PanelNotice: View {
    var symbol: String
    var text: String
    var tint: Color = .secondary
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { bar }
                .buttonStyle(.plain)
        } else {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09))
        .contentShape(.rect)
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

// MARK: - 经纬度

/// 经纬度输入框。固定宽度，等宽数字 —— 两个框并排时数字不会因为位数不同而跳。
struct CoordinateField: View {
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 62)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        if hours == 0 { return L10n.t("clock.remaining.minutes", rest) }
        return rest == 0 ? L10n.t("clock.remaining.hours", hours)
                         : L10n.t("clock.remaining.hoursMinutes", hours, rest)
    }
}
