import AppKit
import SwiftUI

/// Entry point for the menu bar app.
///
/// `LSUIElement` (in the packaging script's Info.plist) removes the Dock icon and main window;
/// the entire interface is the 360 × 470 `MenuBarExtra` panel.
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
        // .window supports a custom panel; the default .menu only supports menu items.
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon. A half-filled hourglass makes paused scheduling immediately recognizable.
private struct MenuBarIcon: View {
    private let model = AppModel.shared

    var body: some View {
        Image(systemName: model.schedule.paused ? "hourglass.bottomhalf.filled" : "hourglass")
    }
}

/// Start the engine before the panel first opens: menu bar apps often run without ever opening it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must precede any `Store.load()` call (`AppModel.init` also guards this; either may run first):
        // the configuration file's existence is the only evidence of whether this is a fresh install.
        Onboarding.captureFirstRun(
            configExists: FileManager.default.fileExists(atPath: Store.fileURL.path))
        LoginItemProbe.handleIfNeeded()
        GuideProbe.handleIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Location needs system callbacks and an active main run loop, so it cannot run in willFinish.
        LocateProbe.handleIfNeeded()
        AppModel.shared.start()
        // Start the engine before showing onboarding: wallpaper should be correct in the first minute.
        // The guide explains what just happened and where to change it later.
        if Onboarding.shouldPresentOnLaunch {
            OnboardingWindow.shared.present()
        }
    }
}

/// Launch-at-login troubleshooting entry point:
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --login-item [status|on|off]
/// ```
///
/// Not part of `hourglow-cli`, because `SMAppService.mainApp` registers **the caller's own
/// bundle**. The CLI is a bare binary with no bundle to register, so it always sees `.notFound`.
/// Exits immediately after printing, without leaving a menu bar icon.
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
                print(L10n.t("probe.loginItem.failed", (error as NSError).localizedDescription))
                exit(1)
            }
        case "status":
            break
        default:
            print(L10n.t("probe.loginItem.usage"))
            exit(2)
        }
        print(L10n.t("probe.loginItem.status", LaunchAtLogin.describe()))
        print(L10n.t("probe.bundle", Bundle.main.bundleURL.path))
        exit(0)
    }
}

/// Location troubleshooting entry point:
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --locate
/// ```
///
/// Like launch at login, permissions are granted per bundle; the bare `hourglow-cli` cannot query them.
/// The first run shows the system location permission dialog, using the reason from Info.plist's
/// `NSLocationWhenInUseUsageDescription`. Results are printed, never saved to the configuration:
/// saving is the settings button's job, and diagnostics must not modify user data as a side effect.
enum LocateProbe {
    @MainActor
    static func handleIfNeeded() {
        guard CommandLine.arguments.contains("--locate") else { return }

        var done = false
        PreciseLocation.shared.request { outcome in
            switch outcome {
            case .coordinate(let c):
                print(L10n.t("probe.locate.coordinate", c.latitude, c.longitude))
            case .denied:
                print(L10n.t("probe.locate.denied"))
            case .failed(let reason):
                print(L10n.t("probe.locate.failed", reason))
            }
            done = true
        }
        // Allow two minutes for the user to answer the permission dialog; `PreciseLocation` also has its own timeout.
        let deadline = Date().addingTimeInterval(120)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        exit(done ? 0 : 1)
    }
}

/// Onboarding troubleshooting entry point:
///
/// ```
/// build/HourGlow.app/Contents/MacOS/HourGlow --guide [status|reset|show]
/// ```
///
/// `status` / `reset` print and exit; `show` continues launching with forced presentation,
/// letting layout changes be previewed without moving `schedule.json` to fake a fresh install.
///
/// Viewed status lives in `UserDefaults`, unaffected by `HOURGLOW_HOME`, so a clean first
/// launch requires both commands:
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
            return          // Continue normal launch; didFinishLaunching will present the guide.
        case "reset":
            Onboarding.reset()
        case "status":
            break
        default:
            print(L10n.t("probe.guide.usage"))
            exit(2)
        }
        print(L10n.t("probe.guide.status", Onboarding.describe()))
        exit(0)
    }
}
