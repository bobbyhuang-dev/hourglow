import AppKit
import SwiftUI

/// A cached hosting view can stay mounted while its window is hidden. SwiftUI appearance
/// callbacks do not reliably follow that transition, so observe the actual window instead.
struct PanelVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stop()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
                // Publishing model changes during a SwiftUI view update is unsafe. Read the
                // latest window state on the next turn, also coalescing rapid show/hide changes.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onChange?(self.window?.isVisible == true)
                }
            }
            if window == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onChange?(self.window?.isVisible == true)
                }
            }
        }

        func stop() {
            observation = nil
            let callback = onChange
            onChange = nil
            DispatchQueue.main.async { callback?(false) }
        }
    }
}
