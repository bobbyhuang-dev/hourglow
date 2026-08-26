import AppKit
import SwiftUI

/// 装新手指引的那扇窗。
///
/// 全项目唯一一扇独立窗口 —— 理由写在 `OnboardingView` 的类型注释里（面板打不开的时候，
/// 指引必须还能出现）。其余界面一律留在菜单栏面板里，不要拿这个类开第二扇窗。
///
/// 三处细节：
///
/// - **临时变成前台应用**。`LSUIElement` 的进程默认是 `.accessory`，窗口能显示，
///   但抢焦点、`⌘Tab`、Dock 里都不见踪影，用户点到别处就再也找不回来。指引开着的时候
///   切成 `.regular`，关掉再切回去 —— 这一手在导入那条路上已经用过（`NSOpenPanel`）。
/// - **关窗就算看过**。跳过、走完、点红灯都一样：只要它出现过又被关掉，
///   下次启动就不该再自己弹出来。真想重看，⋯ 菜单里有入口。
/// - **普通标题栏**。试过 `.fullSizeContentView` 想把天光渐变铺到顶：这个 style mask
///   并不改变 `contentRect:` → 窗框的换算，内容照旧被压在标题栏下面，只是多出一条
///   与渐变对不上的空带（实测 566 的内容摆成 598 的窗）。既然铺不满，就老老实实
///   留一条系统标题栏，把标题写上 —— 这比一条来历不明的空白更像 macOS 的东西。
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    static let shared = OnboardingWindow()

    private var window: NSWindow?
    private var previousPolicy: NSApplication.ActivationPolicy?

    private override init() { super.init() }

    var isOpen: Bool { window != nil }

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingView(rootView: OnboardingView(finish: { [weak self] in
            self?.close()
        }).environment(AppModel.shared))
        host.frame = NSRect(x: 0, y: 0, width: Guide.width, height: Guide.height)

        // 没有 .resizable：版式固定，尺寸也就没有可调的余地。
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        window.title = "HourGlow 新手指引"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()   // 收尾统一在 windowWillClose 里做，点红灯走的也是那条路
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if let previousPolicy {
            NSApp.setActivationPolicy(previousPolicy)
        }
        previousPolicy = nil
        Onboarding.markSeen()
    }
}
