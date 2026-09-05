import Darwin
import Foundation

struct SceneImportError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Converts a folder of images into daylight-phase slots.
///
/// Recognizes 24 Hour Wallpaper naming:
///   `sunrise_1.heic` / `01_sunrise_1.heic` / `morning_2.jpg` / `evening-3.png`
/// and its `.sundialScene/images/5120x2880/` layout, choosing the largest resolution of each image.
/// Filenames containing sunrise / morning / day / sunset / evening / night select the corresponding phase.
/// Unrecognized filenames fall back to ancestor folder names within the import root, as in `sunrise/1.jpg`.
/// Only when nothing is recognized are files sorted by name and split into four equal groups (12 becomes 3/3/3/3).
/// Phase counts may differ: four sunrise images and six daytime images occupy their own independent solar windows.
/// Each slot stores `solarPhase.count`; evaluation divides the day's window evenly.
enum SceneImport {

    static let imageExts: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"
    ]

    /// Import result.
    ///
    /// `skipped` contains images with unrecognized phases when other files were recognized.
    /// Forcing them into daytime could schedule night scenes at noon. The caller must report
    /// their count rather than silently show success with images missing from the timeline.
    struct Outcome {
        var schedule: Schedule
        var skipped: [URL]
        /// Newly written asset directory. Old assets may be cleaned up only after the configuration is saved.
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

    /// Accepts folders, `.sundialScene` bundles, or a directly selected set of images.
    static func apply(urls: [URL],
                      to schedule: Schedule,
                      name: String? = nil) throws -> Outcome {
        guard !urls.isEmpty else {
            throw SceneImportError(message: L10n.t("import.error.noFiles"))
        }

        var files: [URL] = []
        for url in urls {
            files.append(contentsOf: try listImages(in: url))
        }
        files = pickPreferredResolution(files)
        guard !files.isEmpty else {
            throw SceneImportError(message: L10n.t("import.error.noImages"))
        }

        let (grouped, skipped) = group(files, root: commonRoot(of: urls))
        let slug = slugify(name ?? defaultName(for: urls))
        let baseDestination = scenesDirectory.appendingPathComponent(slug, isDirectory: true)
        // Never overwrite an existing directory: the old timeline may still reference it.
        // Reimports use a suffixed directory; finalize may clean up only after the new configuration is saved.
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
                throw SceneImportError(message: L10n.t("import.error.unrecognised"))
            }

            var updated = schedule
            updated.slots = slots
            return Outcome(schedule: updated,
                           skipped: skipped,
                           destination: dest,
                           protectedSources: sources)
        } catch {
            // On a partial copy failure, remove only this new directory, preserving existing assets and timeline.
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// The configuration is saved and the old timeline will not be restored; unreferenced assets can now be removed.
    static func finalize(_ outcome: Outcome) {
        // Reload from disk rather than trust outcome: another process may have committed a later import.
        // Clean up against the persisted timeline so an earlier task cannot delete the later task's new assets.
        guard let current = try? Store.load() else { return }
        pruneScenes(keeping: referencedSceneItems(in: current),
                    sources: outcome.protectedSources)
    }

    /// Configuration save failed: remove this import's new assets, leaving the old timeline and assets intact.
    static func discard(_ outcome: Outcome) {
        let destination = canonicalPath(outcome.destination)
        let parent = canonicalPath(scenesDirectory)
        guard outcome.destination.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.path == parent,
              destination != parent else { return }
        try? FileManager.default.removeItem(at: outcome.destination)
    }

    /// Reserves a fresh directory so assets referenced by the old timeline survive until the configuration commits.
    private static func reserveDestination(basedOn base: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let parent = base.deletingLastPathComponent()
        let stem = base.lastPathComponent
        var candidate = base
        while true {
            // fileExists followed by createDirectory races: two imports could claim the same directory,
            // and one import's failure cleanup could delete files copied by the other. mkdir checks
            // EEXIST and creates atomically, making it suitable for reserving the directory.
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            guard errno == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let suffix = UUID().uuidString.prefix(8).lowercased()
            candidate = parent.appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
        }
    }

    /// Groups by phase keywords in filenames, then ancestor folders; splits into four only if none are recognized.
    ///
    /// `root` bounds the ancestor search. Otherwise importing all of `~/Pictures/Sunset trip/`
    /// would incorrectly classify every image as sunset.
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
        // If only some phases are recognized, do not force the rest into daytime and schedule night scenes at noon.
        // Return them to the caller as skipped.
        return (buckets, leftover)
    }

    /// Falls back from unrecognized filenames to ancestor folder names within the import root.
    /// The nearest match wins: `sunset/closeups/3.jpg` belongs to sunset, not a more distant ancestor's phase.
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

    /// Extracts the phase from a filename, checking sunrise/sunset, then morning/evening, then day/night.
    /// Matches tokens rather than substrings to avoid false positives such as `sunday`;
    /// both `01_sunrise_1.heic` and `sunrise_1.heic` match.
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
            throw SceneImportError(message: L10n.t("import.error.noFolder"))
        }

        let files: [URL]
        if isDir.boolValue {
            files = try collectImages(in: source)
        } else if imageExts.contains(source.pathExtension.lowercased())
                    || source.pathExtension.lowercased() == "sundialscene" {
            files = imageExts.contains(source.pathExtension.lowercased()) ? [source] : try collectImages(in: source)
        } else {
            throw SceneImportError(message: L10n.t("import.error.wrongKind"))
        }
        return pickPreferredResolution(files)
    }

    // MARK: - Internals

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
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files
    }

    /// 24 Hour Wallpaper stores resolutions of the same image under `5120x2880/`, `2560x1440/`, etc.
    /// Merge by the full path with the resolution component removed, not by filename alone.
    /// A bare filename cannot distinguish two resolutions from `sunrise/1.jpg` and `night/1.jpg`,
    /// discarding much of any collection that numbers images from 1 within each phase folder.
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

    /// A component such as `5120x2880`. Requires digits x digits so names such as `extra` are not treated as resolutions.
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
                if let width = Int(parts[0]), let height = Int(parts[1]) {
                    // Directory names come from external collections; two valid Int values can still overflow when multiplied.
                    let area = width.multipliedReportingOverflow(by: height)
                    return area.overflow ? Int.max : area.partialValue
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
        return size
    }

    /// Import root: the folder itself, a single file's parent, or the common ancestor of multiple selections.
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

    /// Directory components between `root` and the file, excluding the filename. Empty if the file is outside root.
    private static func enclosingComponents(of url: URL, below root: URL) -> [String] {
        let file = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard file.count > base.count, Array(file.prefix(base.count)) == base else { return [] }
        return Array(file.dropFirst(base.count).dropLast())
    }

    /// Direct children of `Scenes/` still referenced by the configuration: usually whole scene directories,
    /// but also individual files such as `Scenes/foo.jpg` in hand-written configurations.
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

    /// Replacing the entire timeline leaves the previous collection's assets unreferenced.
    /// Scan only our own `Scenes/` directory and avoid this import's source directories.
    private static func pruneScenes(keeping keep: Set<String>, sources: Set<String>) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: scenesDirectory,
                                                         includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            let path = canonicalPath(child)
            if keep.contains(path) { continue }
            // When importing a collection directly from `Scenes/`, preserve that collection as the source.
            let isSource = sources.contains { $0 == path || $0.hasPrefix(path + "/") }
            if isSource { continue }
            try? fm.removeItem(at: child)
        }
    }

    /// URLs for the same directory can differ (`/private/tmp` vs `/tmp`, `..`, or symlinks).
    /// Normalize here before comparing identity.
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
        // `foo.sundialScene/images/5120x2880` → use the scene name.
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
