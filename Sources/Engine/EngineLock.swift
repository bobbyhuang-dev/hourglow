import Foundation

/// Single-instance lock for the engine.
///
/// Concurrent engines conflict: one defers to a "manual change" actually written by the other.
/// The menu-bar app and hourglow-cli run both acquire this lock at startup. The winner schedules;
/// the other enters follower mode, only editing configuration for the owner's ConfigWatcher to pick up.
///
/// Process exit releases the lock automatically, including when killed; stale lock files need no cleanup.
final class EngineLock {

    static var fileURL: URL {
        Store.directoryURL.appendingPathComponent("run.lock")
    }

    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    /// Returns the acquired lock, or nil if another process holds it.
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

    /// Whether another process is scheduling. Successfully acquiring the lock means none is.
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
