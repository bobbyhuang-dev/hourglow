import AppKit
import Observation

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

    // MARK: - 展示状态

    private(set) var schedule: Schedule
    /// 当前应生效的时段与下一次切换。每 30 秒、每次求值后刷新。
    private(set) var resolution: Resolution?
    /// 系统里此刻实际挂着的那张。
    private(set) var actual: Wallpaper?
    /// 引擎上次写下去的那张 —— 与 `actual` 不一致就说明用户中途手动换过。
    private(set) var lastWritten: Wallpaper?
    /// 最近一条引擎日志，显示几秒后自行消失。
    private(set) var message: String?

    let catalog: [AerialAsset]
    let isFollower: Bool

    private let assetNames: [String: String]
    private let scheduler: Scheduler
    private let lock: EngineLock?
    private var watcher: ConfigWatcher?
    private var ticker: Timer?
    private var pendingCommit: DispatchWorkItem?
    private var messageExpiry: DispatchWorkItem?

    /// 时间选择器一拖就是几十次变更。落盘（进而可能触发写壁纸）要等手停下来。
    private let commitDelay: TimeInterval = 0.35

    private init() {
        catalog = (try? AerialCatalog.load()) ?? []
        assetNames = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        let loaded = (try? Store.load()) ?? Tahoe.preset
        schedule = loaded
        // 面板可能比 start() 先被打开，先把当前时段算出来，别闪一下「没有生效的时段」。
        resolution = loaded.resolve()
        lock = EngineLock.acquire()
        isFollower = lock == nil
        scheduler = Scheduler(schedule: loaded)
    }

    // MARK: - 生命周期

    func start() {
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

        refresh()

        // 面板里的「现在 / 下次」是随时间走的，定期重算一遍。求值是纯计算，很便宜。
        let ticker = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.refresh() }
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
        case .aerial(let id): return assetNames[id] ?? "未知壁纸"
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
        let now = Date()
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

    /// 当前壁纸不是引擎写下去的那张 —— 用户自己换过，下一个触发点才会接管。
    var isManuallyOverridden: Bool {
        guard let lastWritten, let actual else { return false }
        return WallpaperWriter.normalized(actual) != WallpaperWriter.normalized(lastWritten)
    }

    /// 有 solar 时段却没有坐标，这些段会被整个跳过，得说一声。
    var needsCoordinate: Bool {
        schedule.effectiveCoordinate == nil
            && schedule.slots.contains { if case .solar = $0.trigger { return $0.enabled } else { return false } }
    }

    // MARK: - 编辑

    /// `debounced` 用于连续变化的控件（时刻、偏移分钟）：界面立刻跟手，落盘等手停。
    func update(_ slot: Slot, debounced: Bool = false) {
        guard let index = schedule.slots.firstIndex(where: { $0.id == slot.id }) else { return }
        var updated = schedule
        updated.slots[index] = slot
        commit(updated, debounced: debounced)
    }

    /// 新时段默认接着当前这一段：同一张壁纸、下一个整点。改哪一项都行，先给个能用的。
    @discardableResult
    func addSlot() -> UUID {
        let wallpaper = resolution?.active.wallpaper
            ?? catalog.first.map { Wallpaper.aerial(assetID: $0.id) }
            ?? .aerial(assetID: Tahoe.day)
        let hour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        let slot = Slot(trigger: .clock(hour: hour, minute: 0), wallpaper: wallpaper)

        var updated = schedule
        updated.slots.append(slot)
        commit(updated)
        return slot.id
    }

    func delete(_ id: UUID) {
        var updated = schedule
        updated.slots.removeAll { $0.id == id }
        commit(updated)
    }

    // MARK: - 操作

    func setPaused(_ paused: Bool) {
        flushPendingCommit()
        if isFollower {
            var updated = schedule
            updated.paused = paused
            commit(updated)
            // 恢复是明确的用户意图：无视中途的手动改动立刻校正。
            // 对方收到配置变更时的求值不是 assertive 的，得由这里补上。
            if !paused { oneShot(reason: .resume) }
        } else {
            do {
                try paused ? scheduler.pause() : scheduler.resume()
            } catch {
                show("保存失败: \(error)")
            }
        }
        refresh()
    }

    func applyNow() {
        flushPendingCommit()
        if isFollower {
            oneShot(reason: .manual)
        } else {
            scheduler.applyNow()
        }
        refresh()
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
    }

    // MARK: - 内部

    private func commit(_ updated: Schedule, debounced: Bool = false) {
        // 先更新内存，界面立刻跟手；落盘可以慢一拍。
        schedule = updated
        resolution = updated.resolve()

        pendingCommit?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { AppModel.shared.persist(updated) }
        }
        pendingCommit = work
        if debounced {
            DispatchQueue.main.asyncAfter(deadline: .now() + commitDelay, execute: work)
        } else {
            work.perform()
        }
    }

    private func persist(_ updated: Schedule) {
        pendingCommit = nil
        do {
            if isFollower {
                // 存下去就够了，对方的 ConfigWatcher 会接着求值。
                try Store.save(updated)
            } else {
                try scheduler.update(schedule: updated)
            }
        } catch {
            show("保存失败: \(error)")
        }
        refresh()
    }

    /// 有未落盘的编辑时先落下去，再执行会读配置的操作。
    private func flushPendingCommit() {
        guard let pending = pendingCommit else { return }
        pending.cancel()
        pendingCommit = nil
        pending.perform()
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
        schedule = scheduler.schedule
        resolution = scheduler.lastResolution
        refresh()
    }

    private func reloadFromDisk() {
        guard let reloaded = try? Store.load() else { return }
        schedule = reloaded
        refresh()
    }

    private func refresh() {
        resolution = schedule.resolve()
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
