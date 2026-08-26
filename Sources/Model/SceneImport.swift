import Darwin
import Foundation

struct SceneImportError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// 把一文件夹图片编成「天光分段」时段。
///
/// 认 24 Hour Wallpaper 那套命名：
///   `sunrise_1.heic` / `01_sunrise_1.heic` / `morning_2.jpg` / `evening-3.png`
/// 以及它的 `.sundialScene/images/5120x2880/` 目录。同一张图有多个分辨率时取最大的。
/// 文件名带 sunrise / morning / day / sunset / evening / night 的按关键词进对应段；
/// 文件名认不出时再看它在导入目录里的上级文件夹名（`sunrise/1.jpg` 这种按段分子目录的图集）；
/// 全都认不出才按文件名排序均分成四段（12 张就是 3/3/3/3）。
/// 各段张数可以不同：4 张日出和 6 张白昼占各自的太阳窗口，互不影响。
/// 张数写进每个 slot 的 `solarPhase.count`，求值时按当天窗口等分。
enum SceneImport {

    static let imageExts: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"
    ]

    /// 导入结果。
    ///
    /// `skipped` 是「别的文件认得出时段、它自己认不出」的那些图。把它们硬塞进白昼会
    /// 把夜景排到中午，所以不收；但也不能默默丢掉 —— 调用方要把张数说出来，
    /// 否则用户看到的是一个「成功」对话框加一个少了几张的时间轴。
    struct Outcome {
        var schedule: Schedule
        var skipped: [URL]
        /// 这次新写好的素材目录。配置成功落盘后才能据此清理旧素材。
        var destination: URL
        fileprivate var protectedSources: Set<String>
    }

    static var scenesDirectory: URL {
        Store.directoryURL.appendingPathComponent("Scenes", isDirectory: true)
    }

    static func apply(folder source: URL,
                      to schedule: Schedule,
                      name: String? = nil) throws -> Outcome {
        try apply(urls: [source], to: schedule, name: name)
    }

    /// 文件夹、`.sundialScene`、或直接选中的一组图片都可以。
    static func apply(urls: [URL],
                      to schedule: Schedule,
                      name: String? = nil) throws -> Outcome {
        guard !urls.isEmpty else {
            throw SceneImportError(message: "没有选任何文件")
        }

        var files: [URL] = []
        for url in urls {
            files.append(contentsOf: try listImages(in: url))
        }
        files = pickPreferredResolution(files)
        guard !files.isEmpty else {
            throw SceneImportError(message: "这里面没有图片")
        }

        let (grouped, skipped) = group(files, root: commonRoot(of: urls))
        let slug = slugify(name ?? defaultName(for: urls))
        let baseDestination = scenesDirectory.appendingPathComponent(slug, isDirectory: true)
        // 永远不覆盖已有目录。旧时间轴可能仍引用它；只有新配置成功落盘后，调用方
        // 才能 finalize 并清理。相同名字再次导入时先写到带后缀的新目录。
        let dest = try reserveDestination(basedOn: baseDestination)
        let fm = FileManager.default

        let sources = Set(urls.map(canonicalPath))
        do {
            var slots: [Slot] = []
            for phase in DayPhase.allCases {
                let urls = grouped[phase] ?? []
                let count = urls.count
                for (index, url) in urls.enumerated() {
                    let ext = url.pathExtension.lowercased()
                    let fileName = "\(phase.rawValue)_\(index + 1).\(ext)"
                    let destURL = dest.appendingPathComponent(fileName)
                    try fm.copyItem(at: url, to: destURL)
                    slots.append(Slot(
                        trigger: .solarPhase(phase: phase, index: index, count: count),
                        wallpaper: .image(path: destURL.path)
                    ))
                }
            }
            guard !slots.isEmpty else {
                throw SceneImportError(message: "没有识别到可用的图片")
            }

            var updated = schedule
            updated.slots = slots
            return Outcome(schedule: updated,
                           skipped: skipped,
                           destination: dest,
                           protectedSources: sources)
        } catch {
            // 复制到一半失败时只删这次新建的目录；既有目录和旧时间轴仍然完整。
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// 配置已经成功落盘：现在旧时间轴不再会被恢复，可以清掉无人引用的旧素材。
    static func finalize(_ outcome: Outcome) {
        // 重新读磁盘而不是盲信 outcome：两个进程可能同时导入，后提交者已经成为权威。
        // 清理只以此刻真正落盘的时间轴为准，先完成的任务不能删掉后完成者的新素材。
        guard let current = try? Store.load() else { return }
        pruneScenes(keeping: referencedSceneItems(in: current),
                    sources: outcome.protectedSources)
    }

    /// 配置保存失败：撤掉本次新素材，旧时间轴及其素材保持原样。
    static func discard(_ outcome: Outcome) {
        let destination = canonicalPath(outcome.destination)
        let parent = canonicalPath(scenesDirectory)
        guard outcome.destination.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.path == parent,
              destination != parent else { return }
        try? FileManager.default.removeItem(at: outcome.destination)
    }

    /// 找一个从未存在过的目标目录，避免配置提交前破坏旧时间轴引用的同名素材。
    private static func reserveDestination(basedOn base: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let parent = base.deletingLastPathComponent()
        let stem = base.lastPathComponent
        var candidate = base
        while true {
            // `fileExists` 后再 `createDirectory` 有竞态：两个导入会同时认领同一个目录，
            // 其中一个失败清理时还可能把另一个已经复制的文件一起删掉。mkdir 的 EEXIST
            // 检查与创建是一个原子操作，正好用来认领目录。
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            guard errno == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let suffix = UUID().uuidString.prefix(8).lowercased()
            candidate = parent.appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
        }
    }

    /// 优先按时段关键词归类（先看文件名，再看导入目录里的上级文件夹）；都认不出时才均分成四段。
    ///
    /// `root` 是这次导入的根，只往上找到它为止 —— 否则把一整个 `~/Pictures/Sunset trip/`
    /// 拖进来，里面每张图都会被当成日落。
    static func group(_ files: [URL], root: URL? = nil) -> (buckets: [DayPhase: [URL]],
                                                            skipped: [URL]) {
        var buckets: [DayPhase: [URL]] = [:]
        var leftover: [URL] = []
        for url in files {
            if let phase = phase(for: url, root: root) {
                buckets[phase, default: []].append(url)
            } else {
                leftover.append(url)
            }
        }
        for phase in DayPhase.allCases {
            buckets[phase] = (buckets[phase] ?? []).sorted(by: sceneOrder)
        }
        leftover.sort(by: sceneOrder)

        if leftover.isEmpty { return (buckets, []) }

        if buckets.values.allSatisfy(\.isEmpty) {
            let n = leftover.count
            let base = n / 4
            let rem = n % 4
            var i = 0
            for (idx, phase) in DayPhase.allCases.enumerated() {
                let count = base + (idx < rem ? 1 : 0)
                buckets[phase] = Array(leftover[i ..< i + count])
                i += count
            }
            return (buckets, [])
        }
        // 有的认得出、有的认不出：认不出的不硬塞进白昼，免得把一张夜景排到中午。
        // 它们会作为 skipped 报给调用方。
        return (buckets, leftover)
    }

    /// 文件名认不出时，再看它在导入目录里的上级文件夹名。
    /// 就近的一层先算：`sunset/closeups/3.jpg` 该进日落，不该被更外层的名字盖掉。
    static func phase(for url: URL, root: URL?) -> DayPhase? {
        if let phase = phase(from: url.lastPathComponent) { return phase }
        guard let root else { return nil }
        for component in enclosingComponents(of: url, below: root).reversed() {
            if isResolutionComponent(component) { continue }
            if component.lowercased() == "images" { continue }
            if let phase = phase(from: component) { return phase }
        }
        return nil
    }

    /// 从文件名拆出时段。先看 sunrise/sunset，再看 morning/evening，最后才是 day/night，
    /// 避免 `sunday` 这种词误伤；用 token 而不是子串，所以 `01_sunrise_1.heic` 和
    /// `sunrise_1.heic` 都能对上。
    static func phase(from filename: String) -> DayPhase? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let tokens = tokenize(stem)
        let joined = tokens.joined(separator: " ")
        if match(tokens, joined, ["sunrise", "dawn", "morning", "日出", "晨", "朝", "清晨"]) {
            return .sunrise
        }
        if match(tokens, joined, ["sunset", "dusk", "evening", "twilight", "日落", "昏", "晚", "黄昏", "傍晚"]) {
            return .sunset
        }
        if match(tokens, joined, ["night", "midnight", "夜", "夜晚", "深夜"]) {
            return .night
        }
        if match(tokens, joined, ["day", "daytime", "noon", "midday", "afternoon", "昼", "白天", "日间", "午"]) {
            return .day
        }
        return nil
    }

    static func listImages(in source: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw SceneImportError(message: "找不到这个文件夹")
        }

        let files: [URL]
        if isDir.boolValue {
            files = try collectImages(in: source)
        } else if imageExts.contains(source.pathExtension.lowercased())
                    || source.pathExtension.lowercased() == "sundialscene" {
            files = imageExts.contains(source.pathExtension.lowercased()) ? [source] : try collectImages(in: source)
        } else {
            throw SceneImportError(message: "请选一个图片文件夹，或一组图片")
        }
        return pickPreferredResolution(files)
    }

    // MARK: - 内部

    private static func collectImages(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard imageExts.contains(ext) else { continue }
            if url.lastPathComponent.hasPrefix(".") { continue }
            files.append(url)
        }
        return files
    }

    /// 24 Hour Wallpaper 把同一张图按分辨率放在 `5120x2880/`、`2560x1440/` 下。
    /// 归并的键是「去掉分辨率那一层之后的整条路径」，不是光秃秃的文件名 ——
    /// 后者分不清「同一张图的两个分辨率」和「`sunrise/1.jpg` 与 `night/1.jpg`」，
    /// 按段分子目录、文件名从 1 编号的图集会被吃掉大半。
    private static func pickPreferredResolution(_ files: [URL]) -> [URL] {
        var best: [String: (url: URL, score: Int)] = [:]
        for file in files {
            let key = mergeKey(file)
            let score = resolutionScore(file)
            if let current = best[key], current.score >= score { continue }
            best[key] = (file, score)
        }
        return best.values.map(\.url).sorted(by: sceneOrder)
    }

    private static func mergeKey(_ url: URL) -> String {
        url.standardizedFileURL.pathComponents
            .filter { !isResolutionComponent($0) }
            .joined(separator: "/")
            .lowercased()
    }

    /// `5120x2880` 这样的一层。只认「数字 x 数字」，否则 `extra` 这种名字会被误当成分辨率层。
    private static func isResolutionComponent(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func resolutionScore(_ url: URL) -> Int {
        var current = url.deletingLastPathComponent()
        for _ in 0..<6 {
            let name = current.lastPathComponent
            if isResolutionComponent(name) {
                let parts = name.lowercased().split(separator: "x")
                if let width = Int(parts[0]), let height = Int(parts[1]) { return width * height }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
        return size
    }

    /// 这次导入的根：单个文件夹就是它自己，单个文件是它所在的目录，多选取共同的上级。
    private static func commonRoot(of urls: [URL]) -> URL? {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        let roots: [URL] = urls.map {
            let standardized = $0.standardizedFileURL
            if fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue {
                return standardized
            }
            return standardized.deletingLastPathComponent()
        }
        guard var shared = roots.first?.pathComponents else { return nil }
        for root in roots.dropFirst() {
            let other = root.pathComponents
            var i = 0
            while i < shared.count, i < other.count, shared[i] == other[i] { i += 1 }
            shared = Array(shared.prefix(i))
        }
        guard shared.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: shared))
    }

    /// `root` 与文件之间的那几层目录名（不含文件名本身）。文件不在 root 底下时为空。
    private static func enclosingComponents(of url: URL, below root: URL) -> [String] {
        let file = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard file.count > base.count, Array(file.prefix(base.count)) == base else { return [] }
        return Array(file.dropFirst(base.count).dropLast())
    }

    /// 配置里仍被引用的 `Scenes/` 直属项。通常是一整个场景目录；也兼容手写配置
    /// 直接引用 `Scenes/foo.jpg` 的情况。
    private static func referencedSceneItems(in schedule: Schedule) -> Set<String> {
        let root = canonicalPath(scenesDirectory)
        let prefix = root + "/"
        var result = Set<String>()
        for slot in schedule.slots {
            guard case .image(let rawPath) = slot.wallpaper else { continue }
            let expanded = (rawPath as NSString).expandingTildeInPath
            let path = canonicalPath(URL(fileURLWithPath: expanded))
            guard path.hasPrefix(prefix) else { continue }
            let remainder = path.dropFirst(prefix.count)
            guard let item = remainder.split(separator: "/").first else { continue }
            result.insert(prefix + item)
        }
        return result
    }

    /// 换一套壁纸后，上一套的素材没有任何时段引用了 —— 时间轴是整体替换的。
    /// 只扫我们自己的 `Scenes/`，并且躲开这次导入的源目录。
    private static func pruneScenes(keeping keep: Set<String>, sources: Set<String>) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: scenesDirectory,
                                                         includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            let path = canonicalPath(child)
            if keep.contains(path) { continue }
            // 直接从 `Scenes/` 里的某一套导入时，那一套就是源，别把脚下的地板拆了。
            let isSource = sources.contains { $0 == path || $0.hasPrefix(path + "/") }
            if isSource { continue }
            try? fm.removeItem(at: child)
        }
    }

    /// 同一个目录的两个 URL 可能长得不一样（`/private/tmp` 与 `/tmp`、`..`、软链）。
    /// 凡是要判断「是不是同一个东西」都先过这里。
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func tokenize(_ stem: String) -> [String] {
        stem.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func match(_ tokens: [String], _ joined: String, _ keys: [String]) -> Bool {
        keys.contains { key in
            tokens.contains(key) || joined == key
        }
    }

    private static func sceneOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = orderKey(lhs)
        let b = orderKey(rhs)
        if a.trailing != b.trailing { return a.trailing < b.trailing }
        if a.leading != b.leading { return a.leading < b.leading }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func orderKey(_ url: URL) -> (trailing: Int, leading: Int) {
        let numbers = tokenize(url.deletingPathExtension().lastPathComponent).compactMap(Int.init)
        return (numbers.last ?? 0, numbers.first ?? 0)
    }

    private static func defaultName(for urls: [URL]) -> String {
        if urls.count == 1 { return sceneName(from: urls[0]) }
        return urls[0].deletingLastPathComponent().lastPathComponent
    }

    private static func sceneName(from source: URL) -> String {
        var url = source.standardizedFileURL
        // `foo.sundialScene/images/5120x2880` → 用场景名。
        for _ in 0..<4 {
            let name = url.lastPathComponent
            if name.lowercased().hasSuffix(".sundialscene") {
                return String(name.dropLast(".sundialScene".count))
            }
            if isResolutionComponent(name) || name.lowercased() == "images" {
                url = url.deletingLastPathComponent()
                continue
            }
            break
        }
        return url.lastPathComponent
    }

    private static func slugify(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { ch -> String in
                let s = String(ch)
                return s.unicodeScalars.allSatisfy { allowed.contains($0) } ? s : "-"
            }
            .joined()
        let collapsed = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "scene-\(UUID().uuidString.prefix(8))" : collapsed
    }
}
