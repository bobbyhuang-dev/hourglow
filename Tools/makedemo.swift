import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draw the README demo GIF and a 1200 × 630 sharing card for the website and GitHub Social Preview.
// Both show a day on a Mac: Tahoe wallpaper changes with the time, the menu bar hourglass has its panel open,
// and the panel timeline shows the current phase. Panels are real panelshot captures, not illustrations.
//
// Normally invoked by Tools/makedemo.sh, which captures the panels first:
//
//   swiftc -O Tools/makedemo.swift -o build/makedemo
//   build/makedemo gif  --shots DIR --walls DIR --icon Resources/HourGlow.icns --day 2026-09-04 --out docs/demo.gif
//   build/makedemo card --shots DIR --walls DIR --icon Resources/HourGlow.icns --day 2026-09-04 --out og.png
//
// --shots contains <phase>-<HHMM>.png (morning-0620.png); --walls contains tahoe-<phase>.jpg.
// Phases are morning / day / evening / night, matching the four-phase Tahoe preset.
//
// Why ImageIO rather than ffmpeg / gifsicle: the rest of the repo has no dependencies, and one image
// does not warrant another toolchain. ImageIO generates per-frame palettes with dithering; sky gradients show no obvious banding.
// Why not ImageRenderer: for the same reason as panelshot, everything here is drawn offscreen with AppKit.

// MARK: - Arguments

enum Phase: String, CaseIterable {
    case morning, day, evening, night

    /// Tahoe Evening / Night wallpapers are dark, so makedemo.sh captures those panels in dark appearance.
    /// The border follows suit: a dark outline separates light panels from the desktop, and a light outline separates dark panels.
    var dark: Bool { self == .evening || self == .night }
}

struct Shot {
    let phase: Phase
    /// "0620" → 06:20.
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
        print("Usage: makedemo gif|card --shots DIR --walls DIR --icon FILE --day YYYY-MM-DD --out FILE")
        exit(2)
    }
    options.mode = mode
    while let argument = arguments.next() {
        guard let value = arguments.next() else { print("Missing value for \(argument)"); exit(2) }
        switch argument {
        case "--shots": options.shots = value
        case "--walls": options.walls = value
        case "--icon":  options.icon = value
        case "--day":   options.day = value
        case "--out":   options.out = value
        default: print("Unknown argument \(argument)"); exit(2)
        }
    }
    guard !options.shots.isEmpty, !options.walls.isEmpty, !options.icon.isEmpty, !options.out.isEmpty else {
        print("--shots / --walls / --icon / --out are all required"); exit(2)
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
        else { print("Skipping unrecognized file \(name)"); continue }
        result[phase, default: []].append(Shot(phase: phase, clock: String(parts[1]), image: image))
    }
    for phase in Phase.allCases {
        guard let shots = result[phase], !shots.isEmpty else {
            print("No \(phase.rawValue)-HHMM.png files in \(directory)"); exit(1)
        }
        result[phase] = shots.sorted { $0.minutes < $1.minutes }
    }
    return result
}

func loadWalls(_ directory: String) -> [Phase: NSImage] {
    var result: [Phase: NSImage] = [:]
    for phase in Phase.allCases {
        let path = (directory as NSString).appendingPathComponent("tahoe-\(phase.rawValue).jpg")
        guard let image = NSImage(contentsOfFile: path) else { print("Missing wallpaper \(path)"); exit(1) }
        result[phase] = image
    }
    return result
}

func dateLabel(_ day: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: day) else { print("--day must use YYYY-MM-DD format, e.g. 2026-09-04"); exit(2) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM"
    return formatter.string(from: date)
}

// MARK: - Canvas

/// Offscreen canvas with a top-left origin. NSGraphicsContext(cgContext:flipped:) draws NSImage and text
/// in flipped coordinates, avoiding manual transforms for each text run.
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

/// Fill while preserving aspect ratio, cropping overflow; alpha crossfades between wallpapers.
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

/// Draw a menu bar item and return its width. Both icons and text are vertically centered in bar.
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

// MARK: - Desktop frame

struct Desk {
    /// A 1000 × 625 canvas keeps panel text readable when scaled to the README's roughly 800-pixel content width.
    static let size = CGSize(width: 1000, height: 625)
    /// Slightly taller menu bar proportions than a real Mac (24 pt on a screen over 1500 pt wide):
    /// this is an illustration, and the panel and hourglass above it must remain clear.
    static let barHeight: CGFloat = 30
    static let panelWidth: CGFloat = 380
    static let panelCorner: CGFloat = 12

    let walls: [Phase: NSImage]
    let dateLabel: String

    /// - from/to: Wallpapers to crossfade; progress 0 is from, 1 is to.
    /// - shot: Screenshot to display in the panel.
    /// - clock: Time at the top right of the menu bar.
    func frame(from: Phase, to: Phase, progress: CGFloat, shot: Shot, clock: String) -> CGImage {
        render(width: Int(Desk.size.width), height: Int(Desk.size.height)) { cg, bounds in
            drawFill(walls[from]!, in: bounds)
            if progress > 0 { drawFill(walls[to]!, in: bounds, alpha: progress) }

            // Menu bar: translucent dark strip with white text, approximating the real frosted glass with opacity.
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

            // Lay out the right side from right to left: time, date, battery, Wi-Fi, then hourglass.
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
            // Hourglass: show a pressed background because the panel is open.
            let hourglass = symbol("hourglass", size: 14, weight: .medium)!
            right -= 16 + hourglass.size.width
            let pressed = CGRect(x: right - 6, y: bar.minY + 3, width: hourglass.size.width + 12, height: bar.height - 6)
            cg.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
            cg.addPath(CGPath(roundedRect: pressed, cornerWidth: 5, cornerHeight: 5, transform: nil))
            cg.fillPath()
            drawCentered(hourglass, x: right, bar: bar)

            // Panel: below the hourglass, 8 pt from the right edge, matching MenuBarExtra's screen-edge adjustment.
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

/// Hold each phase for a few frames while the clock and countdown advance, then crossfade to the next wallpaper.
/// The last phase fades back to the first for a seamless loop. Long holds and short transitions total just over ten seconds.
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
            // Switch the panel and clock together halfway through: the wallpaper fades, but the phase change is discrete.
            let shot = progress < 0.5 ? last : first
            frames.append((desk.frame(from: phase, to: next, progress: progress, shot: shot, clock: shot.label), fadeDelay))
        }
    }

    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
        print("Cannot create \(url.path)"); exit(1)
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
    guard CGImageDestinationFinalize(destination) else { print("Cannot write \(url.path)"); exit(1) }
    let total = frames.reduce(0) { $0 + $1.1 }
    print("Wrote \(url.path): \(frames.count) frames, approximately \(String(format: "%.1f", total)) seconds")
}

// MARK: - Sharing card

/// 1200 × 630: the aspect ratio used by GitHub Social Preview, og:image, and Twitter summary_large_image.
/// Name and tagline on the left, evening panel on the right; a dark-to-light overlay on Tahoe Evening keeps text legible.
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

        // Left column
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

        // Right column: panel
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
        print("Cannot create \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { print("Cannot write \(url.path)"); exit(1) }
    print("Wrote \(url.path): \(width) × \(height)")
}

// MARK: - Entry point

let options = parse()
let shots = loadShots(options.shots)
let walls = loadWalls(options.walls)
guard let icon = NSImage(contentsOfFile: options.icon) else { print("Cannot read icon \(options.icon)"); exit(1) }
let desk = Desk(walls: walls, dateLabel: dateLabel(options.day))
let output = URL(fileURLWithPath: options.out)
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
switch options.mode {
case "gif":  writeGIF(desk: desk, shots: shots, to: output)
default:     writeCard(desk: desk, icon: icon, shots: shots, to: output)
}
