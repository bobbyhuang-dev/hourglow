import Foundation

enum WallpaperError: Error, CustomStringConvertible {
    case indexMissing(String)
    case malformed(String)
    case imageMissing(String)

    var description: String {
        switch self {
        case .indexMissing(let p): return "找不到壁纸配置: \(p)"
        case .malformed(let why):  return "Index.plist 结构异常: \(why)"
        case .imageMissing(let p): return "图片不存在: \(p)"
        }
    }
}

/// 读写 macOS 壁纸配置。
///
/// 统一写成 `linked`（桌面与屏保共用一张）。写入前备份，
/// 目标与当前一致时跳过，避免 `killall WallpaperAgent` 带来的闪烁。
enum WallpaperWriter {

    static var indexURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    static var backupURL: URL {
        indexURL.appendingPathExtension("hourglow.bak")
    }

    private static var lockURL: URL {
        indexURL.appendingPathExtension("hourglow.lock")
    }

    // MARK: - 读

    static func current() throws -> Wallpaper? {
        let root = try readIndex()
        guard let scope = root["AllSpacesAndDisplays"] as? [String: Any] else { return nil }

        // linked 用 Linked 键；individual 拆成 Desktop / Idle。
        for key in ["Linked", "Desktop", "Idle"] {
            guard let slot = scope[key] as? [String: Any],
                  let content = slot["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let provider = choice["Provider"] as? String,
                  let configData = choice["Configuration"] as? Data,
                  let config = try PropertyListSerialization.propertyList(
                      from: configData, options: [], format: nil) as? [String: Any]
            else { continue }

            if provider.hasSuffix(".aerials"), let id = config["assetID"] as? String {
                return .aerial(assetID: id)
            }
            if provider.hasSuffix(".image"),
               let url = config["url"] as? [String: Any],
               let relative = url["relative"] as? String,
               let parsed = URL(string: relative) {
                return .image(path: parsed.path)
            }
        }
        return nil
    }

    // MARK: - 写

    /// 返回 true 表示确实写入了，false 表示目标与当前一致、已跳过。
    @discardableResult
    static func apply(_ wallpaper: Wallpaper,
                      dryRun: Bool = false,
                      force: Bool = false) throws -> Bool {

        let target = normalized(wallpaper)

        if case .image(let path) = target {
            guard FileManager.default.fileExists(atPath: path) else {
                throw WallpaperError.imageMissing(path)
            }
        }

        // dry-run 不应创建持久锁文件，也沿用原来的“只报告是否需要改”的宽松语义。
        if dryRun {
            if !force, let existing = try? current(), normalized(existing) == target { return false }
            return true
        }

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw WallpaperError.indexMissing(indexURL.path)
        }

        return try withExclusiveLock {
            if !force, let existing = try? current(), normalized(existing) == target { return false }

            var root = try readIndex()
            let slot = try linkedSlot(for: target)
            root["AllSpacesAndDisplays"] = slot
            root["SystemDefault"] = slot
            // 清掉逐 Space / 逐显示器的覆盖，否则它们会盖过全局设置。
            root["Spaces"] = [String: Any]()
            root["Displays"] = [String: Any]()

            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            // 备份是写入的前置条件；失败时不得继续覆盖原配置。
            try FileManager.default.copyItem(at: indexURL, to: backupURL)

            let encoded = try PropertyListSerialization.data(fromPropertyList: root,
                                                              format: .binary, options: 0)
            try encoded.write(to: indexURL, options: .atomic)
            restartAgent()
            return true
        }
    }

    // MARK: -

    private static func readIndex() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw WallpaperError.indexMissing(indexURL.path)
        }
        let data = try Data(contentsOf: indexURL)
        guard let root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            throw WallpaperError.malformed("顶层不是字典")
        }
        return root
    }

    /// CLI、常驻引擎和菜单栏 app 都可能同时触发写入。把“比较 → 备份 → 写入”
    /// 锁成一个跨进程事务，避免两个进程互删备份、重复重启或后写覆盖先写。
    private static func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// 系统 plist 中的图片 URL 总会读回规范化的绝对路径；比较前使用相同表示，
    /// 否则 `~`、相对路径或 `..` 会让同一张图片被误判为不同目标。
    static func normalized(_ wallpaper: Wallpaper) -> Wallpaper {
        switch wallpaper {
        case .aerial:
            return wallpaper
        case .image(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return .image(path: URL(fileURLWithPath: expanded).standardizedFileURL.path)
        }
    }

    private static func configuration(for wallpaper: Wallpaper) throws -> (String, Data) {
        switch wallpaper {
        case .aerial(let assetID):
            let plist: [String: Any] = ["assetID": assetID]
            return ("com.apple.wallpaper.choice.aerials",
                    try PropertyListSerialization.data(fromPropertyList: plist,
                                                       format: .binary, options: 0))
        case .image(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let plist: [String: Any] = [
                "type": "imageFile",
                "url": ["relative": url.absoluteString],
            ]
            return ("com.apple.wallpaper.choice.image",
                    try PropertyListSerialization.data(fromPropertyList: plist,
                                                       format: .binary, options: 0))
        }
    }

    private static func linkedSlot(for wallpaper: Wallpaper) throws -> [String: Any] {
        let (provider, config) = try configuration(for: wallpaper)
        let options = try PropertyListSerialization.data(
            fromPropertyList: ["values": [String: Any]()], format: .binary, options: 0)

        let choice: [String: Any] = [
            "Provider": provider,
            "Files": [Any](),
            "Configuration": config,
        ]
        let content: [String: Any] = [
            "Choices": [choice],
            "Shuffle": "$null",
            "EncodedOptionValues": options,
        ]
        let now = Date()
        let linked: [String: Any] = ["LastSet": now, "LastUse": now, "Content": content]
        return ["Type": "linked", "Linked": linked]
    }

    private static func restartAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
