import Foundation
import AppKit

/// 调度引擎：在正确的时刻把正确的壁纸写进系统。
///
/// ## 不轮询
///
/// 定时器直接排到下一个触发时刻，中间什么都不做。真实世界里会打乱这个安排的事件
/// 有四类，各自订阅，不靠每分钟醒来一次去发现：
///
/// - 睡眠唤醒 —— `NSWorkspace.didWakeNotification`。睡过头的定时器醒来后会立刻补跑，
///   两条路都能触发补切，互为冗余。
/// - 系统时钟被改（对时、手动调整）—— `NSSystemClockDidChange`
/// - 时区变更、夏令时切换 —— `NSSystemTimeZoneDidChange`，收到后要
///   `NSTimeZone.resetSystemTimeZone()`，否则 `TimeZone.current` 拿到的还是旧值
/// - 跨日 —— `NSCalendarDayChanged`，日出日落每天都不一样
///
/// 另外还有一层安全网：定时器最长只睡 `maxSleep`。丢一个通知不至于让引擎永久失灵。
///
/// ## 用户手动改了壁纸怎么办
///
/// `MVP` 里列的三种语义，最后落在 a 与 c 的组合上 —— 单取哪一种都不对：
///
/// - 纯 a（下次触发照常覆盖）：合盖睡一小时，醒来还在同一个时段内，
///   我们却会拿同一张壁纸把用户十分钟前的手动选择盖掉。这纯属添乱。
/// - 纯 c（当前壁纸不是我们写的那张就永不覆盖）：用户手动换过一次之后，
///   自动切换就此彻底失效，除非他手动换回我们写的那张。
///   这跟 TODO 里「不需要用户额外点任何东西」的初衷正好相反。
///
/// 所以按「是否跨过了新的触发边界」分开处理：
///
/// - **跨过了**（到点了、睡过了某个触发时刻、暂停后恢复）：照常写。
///   手动选择的有效期到下一个排定的切换为止 —— 跟空调的「临时保持」一个意思。
/// - **没跨过**（启动、唤醒、时区变更等原地重新求值）：只有当前壁纸确实是我们
///   上次写的那张时才写；否则说明用户中途换过，让位给他。
///
/// 判据是 `EngineState.lastFiredAt` 与本次 `Resolution.since` 的先后。
final class Scheduler {

    /// 本次求值是被什么触发的。只影响日志与「是否强制写入」。
    enum Reason: String {
        case launch, timer, wake, clockChange, timeZoneChange, dayChange
        case configChange, pause, resume, manual

        var label: String { L10n.t("engine.reason.\(rawValue)") }

        /// 这些触发源代表用户的明确意图，无条件覆盖。
        var isAssertive: Bool { self == .resume || self == .manual }
    }

    /// 一次求值的结果。
    enum Outcome {
        /// 写入成功。
        case applied(Slot)
        /// 目标与当前一致，跳过写入（不闪屏）。
        case unchanged(Slot)
        /// 用户手动换过壁纸，且没有跨过新的触发边界 —— 让位。
        case deferredToManual(Slot, actual: Wallpaper?)
        /// 全局暂停中。
        case paused
        /// 求不出值：没有启用的时段，或 solar 触发缺坐标 / 遇上极昼极夜。
        case unresolvable
        case failed(Error)
    }

    // MARK: - 可观察状态

    /// 日志回调。CLI 打到 stdout，M3 的 UI 会接到面板上。
    var onLog: ((String) -> Void)?
    /// 每次求值后回调，方便 UI 刷新。
    var onEvaluate: ((Outcome, Resolution?) -> Void)?

    private(set) var schedule: Schedule
    private(set) var state: EngineState
    private(set) var lastResolution: Resolution?
    private(set) var lastOutcome: Outcome?
    /// 定时器排在什么时候。nil 表示没有排（暂停中或引擎没起）。
    private(set) var wakeUpAt: Date?

    // MARK: - 内部

    private var timer: Timer?
    private var watcher: ConfigWatcher?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var isRunning = false

    /// 安全网：再没别的事发生，也至少这么久重新求值一次。
    private let maxSleep: TimeInterval = 6 * 3600
    /// 求不出值时的重试间隔。
    private let retryInterval: TimeInterval = 15 * 60
    /// 定时器落在触发时刻之后一点点。早那么几毫秒会求值到上一段，白跑一趟。
    private let fireGuard: TimeInterval = 1

    init(schedule: Schedule, state: EngineState = .load()) {
        self.schedule = schedule
        self.state = state
    }

    // MARK: - 生命周期

    /// 注册所有观察者、启动配置监听，并立即求值一次。
    func start(schedule initialSchedule: Schedule? = nil) {
        guard !isRunning else { return }
        // 从属者接管时，构造 Scheduler 之后配置可能已被别的进程改过；必须以抢锁成功
        // 那一刻重新读到的版本启动，不能先写回旧快照。
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

    // MARK: - 求值

    /// 求值一次，写入（或不写入），然后把定时器排到下一个触发点。
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
        // state.json 才是权威。CLI 的 `resume` / `apply` 是独立进程，
        // 它们写过之后内存里这份就旧了，每次求值前重新读一遍。
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
            // 图片配置可能写成 `~/…`，系统只会读回绝对路径。状态也存规范化后的值，
            // 避免下次启动把同一张图误判成用户手动更换。
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

    /// 是否无条件覆盖当前壁纸。见类型注释里对手动改动的讨论。
    /// 非 private：`Tests/EngineCheck` 直接对它跑决策矩阵。
    func shouldAssert(_ resolution: Resolution, reason: Reason) -> Bool {
        if reason.isAssertive { return true }
        // 没有写入记录 —— 首次运行，谈不上让位。
        guard let lastFiredAt = state.lastFiredAt else { return true }
        // 跨过了一个新的触发时刻。
        if resolution.since > lastFiredAt { return true }
        // 时段被增删改，当前生效的已经不是上次那一个。
        if state.lastSlotID != resolution.active.id { return true }
        return false
    }

    // MARK: - 定时

    /// 定时器该排在什么时候。纯函数，`Tests/EngineCheck` 直接验它。
    ///
    /// - `next` 是下一个触发时刻；`resolved` 表示这次求出值了没有。
    /// - 三条上界取最小：下一个触发点、`maxSleep` 安全网、求不出值时的重试间隔。
    /// - 下界是 now+1 秒：定时器排在过去或当下会立刻再跑一轮，空转。
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
        // .common 而不是 .default：M3 的菜单栏面板打开时是另一个 run loop mode，
        // 用 .default 的话面板一开定时器就不走了。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 系统事件

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
                // 不重置的话 TimeZone.current 还是旧时区，日出日落会算错一整天。
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

    // MARK: - 外部操作

    /// 全局暂停。定时器停掉，壁纸停在当前这张。
    func pause() throws {
        guard !schedule.paused else { return }
        var updated = schedule
        updated.paused = true
        try persistSchedule(updated)
        evaluate(reason: .pause)
    }

    /// 恢复。立即校正到当前应生效的那张，无视用户中途的手动改动。
    func resume() throws {
        guard schedule.paused else { return }
        var updated = schedule
        updated.paused = false
        try persistSchedule(updated)
        evaluate(reason: .resume)
    }

    /// 强制把当前应生效的壁纸写下去。
    @discardableResult
    func applyNow() -> Outcome {
        evaluate(reason: .manual)
    }

    /// 换了一份配置（M3 的 UI 会走这条路）。
    func update(schedule newValue: Schedule) throws {
        try persistSchedule(newValue)
        evaluate(reason: .configChange)
    }

    private func persistSchedule(_ newValue: Schedule) throws {
        // 先落盘再提交内存状态；保存失败时继续运行旧配置，不能出现内存/磁盘分叉。
        try Store.save(newValue)
        schedule = newValue
        // 自己写的这一笔别再绕回来触发一次求值。
        watcher?.acknowledgeSelfWrite()
    }

    // MARK: - 日志

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

    /// 只有一个时段时，「下次」就是明天的同一段。光打 HH:mm 会让人以为它在过去。
    private static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clockFormat.string(from: date) }
        if calendar.isDateInTomorrow(date) { return L10n.t("clock.tomorrow", clockFormat.string(from: date)) }
        return dayClockFormat.string(from: date)
    }

    /// 壁纸的人类可读名。目录读一次就缓存，日志每行都要用。
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
