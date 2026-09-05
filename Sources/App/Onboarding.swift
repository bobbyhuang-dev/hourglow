import Foundation

/// Onboarding steps and the rules for who should see them.
///
/// Foundation only, with no UI or `Store` dependencies, so `appcheck` can compile this file
/// on its own and assert the rules offline. Layout lives in `UI/OnboardingView.swift` and `UI/OnboardingWindow.swift`.
///
/// Copy belongs here rather than scattered through views: what each step says is content,
/// not layout, and the check target can ensure that no step is empty.
enum OnboardingStep: Int, CaseIterable, Identifiable, Equatable {
    /// The app lives in the menu bar: the entry point itself is easy to miss in an `LSUIElement` app.
    case welcome
    /// Location enables sunrise and sunset scheduling, and is the only system permission requiring user approval.
    case place
    /// Staying resident: launch at login, menu bar permission, and not running from Downloads.
    case resident
    /// How to edit the timeline.
    case timeline
    case done

    var id: Int { rawValue }

    /// Each step's key prefix. Copy lives in the language catalogs (`Sources/L10n/Catalogs/`),
    /// not in views: content must remain accessible to the check target.
    var slug: String {
        switch self {
        case .welcome:  return "welcome"
        case .place:    return "place"
        case .resident: return "resident"
        case .timeline: return "timeline"
        case .done:     return "done"
        }
    }

    var title: String { L10n.t("guide.\(slug).title") }

    /// The two lines below the title: what this step does and why.
    var summary: String { L10n.t("guide.\(slug).summary") }
}

/// Tracks the current step. This pure state machine handles bounds so views do not have to.
struct OnboardingFlow: Equatable {
    static let steps = OnboardingStep.allCases

    private(set) var index = 0

    var step: OnboardingStep { Self.steps[index] }
    var count: Int { Self.steps.count }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == count - 1 }

    /// "Step 2 of 5": human-facing numbering starts at one.
    var caption: String { L10n.t("guide.step", index + 1, count) }

    mutating func advance() {
        guard !isLast else { return }
        index += 1
    }

    mutating func back() {
        guard !isFirst else { return }
        index -= 1
    }

    mutating func jump(to step: OnboardingStep) {
        guard let target = Self.steps.firstIndex(of: step) else { return }
        index = target
    }
}

enum Onboarding {

    /// Increment for substantive step changes to show the guide again to past viewers; not for typo fixes.
    static let version = 1

    private static let seenKey = "onboarding.seenVersion"

    // MARK: - Presentation rules

    /// Whether to present automatically. A pure function asserted directly by `appcheck`.
    ///
    /// - Never seen: present automatically **only on a genuinely fresh install**. Users upgrading
    ///   from 1.2 already have a configuration; an unexpected timeline tutorial after an automatic
    ///   update would be intrusive. They can open the guide themselves from the ⋯ menu.
    /// - Seen an older guide: present again after substantive content changes (`version` increases).
    static func shouldPresent(seenVersion: Int?, isFirstRun: Bool) -> Bool {
        guard let seenVersion else { return isFirstRun }
        return seenVersion < version
    }

    // MARK: - Fresh-install detection

    /// `nil` means no caller has checked yet.
    @MainActor private static var freshInstall: Bool?

    /// Record whether the configuration file existed before this launch.
    ///
    /// **Must run before any call to `Store.load()`**, which writes the Tahoe preset if needed;
    /// checking afterward would always find a file. The first call wins; later calls cannot override it.
    /// Both `AppModel.init` and `AppDelegate` call this, and either may run first.
    @MainActor
    static func captureFirstRun(configExists: Bool) {
        guard freshInstall == nil else { return }
        freshInstall = !configExists
    }

    @MainActor
    static var isFirstRun: Bool { freshInstall ?? false }

    /// Used by `--guide show`: always present on this launch to preview layout changes directly.
    @MainActor static var forcedByFlag = false

    @MainActor
    static var shouldPresentOnLaunch: Bool {
        forcedByFlag || shouldPresent(seenVersion: seenVersion, isFirstRun: isFirstRun)
    }

    // MARK: - Remembering viewed guides

    /// The guide version already viewed, or `nil` if never viewed.
    ///
    /// Stored in `UserDefaults`, not `schedule.json`: that file is a user-editable schedule,
    /// and onboarding history is not scheduling data. Redirecting `HOURGLOW_HOME` therefore
    /// does not isolate this state, which is why `--guide reset` exists.
    static var seenVersion: Int? {
        get { UserDefaults.standard.object(forKey: seenKey) as? Int }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: seenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: seenKey)
            }
        }
    }

    /// Closing counts as viewed, whether skipped, completed, or closed via the window button; otherwise it reappears on every launch.
    static func markSeen() { seenVersion = version }

    static func reset() { seenVersion = nil }

    /// The line printed by `--guide status`.
    @MainActor
    static func describe() -> String {
        let seen = seenVersion.map { L10n.t("guide.status.seen", $0) }
            ?? L10n.t("guide.status.unseen")
        let verdict = L10n.t(shouldPresentOnLaunch ? "guide.status.willShow"
                                                   : "guide.status.wontShow")
        return L10n.t("guide.status", seen, version, verdict)
    }
}
