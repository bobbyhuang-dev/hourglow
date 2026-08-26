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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 这一句要抢在任何人碰 `Store.load()` 之前（`AppModel.init` 里也有一句兜底，
        // 谁先跑到都对）：配置文件在不在，是「这次是不是全新安装」的唯一依据。
        Onboarding.captureFirstRun(
            configExists: FileManager.default.fileExists(atPath: Store.fileURL.path))
        LoginItemProbe.handleIfNeeded()
        GuideProbe.handleIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 定位那条要等系统回调，得让主 run loop 转起来，所以不能在 willFinish 里做。
        LocateProbe.handleIfNeeded()
        AppModel.shared.start()
        // 引擎先跑起来，指引再出现：全新安装的第一分钟里壁纸就该已经对了，
        // 指引解释的是「刚才发生了什么、以后在哪儿改」。
        if Onboarding.shouldPresentOnLaunch {
            OnboardingWindow.shared.present()
        }
    }
}

/// 开机自启的排障入口：
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --login-item [status|on|off]
/// ```
///
/// 它没有长在 `hourglow-cli` 上，是因为 `SMAppService.mainApp` 注册的是**调用者自己的
/// bundle** —— CLI 是个裸二进制，没有 bundle 可注册，从那边问到的永远是 `.notFound`。
/// 打印完直接退出，菜单栏上不会留下图标。
enum LoginItemProbe {
    static func handleIfNeeded() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--login-item") else { return }
        let action = index + 1 < arguments.count ? arguments[index + 1] : "status"

        switch action {
        case "on", "off":
            do {
                try LaunchAtLogin.set(action == "on")
            } catch {
                print("失败: \((error as NSError).localizedDescription)")
                exit(1)
            }
        case "status":
            break
        default:
            print("用法: --login-item [status|on|off]")
            exit(2)
        }
        print("开机自启  \(LaunchAtLogin.describe())")
        print("bundle   \(Bundle.main.bundleURL.path)")
        exit(0)
    }
}

/// 定位的排障入口：
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --locate
/// ```
///
/// 和开机自启同理，权限是按 bundle 授予的，`hourglow-cli` 那个裸二进制问不出结果。
/// 第一次跑会弹系统的定位授权对话框（理由取自 Info.plist 里的
/// `NSLocationWhenInUseUsageDescription`）。拿到结果只打印，不写进配置 ——
/// 写配置是设置页里那个按钮的事，排障不该顺手改用户的东西。
enum LocateProbe {
    @MainActor
    static func handleIfNeeded() {
        guard CommandLine.arguments.contains("--locate") else { return }

        var done = false
        PreciseLocation.shared.request { outcome in
            switch outcome {
            case .coordinate(let c):
                print(String(format: "坐标  %.4f, %.4f", c.latitude, c.longitude))
            case .denied:
                print("被拒   在「系统设置 › 隐私与安全性 › 定位服务」里打开，或手填经纬度")
            case .failed(let reason):
                print("失败   \(reason)")
            }
            done = true
        }
        // 授权对话框要等人点，最多陪它两分钟；`PreciseLocation` 自己也有超时。
        let deadline = Date().addingTimeInterval(120)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        exit(done ? 0 : 1)
    }
}

/// 新手指引的排障入口：
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --guide [status|reset|show]
/// ```
///
/// `status` / `reset` 打印完就退出，`show` 不退出 —— 它只是把这一次启动标成「无论
/// 如何都弹」，好让改完版式直接看效果，不必先把 `schedule.json` 挪走假装全新安装。
///
/// 「看过了」存在 `UserDefaults` 里，`HOURGLOW_HOME` 带不走它，所以要一个干净的
/// 首次启动得两条一起用：
///
/// ```
/// HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow --guide reset
/// HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow
/// ```
enum GuideProbe {
    @MainActor
    static func handleIfNeeded() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--guide") else { return }
        let action = index + 1 < arguments.count ? arguments[index + 1] : "status"

        switch action {
        case "show":
            Onboarding.forcedByFlag = true
            return          // 继续正常启动，指引会在 didFinishLaunching 里弹出来
        case "reset":
            Onboarding.reset()
        case "status":
            break
        default:
            print("用法: --guide [status|reset|show]")
            exit(2)
        }
        print("新手指引  \(Onboarding.describe())")
        exit(0)
    }
}
