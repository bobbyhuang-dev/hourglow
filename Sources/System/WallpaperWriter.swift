import Foundation

enum WallpaperError: Error, CustomStringConvertible {
    case indexMissing(String)
    case malformed(String)
    case imageMissing(String)

    var description: String {
        switch self {
        case .indexMissing(let p): return L10n.t("wallpaper.error.indexMissing", p)
        case .malformed(let why):  return L10n.t("wallpaper.error.malformed", why)
        case .imageMissing(let p): return L10n.t("wallpaper.error.imageMissing", p)
        }
    }
}

/// Reads and writes macOS wallpaper configuration.
///
/// Always writes linked mode (one image shared by desktop and screensaver), backing up first.
/// Skips an unchanged target to avoid flicker from killall WallpaperAgent.
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

    // MARK: - Reading

    static func current() throws -> Wallpaper? {
        let root = try readIndex()
        guard let scope = root["AllSpacesAndDisplays"] as? [String: Any] else { return nil }

        // linked uses the Linked key; individual mode separates Desktop and Idle.
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

    // MARK: - Writing

    /// Returns true if written, false if skipped because the target already matches.
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

        // Dry runs must not create persistent lock files and retain the permissive "report whether a change is needed" semantics.
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
            // Clear per-Space and per-display overrides so they cannot supersede the global setting.
            root["Spaces"] = [String: Any]()
            root["Displays"] = [String: Any]()

            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            // A successful backup is a precondition for writing; never overwrite the original if backup fails.
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
            throw WallpaperError.malformed(L10n.t("wallpaper.error.notDictionary"))
        }
        return root
    }

    /// The CLI, resident engine, and menu-bar app can write concurrently. Lock compare → backup → write
    /// as one cross-process transaction to avoid deleting each other's backups, duplicate restarts, or lost updates.
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

    /// Image URLs read from the system plist are normalized absolute paths. Compare the same representation
    /// so ~, relative paths, and .. do not make the same image appear to be a different target.
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
