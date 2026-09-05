import AppKit
import SwiftUI

// Fixed panel dimensions and shared components. Every page uses the same metrics to avoid resizing on navigation.

enum Panel {
    static let width: CGFloat = 360
    /// Fixed picker height to fit the grid; timeline and slot pages fit their content up to this limit.
    static let height: CGFloat = 470
    /// Maximum timeline list height, roughly 7 rows; additional rows scroll.
    static let listMaxHeight: CGFloat = 300
    /// Horizontal padding. Rounded row backgrounds extend farther out, so rows use `rowInset`.
    static let inset: CGFloat = 12
    static let rowInset: CGFloat = 8
    static let rowHeight: CGFloat = 44
    /// Height of the bottom action bar: timeline actions or the slot editor's Apply button.
    static let footerHeight: CGFloat = 42
    static let corner: CGFloat = 7
    /// Section-card and Delete-row corners are slightly rounder than list rows.
    static let cardCorner: CGFloat = 8
    /// The timeline's vertical marker for the currently active slot.
    /// It indicates status, not selection: use a leading bar, never a full-row accent background.
    static let nowBar = CGSize(width: 3, height: 18)
    static let animation: Animation = .snappy(duration: 0.22)

    /// Today's daylight bar beneath the status area: a 24-hour strip plus tick labels.
    static let dayBarHeight: CGFloat = 14
    static let dayBarCorner: CGFloat = 4
    /// Slot marker: a short round-ended vertical line; the "now" cursor is thinner and taller.
    static let dayBarMarker = CGSize(width: 2, height: 8)
    static let dayBarLabelHeight: CGFloat = 13

    /// Shared font sizes keep equivalent text consistent across pages; avoid scattered view-local sizes.
    enum Font {
        /// Wallpaper name in status and current place name on the location page.
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Primary list-row text and toggle titles.
        static let body = SwiftUI.Font.system(size: 12.5)
        /// Form labels beside controls, such as "Every day" and setting titles.
        static let control = SwiftUI.Font.system(size: 12)
        /// Subtitles, footnotes, and notices.
        static let secondary = SwiftUI.Font.system(size: 11)
        /// Inline trigger descriptions, grid names, and disabled labels.
        static let caption = SwiftUI.Font.system(size: 10.5)
        /// Section headings and location-page group headings.
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
    }

    /// Section cards, fields, and thumbnail borders adapt to appearance.
    /// Hardcoded `black.opacity(0.12)` borders vanished in dark mode, while `quaternary` card fills
    /// nearly matched the window background, making card boundaries impossible to distinguish.
    static let cardFill = adaptive(light: NSColor.black.withAlphaComponent(0.05),
                                   dark: NSColor.white.withAlphaComponent(0.07))
    static let fieldFill = adaptive(light: NSColor.black.withAlphaComponent(0.07),
                                    dark: NSColor.white.withAlphaComponent(0.10))
    static let hairline = adaptive(light: NSColor.black.withAlphaComponent(0.12),
                                   dark: NSColor.white.withAlphaComponent(0.10))

    /// Resolve dynamic colors against the view's actual appearance without passing `colorScheme` everywhere.
    /// This also supports `panelshot --appearance`, which changes only the window's `appearance`.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Shared sky palette for the app icon, onboarding header, and timeline daylight bar,
/// making all three feel like the same product.
enum Sky {
    static let night = Color(red: 0.13, green: 0.16, blue: 0.32)
    /// The violet blue of civil dusk.
    static let dusk = Color(red: 0.33, green: 0.30, blue: 0.47)
    /// Warm orange around sunrise and sunset.
    static let glow = Color(red: 0.78, green: 0.47, blue: 0.33)
    /// Daytime sky blue. Unused in the guide's night-to-dawn gradient, but fills much of the daylight bar.
    static let day = Color(red: 0.55, green: 0.74, blue: 0.92)
}

/// Onboarding window metrics, separate from `Panel` because this is a different canvas.
/// The menu bar panel is locked to 360 pt to hang beneath its status item; the standalone guide
/// needs more width for prose. Keep metrics centralized rather than scattering numbers through views.
enum Guide {
    static let width: CGFloat = 480
    /// Sized for the fullest step (step five's checklist and two notes), not an arbitrary round number.
    static let height: CGFloat = 566
    /// Header illustration strip. All five steps share the sky gradient and change only the illustration.
    static let heroHeight: CGFloat = 140
    /// Footer: Skip / progress dots / Back · Continue.
    static let footerHeight: CGFloat = 54
    static let inset: CGFloat = 24
    /// Fixed body height prevents title jumps during navigation; overflowing content scrolls.
    /// Subtract 1 for the divider.
    static var contentHeight: CGFloat { height - heroHeight - footerHeight - 1 }
}

// MARK: - Page header

/// Shared header: back on the left, centered title, accessory on the right. Keeps titles aligned across all three pages.
struct PanelHeader<Trailing: View>: View {
    var title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(Panel.Font.headline)

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

// MARK: - Sections

/// System Settings-style group: a small heading above a lightly filled rounded card.
struct PanelSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Panel.Font.section)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Panel.cardFill,
                        in: RoundedRectangle(cornerRadius: Panel.cardCorner, style: .continuous))
        }
    }
}

// MARK: - Scrolling

/// Locks the enclosing SwiftUI `ScrollView` to vertical scrolling only.
///
/// On macOS a vertical `ScrollView` is backed by an `NSScrollView` whose horizontal elasticity
/// defaults to `.automatic`: a sideways trackpad swipe drags the whole list out and snaps it
/// back. The panel width is fixed, so there is never anything to scroll horizontally.
/// `.scrollBounceBehavior(.basedOnSize, axes: .horizontal)` still leaves AppKit at `.automatic`
/// and does not stop it; the only reliable fix is to find that `NSScrollView` and turn
/// horizontal elasticity off. Place it inside the `ScrollView` content
/// (`.background(VerticalOnlyScroll())`), not on the `ScrollView` itself.
struct VerticalOnlyScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        private weak var scrollView: NSScrollView?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// SwiftUI can reconfigure the native scroll view after mounting or updating its
        /// content. Keep the axis locked for its lifetime, including rebuilt panel pages.
        func apply() {
            guard window != nil, let enclosing = enclosingScrollView else { stop(); return }
            if scrollView !== enclosing {
                stop()
                scrollView = enclosing
                observations = [
                    enclosing.observe(\.horizontalScrollElasticity) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.lockAxis() }
                    },
                    enclosing.observe(\.hasHorizontalScroller) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.lockAxis() }
                    }
                ]
            }
            lockAxis()
        }

        private func lockAxis() {
            guard let scrollView else { return }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
            if scrollView.hasHorizontalScroller {
                scrollView.hasHorizontalScroller = false
            }
        }

        func stop() {
            observations.removeAll()
            scrollView = nil
        }
    }
}

// MARK: - Rows

/// Native-feeling panel row button style: a light hover fill, darkened while pressed.
///
/// Fill indicates hover or pressing for every row. A persistent fill implies list selection,
/// but panel rows navigate to another page and never have a selected state.
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

// MARK: - Thumbnails

/// Decode thumbnails off the main thread and cache by URL.
/// Synchronously decoding 156 aerial thumbnails of roughly 50 KB each causes visible scrolling stutter.
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

    /// Ask ImageIO for a thumbnail directly: a local HEIC may be tens of MB,
    /// and decoding the whole image just to draw a 100 pt cell wastes memory.
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

/// A wallpaper thumbnail cell, falling back to a placeholder when unreadable (undownloaded local image or missing file).
struct Thumbnail: View {
    var url: URL?
    var size: CGSize
    var corner: CGFloat = 5

    @State private var image: NSImage?

    init(url: URL?, size: CGSize, corner: CGFloat = 5) {
        self.url = url
        self.size = size
        self.corner = corner
        // Use cached images immediately so returning to a page or scrolling back does not flash a placeholder.
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
                    .strokeBorder(Panel.hairline, lineWidth: 0.5)
            }
            .task(id: url) {
                image = ThumbnailCache.shared.cached(url ?? URL(fileURLWithPath: "/"))
                guard let url else { image = nil; return }
                image = await ThumbnailCache.shared.image(for: url,
                                                          maxPixel: Int(size.width * 3))
            }
    }
}

// MARK: - Time input

/// The hours-and-minutes field in "Every day 09:00".
///
/// SwiftUI's `DatePicker(.stepperField)` places digits too close to the AppKit border, and SwiftUI
/// cannot adjust that horizontal inset: assigning width only centers the control in a larger box,
/// while `controlSize` changes height, not width. Wrap `NSDatePicker` instead, removing its border
/// and background so outer padding controls spacing. Editing individual hour/minute segments,
/// arrow keys, and the stepper all retain native behavior.
///
/// This loses the system focus ring, but digit highlighting still identifies the segment being edited.
///
/// Own background and padding here: top and bottom are deliberately **unequal**, not a caller's typo.
struct TimeField: View {
    @Binding var date: Date

    var body: some View {
        Field(date: $date)
            .fixedSize()
            .padding(.horizontal, 8)
            // The half-point vertical adjustment is deliberate. `NSDatePicker` draws against its bottom
            // edge, reserving font descender space below (6.5 pt for a 12 pt font) and consuming the rest
            // above. Times contain only digits and colons, so they need none of that descender space.
            // Equal padding looks top-heavy ("8.5 above, 10 below"). This half-point correction centers
            // both digits and the right-hand stepper. Use 12 pt to match "Every day" on the left:
            // at 13 pt, the 1.5 pt discrepancy would misalign the stepper if corrected for the digits.
            .padding(.top, 3.5)
            .padding(.bottom, 3)
            .background(Panel.fieldFill,
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
        // Do not reset the insertion point to the beginning while the user types.
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

// MARK: - Notices

/// A one-line page-top explanation (missing coordinates, manual override, scheduler ownership) that does not expand the layout.
///
/// Providing `action` makes the notice clickable: explaining what is wrong should link to where it can be fixed.
/// A trailing chevron makes the interaction discoverable rather than something users must guess.
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
                .font(Panel.Font.secondary)
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

// MARK: - Content height measurement

extension View {
    /// Report this view's height so lists can shrink to fit. Panel width is fixed,
    /// but four slots should not leave a screenful of empty space.
    func measureHeight(into height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height.wrappedValue = $0 }
    }
}

// MARK: - Coordinates

/// Coordinate field with fixed width and monospaced digits, keeping side-by-side values stable across digit counts.
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
            .background(Panel.fieldFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Time formatting

enum Clock {
    static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func string(_ date: Date?) -> String {
        date.map { hourMinute.string(from: $0) } ?? "—:—"
    }

    /// "2 hours 12 minutes remaining." Minute precision is enough; seconds add no useful information here.
    static func remaining(until date: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(AppModel.now()) / 60).rounded()))
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return L10n.t("clock.remaining.minutes", rest) }
        return rest == 0 ? L10n.t("clock.remaining.hours", hours)
                         : L10n.t("clock.remaining.hoursMinutes", hours, rest)
    }
}
