import AppKit

// 生成 `Resources/HourGlow.icns`。产物已经提交进仓库，`build.sh` 只负责拷进 bundle ——
// 这个工具平时不跑，改图标时才跑一次：
//
//   swiftc -O Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon Resources
//
// 沙漏用 SF Symbol，和菜单栏上那个是同一个字形；底是一条从晨光到夜色的竖向渐变，
// 正是这个 app 干的事。圆角与留白照 macOS 的图标网格：内容占画布的 82%，圆角半径
// 是内容边长的 0.2237（Apple 那个「连续圆角」的近似值，这个尺寸下看不出差别）。

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let sizes = [16, 32, 64, 128, 256, 512, 1024]   // iconset 要的 10 张由这 7 个尺寸拼出来

// 直接从晨光渐到夜色，中段会糊成一片土褐 —— 真实的暮色天空也不是那样过渡的，
// 中间插一档偏粉的「维纳斯带」，三档下来才像一次天光变化。
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

    // 沙漏。留白按内容框算，图标越小符号相对越大，不然 16 pt 下只剩一根线。
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

// iconset 的命名规则：@2x 那张就是两倍尺寸的同一张图。
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
    FileHandle.standardError.write(Data("iconutil 失败\n".utf8))
    exit(1)
}
print("已写出 \(output.appendingPathComponent("HourGlow.icns").path)")
