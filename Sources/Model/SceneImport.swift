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
/// 否则按文件名排序后均分成四段（12 张就是 3/3/3/3）。
/// 各段张数可以不同：4 张日出和 6 张白昼占各自的太阳窗口，互不影响。
/// 张数写进每个 slot 的 `solarPhase.count`，求值时按当天窗口等分。
enum SceneImport {

    static let imageExts: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"
    ]

    static var scenesDirectory: URL {
        Store.directoryURL.appendingPathComponent("Scenes", isDirectory: true)
    }

    static func apply(folder source: URL,
                      to schedule: Schedule,
                      name: String? = nil) throws -> Schedule {
        try apply(urls: [source], to: schedule, name: name)
    }

    /// 文件夹、`.sundialScene`、或直接选中的一组图片都可以。
    static func apply(urls: [URL],
                      to schedule: Schedule,
                      name: String? = nil) throws -> Schedule {
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

        let grouped = group(files)
        let slug = slugify(name ?? defaultName(for: urls))
        let dest = scenesDirectory.appendingPathComponent(slug, isDirectory: true)
        let fm = FileManager.default

        // 源目录就是目标时只重写时段，别先把自己删掉。
        let destPath = dest.standardizedFileURL
        let sources = Set(urls.map(\.standardizedFileURL))
        if !sources.contains(destPath), fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        var slots: [Slot] = []
        for phase in DayPhase.allCases {
            let urls = grouped[phase] ?? []
            let count = urls.count
            for (index, url) in urls.enumerated() {
                let ext = url.pathExtension.lowercased()
                let fileName = "\(phase.rawValue)_\(index + 1).\(ext)"
                let destURL = dest.appendingPathComponent(fileName)
                if destURL.standardizedFileURL != url.standardizedFileURL {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.copyItem(at: url, to: destURL)
                }
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
        return updated
    }

    /// 优先按文件名里的时段关键词归类；都认不出时再均分成四段。
    static func group(_ files: [URL]) -> [DayPhase: [URL]] {
        var buckets: [DayPhase: [URL]] = [:]
        var leftover: [URL] = []
        for url in files {
            if let phase = phase(from: url.lastPathComponent) {
                buckets[phase, default: []].append(url)
            } else {
                leftover.append(url)
            }
        }
        for phase in DayPhase.allCases {
            buckets[phase] = (buckets[phase] ?? []).sorted(by: sceneOrder)
        }
        leftover.sort(by: sceneOrder)

        if leftover.isEmpty { return buckets }

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
            return buckets
        }
        // 有的认得出、有的认不出：认不出的不硬塞进白昼，免得把一张夜景排到中午。
        return buckets
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
    /// 按文件名归并，留分辨率最大的那份。
    private static func pickPreferredResolution(_ files: [URL]) -> [URL] {
        var best: [String: (url: URL, score: Int)] = [:]
        for file in files {
            let key = file.lastPathComponent.lowercased()
            let score = resolutionScore(file)
            if let current = best[key], current.score >= score { continue }
            best[key] = (file, score)
        }
        return best.values.map(\.url).sorted(by: sceneOrder)
    }

    private static func resolutionScore(_ url: URL) -> Int {
        var current = url.deletingLastPathComponent()
        for _ in 0..<6 {
            let name = current.lastPathComponent.lowercased()
            let parts = name.split(separator: "x")
            if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
               width > 0, height > 0 {
                return width * height
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
        return size
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
            if name.contains("x"), name.split(separator: "x").count == 2 {
                url = url.deletingLastPathComponent()
                continue
            }
            if name.lowercased() == "images" {
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
