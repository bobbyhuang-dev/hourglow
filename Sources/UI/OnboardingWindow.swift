import AppKit
import SwiftUI

/// The window that hosts onboarding.
///
/// One of the project's two standalone windows (the other is `AboutWindow`); `OnboardingView` explains
/// why the guide must appear even before the panel is found. Keep every other interface in the menu bar panel.
///
/// Three important details:
///
/// - **Temporarily become a foreground app.** An `LSUIElement` process defaults to `.accessory`:
///   its window can appear, but focus, `⌘Tab`, and Dock visibility are unreliable or absent, so users
///   cannot find it again after clicking elsewhere. Use `.regular` while the guide is open, then restore
///   the policy, as the import flow already does for `NSOpenPanel`.
/// - **Closing counts as seen.** Skipping, finishing, and clicking the close button all count:
///   once shown and closed, it should not reopen on the next launch. The ⋯ menu can reopen it.
/// - **Use a normal title bar.** `.fullSizeContentView` did not extend the sky gradient to the top:
///   it leaves the `contentRect:` → window-frame conversion unchanged, adding an unmatched empty strip
///   above the content (566 pt of content produced a 598 pt window). A titled system bar feels more native.
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

        // No .resizable: the fixed layout has no useful adjustable size.
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        window.title = L10n.t("guide.window.title")
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
        window?.close()   // Centralize cleanup in windowWillClose, including the title-bar close button.
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
