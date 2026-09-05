import AppKit

// Generate Resources/HourGlow.icns. The output is checked in; build.sh only copies it into the bundle.
// Run this tool only when changing the icon:
//
//   swiftc -O Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon Resources
//
// The hourglass uses the same SF Symbol as the menu bar, over a vertical gradient from morning to night,
// reflecting the app's purpose. Corners and padding follow the macOS icon grid: content occupies 82% of
// the canvas, with a corner radius of 0.2237 times its side (visually approximating Apple's continuous corners at this size).

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let sizes = [16, 32, 64, 128, 256, 512, 1024]   // These seven sizes supply the ten images required by an iconset.

// A direct morning-to-night gradient turns muddy brown in the middle, unlike a real twilight sky.
// Add a pinkish Belt of Venus stop so the three-color gradient resembles the changing daylight.
let morning = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.40, alpha: 1)
let dusk    = NSColor(srgbRed: 0.79, green: 0.48, blue: 0.55, alpha: 1)
let night   = NSColor(srgbRed: 0.16, green: 0.21, blue: 0.47, alpha: 1)

func render(_ size: Int) -> NSBitmapImageRep {
    let side = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = side * 0.09
    let box = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = box.width * 0.2237
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    NSGradient(colors: [morning, dusk, night],
               atLocations: [0, 0.42, 1], colorSpace: .sRGB)?.draw(in: squircle, angle: -90)

    // Hourglass: scale relative to the content box, larger in small icons so it does not collapse to a line at 16 pt.
    let scale: CGFloat = size <= 32 ? 0.60 : 0.52
    let config = NSImage.SymbolConfiguration(pointSize: box.width * scale, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            NSColor.white.set()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let frame = NSRect(x: box.midX - tinted.size.width / 2,
                           y: box.midY - tinted.size.height / 2,
                           width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: frame)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("HourGlow.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var pngs: [Int: Data] = [:]
for size in sizes {
    pngs[size] = render(size).representation(using: .png, properties: [:])!
}

// iconset naming: the @2x image is the same artwork at twice the dimensions.
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                       (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(point)x\(point)\(suffix).png"
    try! pngs[point * scale]!.write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path,
                  "-o", output.appendingPathComponent("HourGlow.icns").path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.appendingPathComponent("HourGlow.icns").path)")
