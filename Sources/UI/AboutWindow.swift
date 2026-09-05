import AppKit
import SwiftUI

/// The window that hosts `AboutView`.
///
/// One of the project's two standalone windows (the other is `OnboardingWindow`, which explains the
/// rules for being a foreground app). About follows the system's About This Mac: a small non-resizable
/// window with a transparent, untitled title bar, so the traffic lights sit directly on the card.
/// `.fullSizeContentView` is deliberately not used; see `OnboardingWindow` for the frame pitfall.
@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {

    static let shared = AboutWindow()

    private var window: NSWindow?
    private var previousPolicy: NSApplication.ActivationPolicy?

    private override init() { super.init() }

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingView(rootView: AboutView())
        host.frame = NSRect(x: 0, y: 0, width: About.width, height: About.height)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        // Named for ⌘Tab and accessibility, but drawn without a title bar label, like About This Mac.
        window.title = L10n.t("about.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // See OnboardingWindow: an accessory app's window cannot reliably take focus or be found again.
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if let previousPolicy {
            NSApp.setActivationPolicy(previousPolicy)
        }
        previousPolicy = nil
    }
}
