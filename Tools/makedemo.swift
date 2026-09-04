import AppKit
import ImageIO
import UniformTypeIdentifiers

// 画 README 顶上的演示 GIF，以及官网 / GitHub Social Preview 用的 1200 × 630 分享卡片。
// 两张图都是「一台 Mac 的一天」：Tahoe 壁纸随时刻换、菜单栏里的沙漏开着面板、
// 面板里的时间轴标着现在跑到哪一段。面板是 panelshot 抓的真图，不是画的。
//
// 平时不用直接调它，`Tools/makedemo.sh` 负责先出面板截图再调这里：
//
//   swiftc -O Tools/makedemo.swift -o build/makedemo
//   build/makedemo gif  --shots DIR --walls DIR --icon Resources/HourGlow.icns --day 2026-09-04 --out docs/demo.gif
//   build/makedemo card --shots DIR --walls DIR --icon Resources/HourGlow.icns --day 2026-09-04 --out og.png
//
// `--shots` 里是 `<phase>-<HHMM>.png`（morning-0620.png），`--walls` 里是 `tahoe-<phase>.jpg`；
// phase 固定是 morning / day / evening / night，与 Tahoe 四段预设一一对应。
//
// 为什么用 ImageIO 编 GIF 而不是 ffmpeg / gifsicle：仓库其余部分零依赖，这里也不想为一张图
// 引入一套工具链；ImageIO 会按帧生成调色板并抖动，实测天空的渐变没有明显色带。
// 为什么不是 ImageRenderer：与 panelshot 同一个理由 —— 这里干脆全部用 AppKit 离屏画。

// MARK: - 参数

enum Phase: String, CaseIterable {
    case morning, day, evening, night

    /// Tahoe 的 Evening / Night 是暗色壁纸，makedemo.sh 把这两段的面板按深色外观抓。
    /// 面板四周那一圈描边得跟着换：浅色面板靠一圈暗线与桌面分开，深色面板靠一圈亮线。
    var dark: Bool { self == .evening || self == .night }
}

struct Shot {
    let phase: Phase
    /// "0620" → 06:20。
    let clock: String
    let image: NSImage

    var minutes: Int { (Int(clock.prefix(2)) ?? 0) * 60 + (Int(clock.suffix(2)) ?? 0) }
    var label: String { "\(clock.prefix(2)):\(clock.suffix(2))" }
}

struct Options {
    var mode = "gif"
    var shots = ""
    var walls = ""
    var icon = ""
    var day = "2026-09-04"
    var out = ""
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    guard let mode = arguments.next(), mode == "gif" || mode == "card" else {
        print("用法: makedemo gif|card --shots DIR --walls DIR --icon FILE --day YYYY-MM-DD --out FILE")
        exit(2)
    }
    options.mode = mode
    while let argument = arguments.next() {
        guard let value = arguments.next() else { print("\(argument) 缺参数"); exit(2) }
        switch argument {
        case "--shots": options.shots = value
        case "--walls": options.walls = value
        case "--icon":  options.icon = value
        case "--day":   options.day = value
        case "--out":   options.out = value
        default: print("不认识的参数 \(argument)"); exit(2)
        }
    }
    guard !options.shots.isEmpty, !options.walls.isEmpty, !options.icon.isEmpty, !options.out.isEmpty else {
        print("--shots / --walls / --icon / --out 都要给"); exit(2)
    }
    return options
}

func loadShots(_ directory: String) -> [Phase: [Shot]] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    var result: [Phase: [Shot]] = [:]
    for name in names where name.hasSuffix(".png") {
        let stem = name.dropLast(4)
        let parts = stem.split(separator: "-")
        guard parts.count == 2, let phase = Phase(rawValue: String(parts[0])), parts[1].count == 4,
              let image = NSImage(contentsOfFile: (directory as NSString).appendingPathComponent(name))
        else { print("跳过认不出的文件 \(name)"); continue }
        result[phase, default: []].append(Shot(phase: phase, clock: String(parts[1]), image: image))
    }
    for phase in Phase.allCases {
        guard let shots = result[phase], !shots.isEmpty else {
            print("\(directory) 里没有 \(phase.rawValue)-HHMM.png"); exit(1)
        }
        result[phase] = shots.sorted { $0.minutes < $1.minutes }
    }
    return result
}

func loadWalls(_ directory: String) -> [Phase: NSImage] {
    var result: [Phase: NSImage] = [:]
    for phase in Phase.allCases {
        let path = (directory as NSString).appendingPathComponent("tahoe-\(phase.rawValue).jpg")
        guard let image = NSImage(contentsOfFile: path) else { print("缺壁纸 \(path)"); exit(1) }
        result[phase] = image
    }
    return result
}

func dateLabel(_ day: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: day) else { print("--day 格式是 2026-09-04"); exit(2) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM"
    return formatter.string(from: date)
}

// MARK: - 画布

/// 顶左原点的离屏画布。`NSGraphicsContext(cgContext:flipped:)` 让 NSImage 与文字都按翻转坐标画，
/// 不用自己给每一段文字倒过来。
func render(width: Int, height: Int, _ body: (CGContext, CGRect) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    cg.interpolationQuality = .high
    let context = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    body(cg, CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return cg.makeImage()!
}

/// 等比铺满（多出来的裁掉），alpha 用来做两张壁纸的交叉淡入。
func drawFill(_ image: NSImage, in rect: CGRect, alpha: CGFloat = 1) {
    let size = image.size
    let scale = max(rect.width / size.width, rect.height / size.height)
    let drawn = CGSize(width: size.width * scale, height: size.height * scale)
    let origin = CGPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
    image.draw(in: CGRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver,
               fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSImage? {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return base?.withSymbolConfiguration(configuration)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          shadow: Bool = false, monospacedDigits: Bool = false) -> NSAttributedString {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if monospacedDigits { font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 2
        s.shadowOffset = NSSize(width: 0, height: -1)
        attributes[.shadow] = s
    }
    return NSAttributedString(string: string, attributes: attributes)
}

/// 画一行菜单栏项，返回它占掉的宽度。图标与文字都垂直居中在 `bar` 里。
@discardableResult
func drawCentered(_ item: NSAttributedString, x: CGFloat, bar: CGRect) -> CGFloat {
    let size = item.size()
    item.draw(at: CGPoint(x: x, y: bar.midY - size.height / 2))
    return size.width
}

@discardableResult
func drawCentered(_ image: NSImage, x: CGFloat, bar: CGRect) -> CGFloat {
    let size = image.size
    image.draw(in: CGRect(x: x, y: bar.midY - size.height / 2, width: size.width, height: size.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    return size.width
}

// MARK: - 一帧「桌面」

struct Desk {
    /// 画布 1000 × 625：README 里按内容宽度缩到八百多像素，面板上的字还认得出来。
    static let size = CGSize(width: 1000, height: 625)
    /// 菜单栏比真机的比例略高（真机 24 pt 摆在 1500 多 pt 宽的屏上）：这是示意图，
    /// 面板与它上面的沙漏才是要讲的事，得看得清。
    static let barHeight: CGFloat = 30
    static let panelWidth: CGFloat = 380
    static let panelCorner: CGFloat = 12

    let walls: [Phase: NSImage]
    let dateLabel: String

    /// - from/to: 交叉淡入的两张壁纸，`progress` 0 是 from、1 是 to。
    /// - shot: 面板里放哪张截图。
    /// - clock: 菜单栏右上角的时刻。
    func frame(from: Phase, to: Phase, progress: CGFloat, shot: Shot, clock: String) -> CGImage {
        render(width: Int(Desk.size.width), height: Int(Desk.size.height)) { cg, bounds in
            drawFill(walls[from]!, in: bounds)
            if progress > 0 { drawFill(walls[to]!, in: bounds, alpha: progress) }

            // 菜单栏：半透明深色一条，白字。真机是毛玻璃，这里用透明度近似。
            let bar = CGRect(x: 0, y: 0, width: bounds.width, height: Desk.barHeight)
            cg.setFillColor(NSColor(white: 0.06, alpha: 0.32).cgColor)
            cg.fill(bar)

            var x: CGFloat = 16
            if let apple = symbol("apple.logo", size: 13, weight: .medium) {
                x += drawCentered(apple, x: x, bar: bar) + 16
            }
            x += drawCentered(text("Finder", size: 13, weight: .bold, color: .white, shadow: true), x: x, bar: bar) + 18
            for menu in ["File", "Edit", "View", "Go", "Window", "Help"] {
                x += drawCentered(text(menu, size: 13, weight: .medium, color: .white, shadow: true), x: x, bar: bar) + 16
            }

            // 右侧从右往左摆：时刻、日期、电池、Wi-Fi、然后是沙漏。
            let clockText = text(clock, size: 13, weight: .medium, color: .white, shadow: true, monospacedDigits: true)
            var right = bounds.width - 14 - clockText.size().width
            drawCentered(clockText, x: right, bar: bar)
            let dateText = text(dateLabel, size: 13, weight: .medium, color: .white, shadow: true)
            right -= 8 + dateText.size().width
            drawCentered(dateText, x: right, bar: bar)
            for name in ["battery.100percent", "wifi"] {
                if let icon = symbol(name, size: 13, weight: .medium) {
                    right -= 14 + icon.size.width
                    drawCentered(icon, x: right, bar: bar)
                }
            }
            // 沙漏：面板开着，所以它带着「按下」的底色。
            let hourglass = symbol("hourglass", size: 14, weight: .medium)!
            right -= 16 + hourglass.size.width
            let pressed = CGRect(x: right - 6, y: bar.minY + 3, width: hourglass.size.width + 12, height: bar.height - 6)
            cg.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
            cg.addPath(CGPath(roundedRect: pressed, cornerWidth: 5, cornerHeight: 5, transform: nil))
            cg.fillPath()
            drawCentered(hourglass, x: right, bar: bar)

            // 面板：挂在沙漏下面，贴着右边留 8 pt，跟 MenuBarExtra 被屏幕边缘顶回来的位置一样。
            let panelSize = CGSize(width: Desk.panelWidth,
                                   height: Desk.panelWidth * shot.image.size.height / shot.image.size.width)
            let panel = CGRect(x: bounds.width - 8 - panelSize.width, y: bar.maxY + 6,
                               width: panelSize.width, height: panelSize.height)
            let path = CGPath(roundedRect: panel, cornerWidth: Desk.panelCorner, cornerHeight: Desk.panelCorner, transform: nil)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            cg.setFillColor(NSColor.white.cgColor)
            cg.addPath(path)
            cg.fillPath()
            cg.restoreGState()
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            shot.image.draw(in: panel, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high])
            cg.restoreGState()
            cg.setStrokeColor(NSColor(white: shot.phase.dark ? 1 : 0, alpha: 0.18).cgColor)
            cg.setLineWidth(1)
            cg.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Desk.panelCorner,
                              cornerHeight: Desk.panelCorner, transform: nil))
            cg.strokePath()
        }
    }
}

// MARK: - GIF

/// 每一段先停几帧（时刻在走、面板在数倒计时），再用几帧把壁纸淡到下一段；
/// 最后一段淡回第一段，循环接得上。停帧长、过渡帧短，总长十秒出头。
func writeGIF(desk: Desk, shots: [Phase: [Shot]], to url: URL) {
    let hold: Double = 0.75
    let fadeFrames = 5
    let fadeDelay: Double = 0.07

    var frames: [(CGImage, Double)] = []
    let phases = Phase.allCases
    for (index, phase) in phases.enumerated() {
        let next = phases[(index + 1) % phases.count]
        for shot in shots[phase]! {
            frames.append((desk.frame(from: phase, to: next, progress: 0, shot: shot, clock: shot.label), hold))
        }
        let last = shots[phase]!.last!
        let first = shots[next]!.first!
        for step in 1...fadeFrames {
            let progress = CGFloat(step) / CGFloat(fadeFrames + 1)
            // 面板与时钟在过渡过半时一起跳到下一段：壁纸是渐变的，切换本身不是。
            let shot = progress < 0.5 ? last : first
            frames.append((desk.frame(from: phase, to: next, progress: progress, shot: shot, clock: shot.label), fadeDelay))
        }
    }

    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
        print("建不了 \(url.path)"); exit(1)
    }
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    for (image, delay) in frames {
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { print("写不出 \(url.path)"); exit(1) }
    let total = frames.reduce(0) { $0 + $1.1 }
    print("已写出 \(url.path)：\(frames.count) 帧，约 \(String(format: "%.1f", total)) 秒")
}

// MARK: - 分享卡片

/// 1200 × 630：GitHub Social Preview、og:image、Twitter summary_large_image 都是这个比例。
/// 左边是名字与一句话，右边是傍晚那一刻的面板；底图是 Tahoe Evening，压一层左深右浅的渐变让字站得住。
func writeCard(desk: Desk, icon: NSImage, shots: [Phase: [Shot]], to url: URL) {
    let width = 1200, height = 630
    let shot = shots[.evening]!.first!
    let image = render(width: width, height: height) { cg, bounds in
        drawFill(desk.walls[.evening]!, in: bounds)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [NSColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 0.90).cgColor,
                      NSColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 0.55).cgColor,
                      NSColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 0.15).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: bounds.width, y: 0), options: [])

        // 左栏
        let inset: CGFloat = 76
        icon.draw(in: CGRect(x: inset - 6, y: 70, width: 112, height: 112), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        text("HourGlow", size: 78, weight: .bold, color: .white).draw(at: CGPoint(x: inset - 4, y: 196))
        let tagline = text("Your wallpaper,\non the sun's schedule.", size: 36, weight: .medium,
                           color: NSColor(white: 1, alpha: 0.94))
        tagline.draw(in: CGRect(x: inset, y: 306, width: 560, height: 110))
        text("Free · Open source · macOS 26 · Lives in the menu bar", size: 21, weight: .regular,
             color: NSColor(white: 1, alpha: 0.78)).draw(at: CGPoint(x: inset, y: 440))
        text("hourglow.bobbyhuang.dev", size: 19, weight: .medium,
             color: NSColor(white: 1, alpha: 0.7)).draw(at: CGPoint(x: inset, y: 546))

        // 右栏：面板
        let panelWidth: CGFloat = 400
        let panelSize = CGSize(width: panelWidth, height: panelWidth * shot.image.size.height / shot.image.size.width)
        let panel = CGRect(x: bounds.width - 72 - panelSize.width, y: (bounds.height - panelSize.height) / 2,
                           width: panelSize.width, height: panelSize.height)
        let path = CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        cg.setFillColor(NSColor.white.cgColor)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        shot.image.draw(in: panel, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high])
        cg.restoreGState()
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("建不了 \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { print("写不出 \(url.path)"); exit(1) }
    print("已写出 \(url.path)：\(width) × \(height)")
}

// MARK: - 入口

let options = parse()
let shots = loadShots(options.shots)
let walls = loadWalls(options.walls)
guard let icon = NSImage(contentsOfFile: options.icon) else { print("读不了图标 \(options.icon)"); exit(1) }
let desk = Desk(walls: walls, dateLabel: dateLabel(options.day))
let output = URL(fileURLWithPath: options.out)
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
switch options.mode {
case "gif":  writeGIF(desk: desk, shots: shots, to: output)
default:     writeCard(desk: desk, icon: icon, shots: shots, to: output)
}
