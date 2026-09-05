import Foundation
import AppKit

/// Scheduling engine: writes the right wallpaper to the system at the right time.
///
/// ## No polling
///
/// Schedules the timer directly for the next trigger and does nothing in between. Four kinds of
/// real-world events can disrupt that schedule; subscribe to each instead of waking every minute:
///
/// - Wake from sleep: NSWorkspace.didWakeNotification. An overdue timer also fires on wake,
///   providing two redundant paths to catch up.
/// - System clock changes (synchronization or manual adjustment): NSSystemClockDidChange.
/// - Time-zone or daylight-saving changes: NSSystemTimeZoneDidChange. Call
///   NSTimeZone.resetSystemTimeZone() on receipt or TimeZone.current retains the old value.
/// - Day rollover: NSCalendarDayChanged, since sunrise and sunset change daily.
///
/// A safety net limits timer sleep to maxSleep so a missed notification cannot disable the engine indefinitely.
///
/// ## Respecting manual wallpaper changes
///
/// Of the three semantics in MVP, the chosen behavior combines a and c; neither works alone:
///
/// - Pure a (overwrite on the next evaluation): close the lid for an hour and wake in the same slot,
///   and we would overwrite a manual choice made ten minutes earlier with the same scheduled image.
/// - Pure c (never overwrite unless the current wallpaper is ours): one manual change disables
///   automatic switching indefinitely unless the user manually restores our last wallpaper.
///   That contradicts the TODO goal of requiring no extra user actions.
///
/// Instead, distinguish whether a new trigger boundary has been crossed:
///
/// - **Crossed** (trigger reached, slept past a trigger, or resumed after pausing): write normally.
///   Manual choices last until the next scheduled transition, like a thermostat's temporary hold.
/// - **Not crossed** (launch, wake, time-zone change, or other reevaluation within the same slot):
///   write only if the current wallpaper is still our last write; otherwise defer to the user's choice.
///
/// Compare EngineState.lastFiredAt with the current Resolution.since to decide.
final class Scheduler {

    /// What triggered this evaluation. Affects only logging and whether to force a write.
    enum Reason: String {
        case launch, timer, wake, clockChange, timeZoneChange, dayChange
        case configChange, pause, resume, manual

        var label: String { L10n.t("engine.reason.\(rawValue)") }

        /// These reasons express explicit user intent and overwrite unconditionally.
        var isAssertive: Bool { self == .resume || self == .manual }
    }

    /// Result of one evaluation.
    enum Outcome {
        /// Successfully written.
        case applied(Slot)
        /// Target already matches; skipped the write to avoid flicker.
        case unchanged(Slot)
        /// User changed the wallpaper and no new trigger boundary was crossed; defer to that choice.
        case deferredToManual(Slot, actual: Wallpaper?)
        /// Globally paused.
        case paused
        /// No enabled slots, or solar triggers lack coordinates or encounter polar day/night.
        case unresolvable
        case failed(Error)
    }

    // MARK: - Observable state

    /// Log callback: the CLI writes to stdout; the M3 UI displays it in the panel.
    var onLog: ((String) -> Void)?
    /// Called after each evaluation so the UI can refresh.
    var onEvaluate: ((Outcome, Resolution?) -> Void)?

    private(set) var schedule: Schedule
    private(set) var state: EngineState
    private(set) var lastResolution: Resolution?
    private(set) var lastOutcome: Outcome?
    /// Scheduled timer instant; nil when unscheduled (paused or not running).
    private(set) var wakeUpAt: Date?

    // MARK: - Internals

    private var timer: Timer?
    private var watcher: ConfigWatcher?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var isRunning = false

    /// Safety net: reevaluate at least this often even if nothing else happens.
    private let maxSleep: TimeInterval = 6 * 3600
    /// Retry interval when the schedule cannot be resolved.
    private let retryInterval: TimeInterval = 15 * 60
    /// Fire slightly after the trigger; a few milliseconds early would resolve the previous slot and waste a wakeup.
    private let fireGuard: TimeInterval = 1

    init(schedule: Schedule, state: EngineState = .load()) {
        self.schedule = schedule
        self.state = state
    }

    // MARK: - Lifecycle

    /// Registers observers, starts configuration watching, and evaluates immediately.
    func start(schedule initialSchedule: Schedule? = nil) {
        guard !isRunning else { return }
        // When a follower takes over, another process may have changed configuration since construction.
        // Start from the version reread after acquiring the lock, never by writing back the stale snapshot.
        if let initialSchedule { schedule = initialSchedule }
        isRunning = true
        observeSystemEvents()
        startWatchingConfig()
        evaluate(reason: .launch)
    }

    func stop() {
        isRunning = false
        cancelTimer()
        watcher?.stop()
        watcher = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in systemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        systemObservers.removeAll()
    }

    // MARK: - Evaluation

    /// Evaluates, writes or skips, then schedules the timer for the next trigger.
    @discardableResult
    func evaluate(reason: Reason, now: Date = Date()) -> Outcome {
        let outcome = decide(reason: reason, now: now)
        lastOutcome = outcome
        log(outcome, reason: reason)
        scheduleNextWakeUp(from: now, paused: schedule.paused)
        onEvaluate?(outcome, lastResolution)
        return outcome
    }

    private func decide(reason: Reason, now: Date) -> Outcome {
        // state.json is authoritative. CLI resume/apply run in separate processes and can stale
        // the in-memory copy, so reload before every evaluation.
        state = .load()

        if schedule.paused && !reason.isAssertive {
            lastResolution = nil
            return .paused
        }

        guard let resolution = schedule.resolve(at: now) else {
            lastResolution = nil
            return .unresolvable
        }
        lastResolution = resolution

        if !shouldAssert(resolution, reason: reason), let written = state.lastWritten {
            let actual = try? WallpaperWriter.current()
            if actual.map(WallpaperWriter.normalized) != WallpaperWriter.normalized(written) {
                return .deferredToManual(resolution.active, actual: actual)
            }
        }

        do {
            let changed = try WallpaperWriter.apply(resolution.active.wallpaper)
            // Image paths may use ~/…, but the system returns absolute paths. Persist normalized state
            // so the next launch does not mistake the same image for a manual change.
            state.lastWritten = WallpaperWriter.normalized(resolution.active.wallpaper)
            state.lastSlotID = resolution.active.id
            state.lastFiredAt = resolution.since
            if changed { state.lastAppliedAt = now }
            try? state.save()
            return changed ? .applied(resolution.active) : .unchanged(resolution.active)
        } catch {
            return .failed(error)
        }
    }

    /// Whether to overwrite unconditionally; see the type documentation on manual changes.
    /// Not private because Tests/EngineCheck exercises the decision matrix directly.
    func shouldAssert(_ resolution: Resolution, reason: Reason) -> Bool {
        if reason.isAssertive { return true }
        // No write history: first run, with no prior choice to defer to.
        guard let lastFiredAt = state.lastFiredAt else { return true }
        // A new trigger boundary was crossed.
        if resolution.since > lastFiredAt { return true }
        // Slots were added, removed, or edited, and the active slot differs from the previous one.
        if state.lastSlotID != resolution.active.id { return true }
        return false
    }

    // MARK: - Timing

    /// Computes the timer target. A pure function checked directly by Tests/EngineCheck.
    ///
    /// - next is the next trigger; resolved indicates whether this evaluation found an active slot.
    /// - Choose the earliest upper bound: next trigger, maxSleep safety net, or unresolved retry interval.
    /// - The lower bound is now + 1 second; a timer at or before now would immediately spin another evaluation.
    func wakeUpTarget(from now: Date, next: Date?, resolved: Bool) -> Date {
        var target = now.addingTimeInterval(maxSleep)
        if let next {
            target = min(target, next.addingTimeInterval(fireGuard))
        } else if !resolved {
            target = min(target, now.addingTimeInterval(retryInterval))
        }
        return max(target, now.addingTimeInterval(1))
    }

    private func scheduleNextWakeUp(from now: Date, paused: Bool) {
        cancelTimer()
        guard isRunning, !paused else { wakeUpAt = nil; return }

        let fireDate = wakeUpTarget(from: now,
                                    next: lastResolution?.next?.at,
                                    resolved: lastResolution != nil)
        wakeUpAt = fireDate

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.evaluate(reason: .timer)
        }
        // Use .common, not .default: the M3 menu-bar panel uses another run-loop mode when open,
        // so a .default timer would stop while the panel is visible.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                self?.evaluate(reason: .wake)
            })

        let center = NotificationCenter.default
        systemObservers.append(
            center.addObserver(forName: .NSSystemClockDidChange,
                               object: nil, queue: .main) { [weak self] _ in
                self?.evaluate(reason: .clockChange)
            })
        systemObservers.append(
            center.addObserver(forName: .NSSystemTimeZoneDidChange,
                               object: nil, queue: .main) { [weak self] _ in
                // Without a reset, TimeZone.current retains the old zone and miscalculates the day's solar events.
                NSTimeZone.resetSystemTimeZone()
                self?.evaluate(reason: .timeZoneChange)
            })
        systemObservers.append(
            center.addObserver(forName: .NSCalendarDayChanged,
                               object: nil, queue: .main) { [weak self] _ in
                self?.evaluate(reason: .dayChange)
            })
    }

    private func startWatchingConfig() {
        let watcher = ConfigWatcher(fileURL: Store.fileURL) { [weak self] in
            guard let self else { return }
            guard let reloaded = try? Store.load() else {
                self.onLog?(L10n.t("engine.log.configUnreadable"))
                return
            }
            self.schedule = reloaded
            self.evaluate(reason: .configChange)
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - External operations

    /// Pauses globally, stopping the timer and leaving the current wallpaper in place.
    func pause() throws {
        guard !schedule.paused else { return }
        var updated = schedule
        updated.paused = true
        try persistSchedule(updated)
        evaluate(reason: .pause)
    }

    /// Resumes and immediately applies the active wallpaper, overriding intervening manual changes.
    func resume() throws {
        guard schedule.paused else { return }
        var updated = schedule
        updated.paused = false
        try persistSchedule(updated)
        evaluate(reason: .resume)
    }

    /// Forces the currently scheduled wallpaper to be applied.
    @discardableResult
    func applyNow() -> Outcome {
        evaluate(reason: .manual)
    }

    /// Replaces the configuration (used by the M3 UI).
    func update(schedule newValue: Schedule) throws {
        try persistSchedule(newValue)
        evaluate(reason: .configChange)
    }

    private func persistSchedule(_ newValue: Schedule) throws {
        // Persist before updating memory; on failure keep the old configuration so memory and disk cannot diverge.
        try Store.save(newValue)
        schedule = newValue
        // Do not let our own write trigger a second evaluation through the watcher.
        watcher?.acknowledgeSelfWrite()
    }

    // MARK: - Logging

    private func log(_ outcome: Outcome, reason: Reason) {
        let name = { (slot: Slot) in
            "\(slot.trigger.description) → \(Scheduler.describe(slot.wallpaper))"
        }
        let message: String
        switch outcome {
        case .applied(let slot):
            message = L10n.t("engine.log.applied", name(slot))
        case .unchanged(let slot):
            message = L10n.t("engine.log.unchanged", name(slot))
        case .deferredToManual(let slot, let actual):
            let now = actual.map(Scheduler.describe) ?? L10n.t("common.unknown")
            message = L10n.t("engine.log.deferred", now, name(slot))
        case .paused:
            message = L10n.t("engine.log.paused")
        case .unresolvable:
            message = L10n.t("engine.log.unresolvable")
        case .failed(let error):
            message = L10n.t("engine.log.failed", "\(error)")
        }

        var line = "[\(reason.label)] \(message)"
        if let next = lastResolution?.next {
            line += L10n.t("engine.log.next",
                           Scheduler.stamp(next.at),
                           Scheduler.describe(next.slot.wallpaper))
        }
        onLog?(line)
    }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private static let dayClockFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    /// With one slot, "next" means the same slot tomorrow; HH:mm alone would look like a past time.
    private static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clockFormat.string(from: date) }
        if calendar.isDateInTomorrow(date) { return L10n.t("clock.tomorrow", clockFormat.string(from: date)) }
        return dayClockFormat.string(from: date)
    }

    /// Human-readable wallpaper names. Load and cache the catalog once, since every log line uses it.
    private static let assetNames: [String: String] = {
        let catalog = (try? AerialCatalog.load()) ?? []
        return Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }()

    static func describe(_ wallpaper: Wallpaper) -> String {
        switch wallpaper {
        case .aerial(let id): return assetNames[id] ?? "aerial \(id.prefix(8))…"
        case .image(let path): return (path as NSString).lastPathComponent
        }
    }
}
