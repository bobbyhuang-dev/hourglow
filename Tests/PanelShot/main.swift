import AppKit
import SwiftUI

// 把三个页面画成 PNG。菜单栏面板不是普通窗口，screencapture 抓不到它，
// 改版式时用这个对照：
//
//   ./build/panelshot [输出目录]
//
// 走的是真窗口 + `cacheDisplay`，不是 `ImageRenderer` —— 后者画不出 ScrollView
// 里的内容，也画不出 AppKit 撑着的控件（分段控件、时间步进器、输入框、菜单）。
// 窗口以近乎全透明的方式短暂出现，画完就关掉。

@MainActor
func shoot<V: View>(_ view: V, named name: String, into directory: URL) {
    let content = view
        .environment(AppModel.shared)
        .frame(width: Panel.width)
        .background(Color(nsColor: .windowBackgroundColor))

    let host = NSHostingView(rootView: content)
    // 各页高度不同（时间轴按时段数收），照它自己的意愿摆。
    let fitted = host.fittingSize
    host.frame = NSRect(x: 0, y: 0, width: Panel.width,
                        height: max(fitted.height, 120))

    let window = NSWindow(contentRect: host.frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.contentView = host
    window.backgroundColor = .windowBackgroundColor
    window.alphaValue = 1
    window.orderFrontRegardless()

    defer { window.orderOut(nil) }

    // 抓两轮：第一轮等布局与缩略图的 `.task` 落地，第二轮才是要留下的那张。
    // 只抓一次的话，异步加载完的图层可能还没合成进来，抓到半张空白。
    var bitmap: NSBitmapImageRep?
    for wait in [1.2, 0.4] {
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        bitmap = rep
    }
    guard let bitmap else {
        print("取不到位图: \(name)"); return
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("编码失败: \(name)"); return
    }
    let url = directory.appendingPathComponent("\(name).png")
    try? png.write(to: url)
    print("已写出 \(url.path)")
}

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1] : ".")

// 顶层代码不是 main actor 隔离的，但它确确实实跑在主线程上。
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    let model = AppModel.shared
    guard let first = model.schedule.slots.first else {
        print("配置里没有时段，先跑一次 hourglow-cli list"); exit(1)
    }

    shoot(TimelinePage(open: { _ in }), named: "1-timeline", into: directory)
    shoot(SlotPage(slotID: first.id, open: { _ in }), named: "2-slot", into: directory)
    shoot(WallpaperPicker(slotID: first.id, open: { _ in }), named: "3-picker", into: directory)
}
