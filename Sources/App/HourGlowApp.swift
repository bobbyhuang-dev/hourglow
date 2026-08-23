import AppKit
import SwiftUI

/// 菜单栏 app 的入口。
///
/// `LSUIElement`（见打包脚本写的 Info.plist）让它没有 Dock 图标、没有主窗口，
/// 全部界面就是 `MenuBarExtra` 那一块 360 × 470 的面板。
@main
struct HourGlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelRoot()
                .environment(AppModel.shared)
        } label: {
            MenuBarIcon()
        }
        // .window 才是「一块自定义面板」；默认的 .menu 只能放菜单项。
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏上的那个图标。暂停时换成半满的沙漏，一眼能看出调度停了。
private struct MenuBarIcon: View {
    private let model = AppModel.shared

    var body: some View {
        Image(systemName: model.schedule.paused ? "hourglass.bottomhalf.filled" : "hourglass")
    }
}

/// 引擎要在面板第一次打开之前就跑起来 —— 菜单栏 app 的常态是从不打开面板。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}
