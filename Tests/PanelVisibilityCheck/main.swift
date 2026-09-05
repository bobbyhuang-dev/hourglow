import AppKit
import SwiftUI

// Exercise real hosting-window visibility without starting an engine or accessing configuration.
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    var visible = false
    var changes: [Bool] = []
    let host = NSHostingView(rootView: AnyView(
        Text("HourGlow visibility check")
            .background(PanelVisibilityObserver {
                visible = $0
                changes.append($0)
            })
    ))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 60),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.orderOut(nil) }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    settle()
    precondition(!visible, "A mounted view in a hidden window is not visible")
    for _ in 0..<3 {
        window.orderFrontRegardless()
        settle()
        precondition(visible, "Showing a retained hosting window starts display refresh")
        window.orderOut(nil)
        settle()
        precondition(!visible, "Hiding a retained hosting window stops display refresh")
    }
    print("✓ Repeated show/hide follows window visibility without remounting SwiftUI")

    window.orderFrontRegardless()
    window.orderOut(nil)
    settle()
    precondition(!visible, "A rapid open/close cannot leave display refresh enabled")

    window.orderFrontRegardless()
    settle()
    precondition(visible, "The panel can reopen after a rapid close")
    host.rootView = AnyView(Text("Observer removed"))
    settle()
    precondition(!visible, "Dismantling the observer stops display refresh")
    let stoppedCount = changes.count
    window.orderOut(nil)
    window.orderFrontRegardless()
    settle()
    precondition(changes.count == stoppedCount, "A dismantled observer no longer sends callbacks")
    print("✓ Rapid visibility changes and observer teardown leave no stale refresh activity")
}
print("All panel visibility checks passed")
