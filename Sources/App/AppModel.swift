import AppKit
import CoreLocation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

/// UI 与引擎之间唯一的一层。
///
/// 视图只读这里的展示状态、只调这里的方法；求值与写入仍然全在 `Scheduler` 里，
/// M3 没有为 UI 复制一份调度逻辑。
///
/// ## 领跑 / 从属
///
/// 后台可能已经有一个 `hourglow-cli run`（或 M2 装的 LaunchAgent）在排程。
/// 两个引擎同时跑会互相把对方的写入当成「用户手动改的」，所以启动时先抢
/// `EngineLock`：
///
/// - **领跑**（抢到锁）：本进程起 `Scheduler`，定时器与系统事件都归它。
/// - **从属**（没抢到）：不排程，只编辑 `schedule.json`，由对方的 `ConfigWatcher`
///   跟上；面板顶部会说明现在是谁在管。
@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    /// 面板上一切「现在」都从这里取，不直接 `Date()`。
    ///
    /// 只有 `panelshot --now` 会改它：演示图与截图要把时间轴定格在一天里的某一刻
    /// （哪一段在跑、下一次几点换）。app 与 CLI 从不碰它，永远是真实时钟。
    /// `nonisolated(unsafe)`：`Clock.remaining` 不在 main actor 上，而这个值只在
    /// 进程启动、任何视图出现之前被赋一次。
    nonisolated(unsafe) static var now: () -> Date = { Date() }

    // MARK: - 展示状态

    private(set) var schedule: Schedule
    /// Current and next slots; refreshed on engine events and every 30 seconds while visible.
    private(set) var resolution: Resolution?
    /// 系统里此刻实际挂着的那张。
    private(set) var actual: Wallpaper?
    /// 引擎上次写下去的那张 —— 与 `actual` 不一致就说明用户中途手动换过。
    private(set) var lastWritten: Wallpaper?
    /// 最近一条引擎日志，显示几秒后自行消失。
    private(set) var message: String?

    let catalog: [AerialAsset]
    private(set) var isFollower: Bool

    /// 开机自启与 LaunchAgent 的现状。两者都要问系统（`SMAppService` 是同步 IPC、
    /// LaunchAgent 更是要 fork 一个 `launchctl`），所以只在设置页出现时刷一次，
    /// 不放进视图的 body 里每次重绘都问一遍。
    private(set) var launchAtLogin = SMAppService.Status.notRegistered
    private(set) var agentInstalled = false
    /// 开机自启那一栏的补充说明（被系统设置关掉了、bundle 不在原位、注册报错）。
    private(set) var launchAtLoginNote: String?
    private(set) var locating = LocatingState.idle

    /// 语言换了就 +1。`PanelRoot` 拿它当 `.id`，整棵面板重建一次。
    ///
    /// 文案是各视图在自己的 body 里查表拿到的，不经过任何 `@Observable` 属性 ——
    /// 换句话说 SwiftUI 追不到「语言变了」这件事，得由这个计数器替它说一声。
    private(set) var languageGeneration = 0

    /// 更新与壁纸调度彼此独立；这里仅保存设置页要展示的状态。
    private(set) var updateState = AppUpdateState.idle
    private(set) var automaticUpdatesEnabled = AppUpdater.automaticUpdatesEnabled
    private(set) var importingScene = false

    /// 正在编辑的那个时段。改动先落在这里，点「应用」才写进 `schedule`。
    ///
    /// 草稿放在这里而不是 `SlotPage` 的 `@State` 里：选壁纸是另一页，SlotPage 会被
    /// 卸下来重建，草稿得比页面活得久。面板一失焦就收起，草稿也得比面板活得久 ——
    /// 「选本地图片」会弹系统对话框，那一下必定把面板关掉。
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
        // 必须赶在 `Store.load()` 之前问一次「配置文件在不在」—— 那个调用会顺手
        // 把 Tahoe 预设写下去，之后再问就永远是「在」，新手指引也就永远弹不出来。
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
            // 配置损坏不是首次安装，不能用预设接管用户壁纸，也不能让设置动作覆盖坏文件。
            // 借从属模式的监听与定期接管重试，等用户修好原文件再启动排程。
            loaded = Schedule()
            loadFailed = true
        }
        awaitingReadableConfig = loadFailed
        schedule = loaded
        // 面板可能比 start() 先被打开，先把当前时段算出来，别闪一下「没有生效的时段」。
        resolution = loaded.resolve(at: AppModel.now())
        let acquiredLock = loadFailed ? nil : EngineLock.acquire()
        lock = acquiredLock
        isFollower = acquiredLock == nil
        scheduler = Scheduler(schedule: loaded)
    }

    // MARK: - 生命周期

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
            // 别人在排程，我们只需要知道配置被改成了什么样。
            let watcher = ConfigWatcher(fileURL: Store.fileURL) {
                MainActor.assumeIsolated { AppModel.shared.reloadFromDisk() }
            }
            watcher.start()
            self.watcher = watcher
        } else {
            scheduler.start()
        }

        // 语言是从设置页改的，但改完之后整块面板都要跟着换 —— 谁改的不重要，
        // 只认「变了」这件事本身。
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.languageGeneration += 1 }
            }

        refresh()

        updateRefreshTimer()

        // App 通常一跑就是很多天，不能只在启动那一刻检查。每小时醒一次很便宜，
        // AppUpdater 里的 24 小时间隔才是实际的联网频率。
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

    // MARK: - 查询

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

    /// 时间轴的一行：时段 + 它今天的实际触发时刻。
    struct Entry: Identifiable {
        let slot: Slot
        /// solar 触发在缺坐标或极昼极夜时算不出来。
        let time: Date?
        var id: UUID { slot.id }
    }

    /// 按今天的实际时刻排序 —— 「日落前 30 分」排在哪里随季节变，这正是时间轴该有的样子。
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

    /// 面板顶上那张大图，是不是系统里此刻真挂着的那张。
    ///
    /// 不比 `lastWritten` 而直接比 `resolution.active`：引擎还没写过任何东西时
    /// （首次运行、刚清过 `state.json`）`isManuallyOverridden` 恒为假，但那张图
    /// 仍然只是「排程算出来的」，不能对用户说这就是目前的壁纸。
    var activeIsActual: Bool {
        guard let actual, let active = resolution?.active.wallpaper else { return false }
        return WallpaperWriter.normalized(actual) == WallpaperWriter.normalized(active)
    }

    /// 当前壁纸不是引擎写下去的那张 —— 用户自己换过，下一个触发点才会接管。
    var isManuallyOverridden: Bool {
        guard let lastWritten, let actual else { return false }
        return WallpaperWriter.normalized(actual) != WallpaperWriter.normalized(lastWritten)
    }

    /// 有 solar 时段却没有坐标，这些段会被整个跳过，得说一声。
    var needsCoordinate: Bool {
        schedule.effectiveCoordinate == nil
            && schedule.slots.contains { $0.enabled && $0.trigger.dependsOnSun }
    }

    /// 坐标有、但今天算不出日出日落（极圈的极昼极夜）。
    ///
    /// 导入一套壁纸后整张表都是天光分段，这时一段都排不上，壁纸会一动不动地
    /// 停几个星期。`needsCoordinate` 盖不住它 —— 坐标是有的，是太阳不配合。
    var solarUnavailable: Bool {
        guard let coordinate = schedule.effectiveCoordinate else { return false }
        guard schedule.slots.contains(where: { $0.enabled && $0.trigger.dependsOnSun }) else {
            return false
        }
        return Solar.events(on: AppModel.now(), at: coordinate) == nil
    }

    // MARK: - 编辑（草稿）

    /// 时段页要显示的那一段：正在编辑就用草稿，否则用配置里的。
    func editing(_ id: UUID) -> Slot? {
        draftSession?.slot.id == id ? draftSession?.slot : slot(id)
    }

    /// 草稿还没进过配置 —— 是「添加时段」新起的那一份。
    var draftIsNew: Bool {
        draftSession?.isNew ?? false
    }

    /// 有没有未应用的改动。新时段恒为真（配置里那份是 nil）。
    var draftIsDirty: Bool {
        draftSession?.isDirty ?? false
    }

    var draftHasConflict: Bool { draftSession?.conflict != nil }

    var draftCanApply: Bool { draftSession?.canApply ?? false }

    var draftCanDiscard: Bool { draftIsDirty || draftHasConflict }

    /// 新时段不在配置里也能继续编辑；已有时段若被别处删除，就不能借草稿把它复活。
    func canContinueEditing(_ id: UUID) -> Bool {
        guard let session = draftSession, session.slot.id == id else { return slot(id) != nil }
        return session.isNew || session.conflict != .deleted
    }

    func beginEditing(_ id: UUID) {
        // 从选壁纸页返回时还会再走一次，别把半路的改动冲掉。
        guard draftSession?.slot.id != id else { return }
        draftSession = slot(id).map(SlotDraft.init(existing:))
    }

    /// 改草稿。界面立刻跟手，但配置与壁纸都还没动。
    func editDraft(_ transform: (inout Slot) -> Void) {
        draftSession?.edit(transform)
    }

    /// 新时段默认接着当前这一段：同一张壁纸、下一个整点。改哪一项都行，先给个能用的。
    /// 只是一份草稿 —— 点「添加」才会进配置。
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

    /// 点「应用 / 添加」：这是配置唯一会因为编辑而改变的入口。
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
        // 先把会话标成已应用，让领跑模式同步回调时不会把自己的写入误判成外部冲突；
        // 保存失败则恢复，页面仍保留未应用的改动。
        let previous = session
        session.markApplied()
        draftSession = session
        guard commit(updated) else {
            draftSession = previous
            return false
        }
        return true
    }

    /// 把草稿退回配置里那一份。新时段没有「那一份」，直接丢掉。
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

    // MARK: - 设置：开机自启

    /// 只有从 `.app` 里跑起来才谈得上「开机自启」（`panelshot` 是裸二进制）。
    var canLaunchAtLogin: Bool { LaunchAtLogin.isAvailable }

    /// 在不在「应用程序」里。登录项记的是 bundle 的**路径**，所以「先搬家、再开自启」
    /// 是有先后的 —— 新手指引要在开关旁边先说这一句，别等自启失效了再解释。
    var runsFromApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// app 现在待的那个文件夹叫什么（「下载」「桌面」…）。只用来把上面那句话说具体。
    var enclosingFolderName: String {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.displayName(atPath: parent.path)
    }

    /// 读一次系统状态。设置页 `onAppear` 调，别在 body 里问。
    func refreshSettings() {
        if canLaunchAtLogin {
            launchAtLogin = LaunchAtLogin.status
            // `.notFound` 不是错：实测从来没注册过的 app（尤其不在「应用程序」里的）
            // 一上来就是这个状态，照样能注册成功。所以它与 `.notRegistered` 一样，
            // 只表示「没开」，不该在界面上报警。真正要说的只有被系统设置关掉那一种。
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
        // 系统说了算：注册完再读回来，被用户在系统设置里关过的话这里仍然是关着的。
        // 报错要在这之后再写回去 —— `refreshSettings` 会按状态重算这行说明，
        // 先写就被它抹掉了，用户点一下开关什么反馈都没有。
        refreshSettings()
        if let failure { launchAtLoginNote = failure }
    }

    func openLoginItemsSettings() { LaunchAtLogin.openSystemSettings() }

    // MARK: - 设置：语言

    var languagePreference: L10n.Preference { L10n.storedPreference }

    /// 即时生效。写盘与广播都在 `L10n` 里，这里只负责把「没变」挡掉，
    /// 免得点回原来那一项也让面板整个重建一次。
    func setLanguage(_ preference: L10n.Preference) {
        guard preference != L10n.storedPreference else { return }
        L10n.setPreference(preference)
    }

    /// 注册的是**当前这个 bundle 的路径**。`build.sh` 每次都 `rm -rf` 重建
    /// `build/HourGlow.app`，登录项就此指向一个不存在的 bundle；把 app 挪个地方也一样。
    /// 所以不在「应用程序」里跑的时候要说一声 —— 这不是错误，是个容易忘的前提。
    var launchAtLoginPathWarning: String? {
        guard canLaunchAtLogin, launchAtLogin == .enabled else { return nil }
        let path = Bundle.main.bundleURL.path
        guard !path.hasPrefix("/Applications/") else { return nil }
        return L10n.t("model.launchAtLogin.path", path)
    }

    /// 卸掉 M2 那条 LaunchAgent。app 自己会开机自启之后它就是多余的一份 ——
    /// 留着不会出错（`EngineLock` 会让后起的那个退成从属），但白占一个后台进程。
    func uninstallAgent() {
        // 提示条只有一行、后来的会顶掉先来的，所以说明和结果拼成一句再显示。
        let note = LaunchAgentInstaller.uninstall()
        show(note.map { L10n.t("model.agent.uninstalled.note", $0) }
             ?? L10n.t("model.agent.uninstalled"))
        refreshSettings()
        // 如果被卸掉的正是当前领跑者，尽快接班；bootout 尚未释放锁时，30 秒 ticker
        // 还会继续尝试，不会让这个 app 永久停在从属模式。
        promoteIfPossible()
    }

    // MARK: - 设置：更新

    var canUpdate: Bool { AppUpdater.isAvailable }

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
        // 用户刚明确打开时立即检查，不必等上一次检查满 24 小时。
        if enabled { checkForUpdates(manual: false, force: true) }
    }

    /// 手动检查总是联网；自动检查由 24 小时间隔限流。手动检查即使发现新版也先展示，
    /// 等用户点「更新并重启」，避免他正在看设置页时 app 突然消失。
    func checkForUpdates(manual: Bool = true, force: Bool = false) {
        guard canUpdate else {
            if manual { updateState = .failed(L10n.t("update.error.notApp")) }
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
        // helper 已经独立运行；只有当前进程真正退出以后，它才会动 bundle。
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 设置：位置

    enum LocatingState: Equatable {
        case idle
        case requesting
        /// 权限被拒。手填经纬度是唯一的出路，UI 要把它顶到前面。
        case denied
        case failed(String)
    }

    /// 坐标从哪来的。三条路：手填/定位写下的 > 时区推断 > 没有。
    var coordinateSource: String {
        if let location = schedule.location {
            if let name = location.name, !name.isEmpty { return name }
            return L10n.t("model.place.manual")
        }
        return schedule.effectiveCoordinate == nil
            ? L10n.t("common.none")
            : L10n.t("model.place.fromTimeZone", TimeZone.current.identifier)
    }

    /// 地点页顶上那一行：有名字用名字，否则是坐标或时区。
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

    /// 时间轴右上角那颗胶囊：尽量短，满了就截。
    var placeChipLabel: String {
        if let name = schedule.location?.name, !name.isEmpty { return name }
        if schedule.location != nil { return L10n.t("model.place.chip.custom") }
        if schedule.effectiveCoordinate != nil { return L10n.t("model.place.chip.timeZone") }
        return L10n.t("model.place.chip.choose")
    }

    /// 今天的日出日落。设置页用它证明坐标是对的 —— 数字对不对，本地人一眼就知道。
    var solarToday: (sunrise: Date, sunset: Date)? {
        guard let coordinate = schedule.effectiveCoordinate else { return nil }
        return Solar.times(on: AppModel.now(), at: coordinate)
    }

    var solarEventsToday: Solar.Events? {
        guard let coordinate = schedule.effectiveCoordinate else { return nil }
        return Solar.events(on: AppModel.now(), at: coordinate)
    }

    /// 向系统要一次坐标。拿到就写进配置，从此不再依赖时区推断。
    func requestPreciseLocation() {
        guard locating != .requesting else { return }
        locating = .requesting
        PreciseLocation.shared.request { outcome in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                switch outcome {
                case .coordinate(let coordinate):
                    model.locating = .idle
                    // 先把刚拿到的精确坐标写下去。反查只是为了给它起个看得懂的名字，
                    // 不能拿反查回来的行政区中心点替换掉它 —— 大城市能差几十公里，
                    // 而一次定位授权换来的就是这几十公里的精度。
                    model.setManualLocation(coordinate)
                    model.show(L10n.t("model.located",
                                      coordinate.latitude, coordinate.longitude))
                    Task { @MainActor [weak model] in
                        let loc = CLLocation(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude)
                        guard let city = await PlaceSearch.reverse(loc), let model else { return }
                        // 期间用户可能又选了别的地方，别把人家的选择盖回去。
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

    /// 写死一个坐标；传 nil 表示清掉，回退到时区推断。
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

    // MARK: - 导入

    /// 用一组图片替换当前时间轴。
    ///
    /// 菜单栏面板一失焦就收起：从 ⋯ 菜单里立刻 `runModal`，对话框会被一起取消，
    /// 看起来像「不能导入」。等这一轮 UI 收完、临时把 app 变成普通前台，
    /// 选文件夹、一组图片或 `.sundialScene` 都能点「导入」。
    func importSceneFromPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AppModel.shared.presentImportPanel()
        }
    }

    func importScene(from url: URL) {
        importScene(from: [url])
    }

    /// 导入会整体替换时间轴，而且没有撤销。素材拷贝放到后台：24HW 一套几百 MB，
    /// 在主线程上拷会把菜单栏 app 卡住。
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
                // 拷贝期间位置或暂停状态可能被另一个进程改过。导入只承诺替换时间轴，
                // 因此把新 slots 合到此刻最新的配置里，不能拿任务开始前的整份快照覆盖回来。
                var updated = schedule
                updated.slots = outcome.schedule.slots
                guard commit(updated) else {
                    await Task.detached(priority: .utility) { SceneImport.discard(outcome) }.value
                    return
                }
                // 只有配置成功落盘后旧素材才不再被引用。清理可能涉及几百 MB，留在后台做。
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

    /// 时间轴是整体替换的，问一句再动。面板此时已经收起，只能用对话框。
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

    /// 面板此时已经收起，提示条看不见，用对话框把结果说清楚。
    private func announceImport(success: Bool, text: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(success ? "import.result.ok" : "import.result.failed")
        alert.informativeText = text
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: L10n.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 操作

    func setPaused(_ paused: Bool) {
        if isFollower {
            var updated = schedule
            updated.paused = paused
            guard commit(updated) else { return }
            // 恢复是明确的用户意图：无视中途的手动改动立刻校正。
            // 对方收到配置变更时的求值不是 assertive 的，得由这里补上。
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

    // MARK: - 内部

    /// 落盘。编辑期间不会走到这里 —— 草稿只在内存里，点「应用」才调过来。
    @discardableResult
    private func commit(_ updated: Schedule) -> Bool {
        guard !awaitingReadableConfig else {
            show(L10n.t("model.startup.configFailed"))
            return false
        }
        do {
            if isFollower {
                // 存下去就够了，对方的 ConfigWatcher 会接着求值。
                try Store.save(updated)
            } else {
                try scheduler.update(schedule: updated)
            }
        } catch {
            show(L10n.t("model.saveFailed", error.localizedDescription))
            return false
        }
        // 引擎也是先落盘再提交内存；UI 遵守同一个顺序，失败时不会显示一份磁盘上不存在的配置。
        schedule = updated
        resolution = updated.resolve(at: AppModel.now())
        refresh()
        return true
    }

    /// 从属模式下的一次性求值。`state.json` 才是权威，所以借一个临时 `Scheduler`
    /// 走同一套决策逻辑是安全的 —— CLI 的 `resume` 也是这么干的。
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

    /// 另一个引擎退出后从属者必须能接班。否则 app 在 CLI/LaunchAgent 之后启动，
    /// 后者再被用户卸载或退出时，菜单栏仍会永远显示“从属”，实际上已经没人排程。
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
