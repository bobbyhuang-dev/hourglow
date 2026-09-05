import AppKit
import SwiftUI

// Render each page as a PNG (the slot page's fixed-time section has a different layout, so capture it separately).
// The menu bar panel is not a normal window and screencapture cannot capture it; use this to compare layout changes:
//
//   ./build/panelshot [output-directory] [--now 2026-09-04T06:20] [--only timeline] [--appearance dark]
//
// `--now` freezes the panel's "now" at a specific instant (active slot, next switch time, and time remaining).
// Demo GIFs and share cards use it to capture several times within a day (see Tools/makedemo.sh); omit it to use the real clock.
// `--only` captures only images whose names begin with its value (timeline / slot / picker / settings / place / guide / about),
// saving more than ten seconds when only one image is needed.
// `--appearance light|dark` fixes the appearance instead of following the system; evening and night demo panels darken with the wallpaper.
//
// Uses a real window + `cacheDisplay`, not `ImageRenderer` — the latter cannot render ScrollView
// contents or AppKit-backed controls (segmented controls, time steppers, text fields, menus).
// The window appears briefly, almost fully transparent, then closes after rendering.

@MainActor
func shoot<V: View>(_ view: V, named name: String, into directory: URL,
                    width: CGFloat = Panel.width) {
    // Names look like "1-timeline" or "6-guide-3"; `--only` matches the part after the numeric prefix.
    if let only, !name.drop(while: { $0 != "-" }).dropFirst().hasPrefix(only) { return }
    let content = view
        .environment(AppModel.shared)
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))

    let host = NSHostingView(rootView: content)
    // Pages have different heights (the timeline fits its slot count); use each page's preferred size.
    let fitted = host.fittingSize
    host.frame = NSRect(x: 0, y: 0, width: width,
                        height: max(fitted.height, 120))

    let window = NSWindow(contentRect: host.frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.appearance = appearance
    window.contentView = host
    window.backgroundColor = .windowBackgroundColor
    window.alphaValue = 1
    window.orderFrontRegardless()

    defer { window.orderOut(nil) }

    // Capture twice: the first pass lets layout and thumbnail `.task` work settle; keep the second capture.
    // With only one pass, asynchronously loaded layers may not yet be composited, leaving half the image blank.
    var bitmap: NSBitmapImageRep?
    for wait in [1.2, 0.4] {
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        bitmap = rep
    }
    guard let bitmap else {
        print("Could not obtain bitmap: \(name)"); return
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Encoding failed: \(name)"); return
    }
    let url = directory.appendingPathComponent("\(name).png")
    try? png.write(to: url)
    print("Wrote \(url.path)")
}

var outputPath = "."
var only: String?
var appearance: NSAppearance?
var previewUpdateRateLimit = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--update-rate-limit":
        previewUpdateRateLimit = true
    case "--now":
        guard let value = arguments.next() else { print("--now requires a time"); exit(2) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let date = formatter.date(from: value) else {
            print("--now cannot parse \(value); use the format 2026-09-04T06:20"); exit(2)
        }
        // Must run before the first access to AppModel.shared: its init immediately resolves using "now".
        AppModel.now = { date }
    case "--only":
        guard let value = arguments.next() else { print("--only requires a name"); exit(2) }
        only = value
    case "--appearance":
        guard let value = arguments.next() else { print("--appearance requires light or dark"); exit(2) }
        switch value {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark":  appearance = NSAppearance(named: .darkAqua)
        default: print("--appearance only accepts light or dark"); exit(2)
        }
    default:
        outputPath = argument
    }
}
let directory = URL(fileURLWithPath: outputPath)

// Override only this process's argument domain, without changing user preferences or accessing the network; check for truncation of long errors and recovery times.
if previewUpdateRateLimit {
    let limit = AppUpdater.RateLimit(retryAt: AppModel.now().addingTimeInterval(600), notice: .reset)
    UserDefaults.standard.setVolatileDomain(
        ["updates.rateLimit": try! JSONEncoder().encode(limit)],
        forName: UserDefaults.argumentDomain)
}

// Top-level code is not main-actor isolated, but it does run on the main thread.
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    let model = AppModel.shared
    guard let first = model.schedule.slots.first else {
        print("No slots in the configuration; run hourglow-cli list first"); exit(1)
    }

    shoot(TimelinePage(open: { _ in }), named: "1-timeline", into: directory)
    shoot(SlotPage(slotID: first.id, open: { _ in }), named: "2-slot", into: directory)
    // The fixed-time section uses an AppKit time field, with a completely different layout from sunrise/sunset.
    // Capturing only the first slot may never show it. Take an extra capture if the configuration has one.
    if let clock = model.schedule.slots.first(where: {
        if case .clock = $0.trigger { return true } else { return false }
    }), clock.id != first.id {
        shoot(SlotPage(slotID: clock.id, open: { _ in }), named: "2b-slot-clock", into: directory)
    }
    shoot(WallpaperPicker(slotID: first.id, open: { _ in }), named: "3-picker", into: directory)
    shoot(SettingsPage(open: { _ in }), named: "4-settings", into: directory)
    shoot(PlacePage(open: { _ in }), named: "5-place", into: directory)

    // Onboarding is not a panel page, nor is it 360 wide — it is a standalone window (see
    // the type comment on `OnboardingView`). Capture each of the five steps to compare copy or illustration changes.
    for (index, step) in OnboardingStep.allCases.enumerated() {
        shoot(OnboardingView(initialStep: step, finish: {}),
              named: "6-guide-\(index + 1)", into: directory, width: Guide.width)
    }
    // About is the second standalone window, sized like About This Mac.
    shoot(AboutView(), named: "7-about", into: directory, width: About.width)
}
