import Foundation

/// 引擎的单实例锁。
///
/// 两个引擎同时跑会互相打架 —— 一个让位给「手动改动」，而那个「手动改动」
/// 其实是另一个自己写的。菜单栏 app 与 `hourglow-cli run` 启动时都先来抢这把锁：
/// 抢到的负责排程，没抢到的退回从属模式（只编辑配置，由对方的 ConfigWatcher 跟上）。
///
/// 锁随进程退出自动释放（包括被 kill），所以不需要清理残留的锁文件。
final class EngineLock {

    static var fileURL: URL {
        Store.directoryURL.appendingPathComponent("run.lock")
    }

    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    /// 抢到锁返回实例；已被别的进程持有时返回 nil。
    static func acquire() -> EngineLock? {
        try? FileManager.default.createDirectory(at: Store.directoryURL,
                                                 withIntermediateDirectories: true)
        let descriptor = open(fileURL.path, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return EngineLock(descriptor: descriptor)
    }

    /// 有没有别的进程正在排程。抢得到锁就说明没有。
    static var isHeldByAnotherProcess: Bool {
        guard let probe = acquire() else { return true }
        probe.release()
        return false
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
