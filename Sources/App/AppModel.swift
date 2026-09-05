import AppKit
import CoreLocation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

/// The sole layer between the UI and engine.
///
/// Views only read presentation state and call methods here; evaluation and writes remain
/// entirely in `Scheduler`. M3 does not duplicate scheduling logic for the UI.
///
/// ## Leader / follower
///
/// A background `hourglow-cli run` (or an M2-installed LaunchAgent) may already be scheduling.
/// Two engines would mistake each other's writes for manual user changes, so startup first
/// attempts to acquire `EngineLock`:
///
/// - **Leader** (lock acquired): this process starts `Scheduler`, owning timers and system events.
/// - **Follower** (lock unavailable): only edits `schedule.json`, without scheduling; the leader's
///   `ConfigWatcher` picks up changes. The panel header identifies who is in control.
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    /// Every notion of "now" in the panel comes from here, never directly from `Date()`.
    ///
    /// Only `panelshot --now` changes this: demos and screenshots freeze the timeline at a
    /// particular time of day (active slot and next switch). The app and CLI always use the real clock.
    /// `nonisolated(unsafe)` is needed because `Clock.remaining` is not main-actor isolated;
    /// this value is assigned only once at process startup, before any views appear.
    nonisolated(unsafe) static var now: () -> Date = { Date() }

    // MARK: - Presentation state

    private(set) var schedule: Schedule
    /// Current and next slots; refreshed on engine events and every 30 seconds while visible.
    private(set) var resolution: Resolution?
    /// The wallpaper actually set in the system now.
    private(set) var actual: Wallpaper?
    /// The engine's last write; a difference from `actual` indicates an intervening manual change.
    private(set) var lastWritten: Wallpaper?
    /// The latest engine log message, automatically dismissed after a few seconds.
    private(set) var message: String?

    let catalog: [AerialAsset]
    private(set) var isFollower: Bool

    /// Current launch-at-login and LaunchAgent state. Both query the system (`SMAppService`
    /// uses synchronous IPC; LaunchAgent even forks `launchctl`), so refresh only when settings
    /// appear, not on every redraw inside a view's body.
    private(set) var launchAtLogin = SMAppService.Status.notRegistered
    private(set) var agentInstalled = false
    /// Extra launch-at-login context: disabled in System Settings, moved bundle, or registration failure.
    private(set) var launchAtLoginNote: String?
    private(set) var locating = LocatingState.idle

    /// Incremented on language changes. `PanelRoot` uses it as `.id` to rebuild the entire panel.
    ///
    /// Views look up copy in their own bodies without reading any `@Observable` property.
    /// SwiftUI cannot track language changes directly, so this counter notifies it.
    private(set) var languageGeneration = 0

    /// Updates are independent of wallpaper scheduling; this only stores state displayed in settings.
    private(set) var updateState = AppUpdater.pendingRateLimit()
        .map { AppUpdateState.failed($0.localizedDescription) } ?? .idle
    private(set) var automaticUpdatesEnabled = AppUpdater.automaticUpdatesEnabled
    private(set) var importingScene = false

    /// The slot being edited. Changes stay here until Apply writes them into `schedule`.
    ///
    /// Stored here rather than in `SlotPage`'s `@State`: wallpaper selection is a separate page,
    /// so SlotPage is unmounted and rebuilt. Drafts must also outlive the panel, which closes
    /// on losing focus, as always happens when choosing a local image in the system dialog.
    private var draftSession: SlotDraft?

    var draft: Slot? { draftSession?.slot }

    private let assetNames: [String: String]
    private let scheduler: Scheduler
    private var lock: EngineLock?
    private var watcher: ConfigWatcher?
    private var ticker: Timer?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isPanelVisible = false
    private var messageExpiry: DispatchWorkItem?
    private var awaitingReadableConfig = false
    @ObservationIgnored private var updateTicker: Timer?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var languageObserver: NSObjectProtocol?

    private init() {
        // Check whether the configuration exists before `Store.load()`, which writes the Tahoe
        // preset if needed. Checking afterward would always find a file and prevent onboarding.
        Onboarding.captureFirstRun(
            configExists: FileManager.default.fileExists(atPath: Store.fileURL.path))
        catalog = (try? AerialCatalog.load()) ?? []
        assetNames = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        let loaded: Schedule
        let loadFailed: Bool
        do {
            loaded = try Store.load()
            loadFailed = false
        } catch {
            // Corruption is not a fresh install: do not take over wallpaper with a preset or overwrite the bad file.
            // Reuse follower watching and periodic takeover retries; start scheduling only once the user repairs it.
            loaded = Schedule()
            loadFailed = true
        }
        awaitingReadableConfig = loadFailed
        schedule = loaded
        // The panel may open before start(); resolve now to avoid briefly showing no active slot.
        resolution = loaded.resolve(at: AppModel.now())
        let acquiredLock = loadFailed ? nil : EngineLock.acquire()
        lock = acquiredLock
        isFollower = acquiredLock == nil
        scheduler = Scheduler(schedule: loaded)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduler.onLog = { line in
            MainActor.assumeIsolated { AppModel.shared.show(line) }
        }
        scheduler.onEvaluate = { _, _ in
            MainActor.assumeIsolated { AppModel.shared.absorbFromScheduler() }
        }

        if isFollower {
            // Another process schedules; we only need to follow configuration changes.
            let watcher = ConfigWatcher(fileURL: Store.fileURL) {
                MainActor.assumeIsolated { AppModel.shared.reloadFromDisk() }
            }
            watcher.start()
            self.watcher = watcher
        } else {
            scheduler.start()
        }

        // Language is changed from settings, but the whole panel must follow.
        // Observe the change itself regardless of who initiated it.
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.languageGeneration += 1 }
            }

        refresh()

        updateRefreshTimer()

        // The app often runs for days, so checking only at startup is insufficient. Hourly wakeups
        // are cheap; AppUpdater's 24-hour interval determines the actual network frequency.
        checkForUpdates(manual: false)
        let updateTicker = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkForUpdates(manual: false) }
        }
        RunLoop.main.add(updateTicker, forMode: .common)
        self.updateTicker = updateTicker
        if awaitingReadableConfig { show(L10n.t("model.startup.configFailed")) }
    }

    /// Opening the panel must show current state immediately, including manual wallpaper changes.
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible { refresh() }
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        // Followers still need to take over after the leader exits, even with the panel closed.
        guard isStarted && (isPanelVisible || isFollower) else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.promoteIfPossible()
                if model.isPanelVisible { model.refresh() }
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    // MARK: - Queries

    func slot(_ id: UUID) -> Slot? {
        schedule.slots.first { $0.id == id }
    }

    func name(for wallpaper: Wallpaper) -> String {
        switch wallpaper {
        case .aerial(let id): return assetNames[id] ?? L10n.t("model.unknownWallpaper")
        case .image(let path): return (path as NSString).lastPathComponent
        }
    }

    func thumbnailURL(for wallpaper: Wallpaper) -> URL? {
        switch wallpaper {
        case .aerial(let id):
            return catalog.first { $0.id == id }?.thumbnailURL
        case .image(let path):
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
    }

    /// A timeline row: a slot and its actual trigger time today.
    struct Entry: Identifiable {
        let slot: Slot
        /// Solar triggers cannot resolve without coordinates or during polar day/night.
        let time: Date?
        var id: UUID { slot.id }
    }

    /// Sort by today's actual times: "30 minutes before sunset" naturally moves with the seasons.
    var entries: [Entry] {
        let coordinate = schedule.effectiveCoordinate
        let calendar = Calendar.current
        let now = AppModel.now()
        return schedule.slots
            .map { Entry(slot: $0,
                         time: $0.trigger.fireDate(on: now,
                                                   coordinate: coordinate,
                                                   calendar: calendar)) }
            .sorted { lhs, rhs in
                switch (lhs.time, rhs.time) {
                case let (l?, r?): return l < r
                case (nil, _):     return false
                case (_, nil):     return true
                }
            }
    }

    /// Whether the large image at the top of the panel is the actual current system wallpaper.
    ///
    /// Compare directly with `resolution.active`, not `lastWritten`: before the engine's first
    /// write (first run or a cleared `state.json`), `isManuallyOverridden` is always false.
    /// The image is still merely the scheduled result, so we cannot label it as the current wallpaper.
    var activeIsActual: Bool {
        guard let actual, let active = resolution?.active.wallpaper else { return false }
        return WallpaperWriter.normalized(actual) == WallpaperWriter.normalized(active)
    }

    /// The current wallpaper differs from the engine's last write; a manual change lasts until the next trigger.
    var isManuallyOverridden: Bool {
        guard let lastWritten, let actual else { return false }
        return WallpaperWriter.normalized(actual) != WallpaperWriter.normalized(lastWritten)
    }

    /// Solar slots without coordinates are skipped entirely; the user needs to know.
    var needsCoordinate: Bool {
        schedule.effectiveCoordinate == nil
            && schedule.slots.contains { $0.enabled && $0.trigger.dependsOnSun }
    }

    /// Coordinates exist, but today's sunrise and sunset cannot be resolved (polar day/night).
    ///
    /// An imported wallpaper set may use solar phases for every slot, leaving none schedulable
    /// and the wallpaper unchanged for weeks. `needsCoordinate` cannot catch this: coordinates exist, but solar events do not.
    var solarUnavailable: Bool {
        guard let coordinate = schedule.effectiveCoordinate else { return false }
        guard schedule.slots.contains(where: { $0.enabled && $0.trigger.dependsOnSun }) else {
            return false
        }
        return Solar.events(on: AppModel.now(), at: coordinate) == nil
    }

    // MARK: - Editing drafts

    /// The slot shown on the slot page: the draft while editing, otherwise the saved configuration.
    func editing(_ id: UUID) -> Slot? {
        draftSession?.slot.id == id ? draftSession?.slot : slot(id)
    }

    /// The draft has never been saved: it was created by Add Slot.
    var draftIsNew: Bool {
        draftSession?.isNew ?? false
    }

    /// Whether changes remain unapplied. Always true for new slots, whose saved counterpart is nil.
    var draftIsDirty: Bool {
        draftSession?.isDirty ?? false
    }

    var draftHasConflict: Bool { draftSession?.conflict != nil }

    var draftCanApply: Bool { draftSession?.canApply ?? false }

    var draftCanDiscard: Bool { draftIsDirty || draftHasConflict }

    /// New unsaved slots remain editable; an existing slot deleted elsewhere must not be resurrected from its draft.
    func canContinueEditing(_ id: UUID) -> Bool {
        guard let session = draftSession, session.slot.id == id else { return slot(id) != nil }
        return session.isNew || session.conflict != .deleted
    }

    func beginEditing(_ id: UUID) {
        // Returning from wallpaper selection calls this again; preserve edits already in progress.
        guard draftSession?.slot.id != id else { return }
        draftSession = slot(id).map(SlotDraft.init(existing:))
    }

    /// Edit the draft. The UI updates immediately, but configuration and wallpaper remain unchanged.
    func editDraft(_ transform: (inout Slot) -> Void) {
        draftSession?.edit(transform)
    }

    /// New slots default to the current wallpaper at the next whole hour: a usable starting point, fully editable.
    /// This is only a draft; Add is what saves it to the configuration.
    @discardableResult
    func beginNewSlot() -> UUID {
        let wallpaper = resolution?.active.wallpaper
            ?? catalog.first.map { Wallpaper.aerial(assetID: $0.id) }
            ?? .aerial(assetID: Tahoe.day)
        let hour = (Calendar.current.component(.hour, from: AppModel.now()) + 1) % 24
        let slot = Slot(trigger: .clock(hour: hour, minute: 0), wallpaper: wallpaper)
        draftSession = SlotDraft(new: slot)
        return slot.id
    }

    /// Apply / Add: the only entry point where editing changes the configuration.
    @discardableResult
    func applyDraft() -> Bool {
        guard var session = draftSession, session.canApply else { return false }
        var updated = schedule
        if session.isNew {
            updated.slots.append(session.slot)
        } else {
            guard let index = updated.slots.firstIndex(where: { $0.id == session.slot.id }) else {
                show(L10n.t("model.slotDeletedElsewhere"))
                return false
            }
            updated.slots[index] = session.slot
        }
        // Mark applied before synchronous leader callbacks, so our own write is not mistaken for an external conflict.
        // Restore on save failure, preserving the page's unapplied edits.
        let previous = session
        session.markApplied()
        draftSession = session
        guard commit(updated) else {
            draftSession = previous
            return false
        }
        return true
    }

    /// Reset the draft to its saved counterpart. New slots have none, so discard them.
    func discardDraft() {
        guard let session = draftSession else { return }
        guard !session.isNew, let current = slot(session.slot.id) else {
            draftSession = nil
            return
        }
        draftSession = SlotDraft(existing: current)
    }

    func endEditing() {
        draftSession = nil
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        var updated = schedule
        updated.slots.removeAll { $0.id == id }
        let previous = draftSession
        if draftSession?.slot.id == id { draftSession = nil }
        guard commit(updated) else {
            draftSession = previous
            return false
        }
        return true
    }

    // MARK: - Settings: launch at login

    /// Launch at login requires running inside an `.app` (`panelshot` is a bare binary).
    var canLaunchAtLogin: Bool { LaunchAtLogin.isAvailable }

    /// Whether the app is in Applications. Login items store the bundle's **path**, so moving
    /// must precede enabling launch at login. Explain this beside the onboarding toggle, not after it breaks.
    var runsFromApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// The app's enclosing folder (Downloads, Desktop, etc.), used to make the explanation above specific.
    var enclosingFolderName: String {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.displayName(atPath: parent.path)
    }

    /// Query system state once from settings' `onAppear`, not from body.
    func refreshSettings() {
        if canLaunchAtLogin {
            launchAtLogin = LaunchAtLogin.status
            // `.notFound` is not an error: never-registered apps, especially outside Applications,
            // have been observed to start in this state and still register successfully. Like
            // `.notRegistered`, it just means off; only disabling through System Settings warrants a notice.
            launchAtLoginNote = switch launchAtLogin {
            case .requiresApproval: L10n.t("model.launchAtLogin.requiresApproval")
            case .enabled, .notRegistered, .notFound: nil
            @unknown default: LaunchAtLogin.describe(launchAtLogin)
            }
        }
        agentInstalled = LaunchAgentInstaller.isLoaded
    }

    func setLaunchAtLogin(_ on: Bool) {
        var failure: String?
        do {
            try LaunchAtLogin.set(on)
        } catch {
            failure = L10n.t("model.launchAtLogin.failed", (error as NSError).localizedDescription)
        }
        // The system is authoritative: read back after registration, since a System Settings override may keep it off.
        // Write errors afterward; `refreshSettings` recalculates the note and would otherwise
        // erase the error, leaving the user's toggle action without feedback.
        refreshSettings()
        if let failure { launchAtLoginNote = failure }
    }

    func openLoginItemsSettings() { LaunchAtLogin.openSystemSettings() }

    // MARK: - Settings: language

    var languagePreference: L10n.Preference { L10n.storedPreference }

    /// Apply immediately. `L10n` handles persistence and notification; skip unchanged preferences
    /// here so selecting the current language does not rebuild the entire panel.
    func setLanguage(_ preference: L10n.Preference) {
        guard preference != L10n.storedPreference else { return }
        L10n.setPreference(preference)
    }

    /// Registration stores **this bundle's current path**. Every `build.sh` run removes and
    /// recreates `build/HourGlow.app`, leaving the login item pointing to a missing bundle; moving it does the same.
    /// Warn when running outside Applications: not an error, but an easily forgotten prerequisite.
    var launchAtLoginPathWarning: String? {
        guard canLaunchAtLogin, launchAtLogin == .enabled else { return nil }
        let path = Bundle.main.bundleURL.path
        guard !path.hasPrefix("/Applications/") else { return nil }
        return L10n.t("model.launchAtLogin.path", path)
    }

    /// Remove M2's LaunchAgent, now redundant with the app's launch-at-login support.
    /// Keeping it is harmless (`EngineLock` makes the later process a follower), but wastes a background process.
    func uninstallAgent() {
        // The one-line banner replaces earlier messages, so combine the explanation and result.
        let note = LaunchAgentInstaller.uninstall()
        show(note.map { L10n.t("model.agent.uninstalled.note", $0) }
             ?? L10n.t("model.agent.uninstalled"))
        refreshSettings()
        // Take over promptly if the removed agent was the leader. If bootout has not released
        // the lock yet, the 30-second ticker keeps trying rather than leaving this app a follower forever.
        promoteIfPossible()
    }

    // MARK: - Settings: updates

    var canUpdate: Bool { AppUpdater.isAvailable }
    var updateUnavailableReason: String? { AppUpdater.unavailabilityError?.localizedDescription }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var availableUpdate: AppRelease? {
        if case .available(let release) = updateState { return release }
        return nil
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        automaticUpdatesEnabled = enabled
        AppUpdater.automaticUpdatesEnabled = enabled
        // Check immediately when explicitly enabled, without waiting 24 hours after the last check.
        if enabled { checkForUpdates(manual: false, force: true) }
    }

    /// Manual checks ignore the 24-hour interval but honor server rate limits. Show discovered
    /// updates and wait for Update and Restart, rather than disappearing while the user reads settings.
    func checkForUpdates(manual: Bool = true, force: Bool = false) {
        if let reason = updateUnavailableReason {
            if manual { updateState = .failed(reason) }
            return
        }
        guard !updateState.isBusy else { return }
        guard manual || force || AppUpdater.shouldCheckAutomatically else { return }

        updateState = .checking
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { updateTask = nil }
            do {
                let release = try await AppUpdater.latestRelease(currentVersion: currentVersion)
                try Task.checkCancellation()
                AppUpdater.markChecked()
                guard let release else {
                    updateState = .upToDate(currentVersion)
                    return
                }
                updateState = .available(release)
                if automaticUpdatesEnabled && !manual {
                    try await downloadAndInstall(release)
                }
            } catch is CancellationError {
                updateState = .idle
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate, !updateState.isBusy else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { updateTask = nil }
            do {
                try await downloadAndInstall(release)
            } catch is CancellationError {
                updateState = .available(release)
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    func openReleasesPage() {
        let url = availableUpdate?.pageURL ?? AppUpdater.releasesPage
        NSWorkspace.shared.open(url)
    }

    private func downloadAndInstall(_ release: AppRelease) async throws {
        try AppUpdater.requireInstallableLocation()
        updateState = .downloading(release)
        let staged = try await AppUpdater.stage(release)
        try Task.checkCancellation()
        try AppUpdater.launchInstaller(stagedApp: staged)
        // The helper now runs independently and will not touch the bundle until this process actually exits.
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Settings: location

    enum LocatingState: Equatable {
        case idle
        case requesting
        /// Permission denied: manual coordinates are the only option, so the UI should prioritize them.
        case denied
        case failed(String)
    }

    /// Coordinate source precedence: manual entry / location request, then time-zone inference, then none.
    var coordinateSource: String {
        if let location = schedule.location {
            if let name = location.name, !name.isEmpty { return name }
            return L10n.t("model.place.manual")
        }
        return schedule.effectiveCoordinate == nil
            ? L10n.t("common.none")
            : L10n.t("model.place.fromTimeZone", TimeZone.current.identifier)
    }

    /// The location page header: the name if available, otherwise coordinates or time zone.
    var placeLabel: String {
        if let location = schedule.location {
            if let name = location.name, !name.isEmpty { return name }
            return String(format: "%.4f, %.4f", location.latitude, location.longitude)
        }
        if schedule.effectiveCoordinate != nil {
            return L10n.t("model.place.followTimeZone", TimeZone.current.identifier)
        }
        return L10n.t("model.place.none")
    }

    /// The chip at the timeline's top right: keep it short and truncate if needed.
    var placeChipLabel: String {
        if let name = schedule.location?.name, !name.isEmpty { return name }
        if schedule.location != nil { return L10n.t("model.place.chip.custom") }
        if schedule.effectiveCoordinate != nil { return L10n.t("model.place.chip.timeZone") }
        return L10n.t("model.place.chip.choose")
    }

    /// Today's sunrise and sunset let locals recognize whether the settings coordinates are correct.
    var solarToday: (sunrise: Date, sunset: Date)? {
        guard let coordinate = schedule.effectiveCoordinate else { return nil }
        return Solar.times(on: AppModel.now(), at: coordinate)
    }

    var solarEventsToday: Solar.Events? {
        guard let coordinate = schedule.effectiveCoordinate else { return nil }
        return Solar.events(on: AppModel.now(), at: coordinate)
    }

    /// Request coordinates once from the system, then save them instead of relying on time-zone inference.
    func requestPreciseLocation() {
        guard locating != .requesting else { return }
        locating = .requesting
        PreciseLocation.shared.request { outcome in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                switch outcome {
                case .coordinate(let coordinate):
                    model.locating = .idle
                    // Save the precise coordinates first. Reverse lookup only provides a readable name;
                    // do not replace them with an administrative center, which may be tens of kilometers
                    // away in a large city. That precision is what the location permission granted us.
                    model.setManualLocation(coordinate)
                    model.show(L10n.t("model.located",
                                      coordinate.latitude, coordinate.longitude))
                    Task { @MainActor [weak model] in
                        let loc = CLLocation(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude)
                        guard let city = await PlaceSearch.reverse(loc), let model else { return }
                        // The user may have chosen another place meanwhile; do not overwrite that choice.
                        guard model.schedule.location?.latitude == coordinate.latitude,
                              model.schedule.location?.longitude == coordinate.longitude else { return }
                        var named = coordinate
                        named.name = city.name
                        model.setManualLocation(named)
                        model.show(L10n.t("model.located.named", city.name))
                    }
                case .denied:
                    model.locating = .denied
                case .failed(let reason):
                    model.locating = .failed(reason)
                }
            }
        }
    }

    /// Set explicit coordinates; nil clears them and restores time-zone inference.
    @discardableResult
    func setManualLocation(_ coordinate: Coordinate?) -> Bool {
        var updated = schedule
        updated.location = coordinate
        return commit(updated)
    }

    @discardableResult
    func setPlace(_ city: City) -> Bool {
        setManualLocation(city.asCoordinate)
    }

    // MARK: - Import

    /// Replace the current timeline with a set of images.
    ///
    /// The menu bar panel closes on losing focus: calling `runModal` immediately from the ⋯ menu
    /// cancels the dialog too, making import appear broken. Wait for the UI to settle and temporarily
    /// use regular app activation so importing folders, image sets, or `.sundialScene` files works.
    func importSceneFromPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AppModel.shared.presentImportPanel()
        }
    }

    func importScene(from url: URL) {
        importScene(from: [url])
    }

    /// Import replaces the entire timeline without undo. Copy assets in the background: a 24HW
    /// set can be hundreds of MB, and copying on the main thread would freeze the menu bar app.
    func importScene(from urls: [URL]) {
        guard !importingScene else {
            show(L10n.t("import.busy"))
            return
        }
        endEditing()
        guard confirmReplace() else { return }
        importingScene = true
        let current = schedule
        Task {
            defer { importingScene = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try SceneImport.apply(urls: urls, to: current)
                }.value
                // Another process may change location or pause state during copying. Import only replaces
                // the timeline, so merge new slots into the latest configuration rather than restoring the initial snapshot.
                var updated = schedule
                updated.slots = outcome.schedule.slots
                guard commit(updated) else {
                    await Task.detached(priority: .utility) { SceneImport.discard(outcome) }.value
                    return
                }
                // Old assets become unreferenced only after saving succeeds. Cleanup may span hundreds of MB; keep it off the main thread.
                await Task.detached(priority: .utility) { SceneImport.finalize(outcome) }.value
                let imported = updated.slots.count
                var text = L10n.t(count: imported, "import.done.detail", imported)
                if !outcome.skipped.isEmpty {
                    let skipped = outcome.skipped.count
                    text += "\n" + L10n.t(count: skipped, "import.skipped.detail", skipped)
                    text += "\n" + outcome.skipped.prefix(6).map(\.lastPathComponent)
                        .joined(separator: L10n.t("list.separator"))
                    if skipped > 6 { text += " …" }
                }
                show(L10n.t(count: imported, "import.done", imported)
                     + (outcome.skipped.isEmpty
                        ? ""
                        : L10n.t(count: outcome.skipped.count, "import.skipped.suffix",
                                 outcome.skipped.count)))
                announceImport(success: true, text: text)
            } catch {
                show(L10n.t("import.failed", error.localizedDescription))
                announceImport(success: false, text: error.localizedDescription)
            }
        }
    }

    /// Ask before replacing the whole timeline. The panel has already closed, so use a dialog.
    private func confirmReplace() -> Bool {
        guard !schedule.slots.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.t("import.replace.title")
        alert.informativeText = L10n.t(count: schedule.slots.count, "import.replace.body",
                                       schedule.slots.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("import.replace.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentImportPanel() {
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previous) }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        var types: [UTType] = [.folder, .image]
        if let scene = UTType(filenameExtension: "sundialScene") {
            types.append(scene)
        }
        panel.allowedContentTypes = types
        panel.prompt = L10n.t("import.open.prompt")
        panel.message = L10n.t("import.open.message")

        guard panel.runModal() == .OK else { return }
        importScene(from: panel.urls)
    }

    /// The panel and its banner are hidden now; explain the result in a dialog.
    private func announceImport(success: Bool, text: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(success ? "import.result.ok" : "import.result.failed")
        alert.informativeText = text
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: L10n.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Actions

    func setPaused(_ paused: Bool) {
        if isFollower {
            var updated = schedule
            updated.paused = paused
            guard commit(updated) else { return }
            // Resume expresses explicit user intent: correct immediately despite intervening manual changes.
            // The leader's configuration-change evaluation is not assertive, so perform that correction here.
            if !paused { oneShot(reason: .resume) }
        } else {
            do {
                try paused ? scheduler.pause() : scheduler.resume()
            } catch {
                show(L10n.t("model.saveFailed", error.localizedDescription))
            }
        }
        refresh()
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
    }

    // MARK: - Internals

    /// Persist changes. Editing keeps drafts in memory; only Apply reaches this method.
    @discardableResult
    private func commit(_ updated: Schedule) -> Bool {
        guard !awaitingReadableConfig else {
            show(L10n.t("model.startup.configFailed"))
            return false
        }
        do {
            if isFollower {
                // Saving is enough; the leader's ConfigWatcher will evaluate the change.
                try Store.save(updated)
            } else {
                try scheduler.update(schedule: updated)
            }
        } catch {
            show(L10n.t("model.saveFailed", error.localizedDescription))
            return false
        }
        // Like the engine, persist before committing in memory, so failure never shows a configuration absent from disk.
        schedule = updated
        resolution = updated.resolve(at: AppModel.now())
        refresh()
        return true
    }

    /// One-shot evaluation in follower mode. `state.json` is authoritative, so a temporary
    /// `Scheduler` can safely use the same decision logic, just as the CLI's `resume` does.
    private func oneShot(reason: Scheduler.Reason) {
        let scheduler = Scheduler(schedule: schedule)
        scheduler.onLog = { line in
            MainActor.assumeIsolated { AppModel.shared.show(line) }
        }
        scheduler.evaluate(reason: reason)
    }

    private func absorbFromScheduler() {
        replaceSchedule(scheduler.schedule)
        resolution = scheduler.lastResolution
        refresh()
    }

    private func reloadFromDisk() {
        guard let reloaded = try? Store.load() else { return }
        replaceSchedule(reloaded)
        refresh()
    }

    /// Followers must take over when the other engine exits. Otherwise an app launched after
    /// the CLI/LaunchAgent stays a follower forever after that leader exits or is uninstalled, leaving no scheduler.
    private func promoteIfPossible() {
        guard isFollower, let acquired = EngineLock.acquire() else { return }
        guard let latest = try? Store.load() else {
            acquired.release()
            show(L10n.t("model.promote.configFailed"))
            return
        }

        watcher?.stop()
        watcher = nil
        lock = acquired
        isFollower = false
        updateRefreshTimer()
        replaceSchedule(latest)
        scheduler.start(schedule: latest)
        show(L10n.t("model.promote.tookOver"))
    }

    private func replaceSchedule(_ updated: Schedule) {
        awaitingReadableConfig = false
        if var session = draftSession {
            let current = updated.slots.first { $0.id == session.slot.id }
            session.reconcile(with: current)
            draftSession = session
        }
        schedule = updated
    }

    private func refresh() {
        resolution = schedule.resolve(at: AppModel.now())
        actual = try? WallpaperWriter.current()
        lastWritten = EngineState.load().lastWritten
    }

    private func show(_ line: String) {
        message = line
        messageExpiry?.cancel()
        let expiry = DispatchWorkItem {
            MainActor.assumeIsolated { AppModel.shared.message = nil }
        }
        messageExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: expiry)
    }
}
