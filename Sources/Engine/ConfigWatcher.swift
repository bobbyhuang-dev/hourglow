import Foundation

/// 盯着 `schedule.json`，用户手改后引擎立刻跟上。
///
/// 目录和文件本身**都要盯**，两种写法各漏一半：
///
/// - `Store.save` 用原子写（临时文件 + rename），文件的 inode 会被换掉。
///   只盯文件的话，第一次保存之后 fd 指向的就是个已被顶掉的旧 inode，再也收不到事件。
/// - 手改（`vim` 的某些配置、`echo >`、脚本里的 `open(path, "w")`）是原地截断重写，
///   目录内容没变，目录级的 vnode 事件压根不会产生 —— 实测就是这么漏掉一次配置变更的。
///
/// 所以：目录 source 负责接住「文件被换掉」，文件 source 负责接住「原地改内容」，
/// 每次检查后重新挂一次文件 source，保证它始终盯在当前那个 inode 上。
///
/// 同一个目录里还有引擎自己写的 `state.json`，所以每次事件都要比对 `schedule.json`
/// 的实际内容 —— 否则「求值 → 存状态 → 收到事件 → 再求值」会自激成死循环。
final class ConfigWatcher {

    private let fileURL: URL
    private let directoryURL: URL
    private let onChange: () -> Void

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var lastContents: Data?
    private var generation = 0
    private var isStarted = false

    /// 文件系统事件常常成串到达（一次保存可能触发好几次），合并一下再处理。
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
        // 让已经排进 main queue 的 debounce 闭包失效，保证 stop 返回后不再回调。
        generation += 1
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// 引擎自己保存配置后调用，免得把自己的写入当成外部改动再求值一遍。
    /// 原子写换过 inode，顺手重新挂一次文件 source。
    func acknowledgeSelfWrite() {
        lastContents = try? Data(contentsOf: fileURL)
        armFileSource()
    }

    // MARK: -

    private func armFileSource() {
        guard isStarted else { return }
        fileSource?.cancel()
        // 文件不存在（还没写过配置）时挂不上，交给目录 source 接住创建事件。
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
        // 关掉的必须是这一代 source 自己捕获的 descriptor：重新挂载时新旧 source
        // 会短暂并存，按成员变量去关会把新的那个一起关掉。
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.isStarted, self.generation == mine else { return }
            // 文件可能刚被 rename 顶掉，重新挂到当前 inode 上。
            self.armFileSource()

            let current = try? Data(contentsOf: self.fileURL)
            guard current != self.lastContents else { return }
            self.lastContents = current
            self.onChange()
        }
    }
}
