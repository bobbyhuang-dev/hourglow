import Foundation

/// Watches schedule.json so the engine immediately follows manual edits.
///
/// **Watch both the directory and the file**: each alone misses one kind of write.
///
/// - Store.save writes atomically (temporary file + rename), replacing the inode. A file-only watcher
///   keeps its descriptor on the displaced inode after the first save and receives no further events.
/// - Manual edits (some vim configurations, echo >, or open(path, "w") in scripts) truncate and rewrite
///   in place. The directory is unchanged, so no directory vnode event occurs; this has caused missed edits.
///
/// The directory source catches replacements; the file source catches in-place content changes.
/// Re-arm the file source after every check to keep watching the current inode.
///
/// The engine also writes state.json in this directory, so compare schedule.json's actual contents
/// on every event to prevent an endless evaluate → save state → event → evaluate feedback loop.
final class ConfigWatcher {

    private let fileURL: URL
    private let directoryURL: URL
    private let onChange: () -> Void

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var lastContents: Data?
    private var generation = 0
    private var isStarted = false

    /// Filesystem events arrive in bursts, often several per save; coalesce them before handling.
    private let debounce: TimeInterval = 0.25

    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.onChange = onChange
        self.lastContents = try? Data(contentsOf: fileURL)
    }

    deinit { stop() }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        try? FileManager.default.createDirectory(at: directoryURL,
                                                 withIntermediateDirectories: true)
        directorySource = makeSource(path: directoryURL.path,
                                     mask: [.write, .delete, .rename])
        armFileSource()
    }

    func stop() {
        isStarted = false
        // Invalidate debounce closures already on the main queue so no callback occurs after stop returns.
        generation += 1
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// Called after the engine saves configuration to avoid evaluating its own write as an external change.
    /// Re-arm the file source because the atomic write replaced the inode.
    func acknowledgeSelfWrite() {
        lastContents = try? Data(contentsOf: fileURL)
        armFileSource()
    }

    // MARK: -

    private func armFileSource() {
        guard isStarted else { return }
        fileSource?.cancel()
        // If the file does not exist yet, the directory source will catch its creation.
        fileSource = makeSource(path: fileURL.path,
                                mask: [.write, .extend, .delete, .rename, .revoke])
    }

    private func makeSource(path: String,
                            mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        // Close the descriptor captured by this source: old and new sources briefly coexist during
        // re-arming, so closing through a member variable could accidentally close the new descriptor.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.isStarted, self.generation == mine else { return }
            // A rename may have replaced the file; reattach to the current inode.
            self.armFileSource()

            let current = try? Data(contentsOf: self.fileURL)
            guard current != self.lastContents else { return }
            self.lastContents = current
            self.onChange()
        }
    }
}
