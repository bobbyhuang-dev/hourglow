import CryptoKit
import Darwin
import Foundation

/// An installable stable version from a GitHub Release.
struct AppRelease: Equatable, Sendable {
    let version: String
    let notes: String
    let pageURL: URL
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
}

/// Update state shown in settings. After download, the app immediately exits for the helper
/// to replace it, so no potentially stale "waiting to install" state is needed.
enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(AppRelease)
    case downloading(AppRelease)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading: return true
        default: return false
        }
    }
}

/// Built-in updater: accepts only this project's GitHub Releases, then verifies GitHub's
/// SHA-256, bundle ID, version, and full code signature before handing off to the installer helper.
///
/// No Sparkle dependency: the project builds directly with `swiftc` and has no third-party dependencies.
/// GitHub Releases supply asset SHA-256 digests; system frameworks handle download, extraction, and signature checks.
enum AppUpdater {
    static let bundleIdentifier = "dev.bobbyhuang.hourglow"
    static let releasesPage = URL(string: "https://github.com/bobbyhuang-dev/hourglow/releases/latest")!

    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/bobbyhuang-dev/hourglow/releases/latest")!
    private static let automaticKey = "updates.automatic"
    private static let lastCheckKey = "updates.lastCheck"
    private static let rateLimitKey = "updates.rateLimit"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    static var isAvailable: Bool {
        unavailabilityError == nil
    }

    static var unavailabilityError: UpdateError? {
        do {
            _ = try installation()
            return nil
        } catch let error as UpdateError {
            return error
        } catch {
            return .appUnavailable
        }
    }

    /// Bundle.main caches the launch path. If the app or a parent directory moves while running,
    /// ask the kernel for the executable's current location; checks, helper copying, and installation share this result.
    static func installation() throws -> (app: URL, helper: URL) {
        // Swift cannot import the expression macro PROC_PIDPATHINFO_MAXSIZE; expand it as defined in sys/proc_info.h.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
            throw UpdateError.appUnavailable
        }
        let executable = URL(fileURLWithPath: String(cString: path)).standardizedFileURL
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension.lowercased() == "app" else {
            throw UpdateError.notRunningAsApp
        }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier,
              bundle.executableURL?.standardizedFileURL == executable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.appUnavailable
        }
        let helper = app.appendingPathComponent("Contents/Helpers/HourGlowUpdater")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw UpdateError.helperUnavailable
        }
        return (app, helper)
    }

    static var automaticUpdatesEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            // Enabled when this setting first appears; once the user disables it, object is no longer nil.
            return defaults.object(forKey: automaticKey) == nil
                ? true : defaults.bool(forKey: automaticKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    static var shouldCheckAutomatically: Bool {
        guard automaticUpdatesEnabled, pendingRateLimit() == nil else { return false }
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= checkInterval
    }

    static func markChecked() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    // Persist the server's required wait period so restarts and repeated checks cannot bypass it.
    static func pendingRateLimit(now: Date = Date(),
                                 defaults: UserDefaults = .standard) -> RateLimit? {
        guard let data = defaults.data(forKey: rateLimitKey),
              let limit = try? JSONDecoder().decode(RateLimit.self, from: data),
              limit.retryAt > now else { return nil }
        return limit
    }

    static func rememberRateLimit(_ limit: RateLimit?, defaults: UserDefaults = .standard) {
        if let limit, let data = try? JSONEncoder().encode(limit) {
            defaults.set(data, forKey: rateLimitKey)
        } else {
            defaults.removeObject(forKey: rateLimitKey)
        }
    }

    /// Query the latest stable release. `/releases/latest` already excludes drafts and prereleases;
    /// check again to avoid offering test builds if the server's semantics change.
    static func latestRelease(currentVersion: String) async throws -> AppRelease? {
        if let limit = pendingRateLimit() { throw UpdateError.rateLimited(limit) }
        var request = URLRequest(url: latestReleaseAPI,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("HourGlow-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            try requireSuccess(response, data: data)
        } catch UpdateError.rateLimited(let limit) {
            rememberRateLimit(limit)
            throw UpdateError.rateLimited(limit)
        }
        rememberRateLimit(nil)
        return try release(from: data, currentVersion: currentVersion)
    }

    /// Download, verify, and unpack into the cache. The installer helper moves the returned app into the current bundle's location.
    static func stage(_ release: AppRelease) async throws -> URL {
        var request = URLRequest(url: release.downloadURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        request.setValue("HourGlow-Updater", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try requireSuccess(response)

        return try await Task.detached(priority: .utility) {
            try stageDownloadedArchive(temporaryURL, release: release)
        }.value
    }

    /// Launch the bundle's standalone helper. It waits for this PID to exit, replaces the bundle,
    /// and reopens it; the caller should terminate immediately after this returns.
    static func launchInstaller(stagedApp: URL) throws {
        let location = try installation()
        try requireWritableParent(of: location.app)

        let root = try updatesDirectory()
        let copiedHelper = root.appendingPathComponent("HourGlowUpdater-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: location.helper, to: copiedHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: copiedHelper.path)

        // stage() produces <run>/unpacked/HourGlow.app; the helper can clean up the entire <run>.
        let stageRoot = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = copiedHelper
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            stagedApp.path,
            location.app.path,
            copiedHelper.path,
            stageRoot.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: copiedHelper)
            throw error
        }
    }

    /// Reject read-only locations before downloading, rather than downloading the same un-installable update every day.
    static func requireInstallableLocation() throws {
        try requireWritableParent(of: installation().app)
    }

    private static func requireWritableParent(of app: URL) throws {
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.installDirectoryNotWritable(parent.path)
        }
    }

    // MARK: - Pure functions for offline verification

    static func release(from data: Data, currentVersion: String) throws -> AppRelease? {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let remote = AppVersion(payload.tagName),
              let current = AppVersion(currentVersion) else {
            throw UpdateError.invalidVersion(payload.tagName)
        }
        guard remote > current else { return nil }

        let version = remote.description
        let expectedName = "HourGlow-\(version).zip"
        guard let asset = payload.assets.first(where: { $0.name == expectedName }) else {
            throw UpdateError.missingAsset(expectedName)
        }
        guard asset.browserDownloadURL.host == "github.com",
              asset.browserDownloadURL.path.hasPrefix(
                "/bobbyhuang-dev/hourglow/releases/download/") else {
            throw UpdateError.unexpectedDownloadURL
        }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.missingDigest
        }

        return AppRelease(version: version,
                          notes: payload.body ?? "",
                          pageURL: payload.htmlURL,
                          downloadURL: asset.browserDownloadURL,
                          byteCount: asset.size,
                          sha256: String(digest.dropFirst(7)))
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download and signature verification

    static func requireSuccess(_ response: URLResponse, data: Data? = nil,
                               now: Date = Date()) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse(nil) }
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 403 || http.statusCode == 429 {
            let exhausted = http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            let payload = data.flatMap { try? JSONDecoder().decode(GitHubError.self, from: $0) }
            let message = payload?.message.lowercased() ?? ""
            let retryHeader = http.value(forHTTPHeaderField: "retry-after")
            if exhausted || http.statusCode == 429 || retryHeader != nil
                || message.contains("rate limit") {
                let reset = exhausted ? futureDate(
                    http.value(forHTTPHeaderField: "x-ratelimit-reset"), now: now) : nil
                let retry = retryDate(retryHeader, now: now)
                // Honor the later deadline when both headers exist; secondary limits must not use an unrelated reset header.
                let deadline = [reset, retry].compactMap { $0 }.max()
                let notice: RateLimit.Notice = deadline == nil ? .unknown
                    : (deadline == reset ? .reset : .retry)
                throw UpdateError.rateLimited(RateLimit(
                    retryAt: deadline?.addingTimeInterval(1) ?? now.addingTimeInterval(60),
                    notice: notice))
            }
            throw UpdateError.forbidden
        }
        throw UpdateError.badResponse(http.statusCode)
    }

    private static func futureDate(_ value: String?, now: Date) -> Date? {
        guard let value, let seconds = TimeInterval(value), seconds.isFinite,
              seconds > now.timeIntervalSince1970,
              seconds < Date.distantFuture.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return futureDate(String(now.timeIntervalSince1970 + seconds), now: now)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date > now else { return nil }
        return date
    }

    struct RateLimit: Codable, Equatable, Sendable {
        enum Notice: String, Codable { case reset, retry, unknown }
        let retryAt: Date
        let notice: Notice

        var localizedDescription: String {
            if notice == .unknown { return L10n.t("update.error.rateLimit.unknown") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: L10n.code)
            // Include date and time zone so a retry after midnight is not mistaken for a time today.
            formatter.setLocalizedDateFormatFromTemplate("MMMdHHmmssz")
            let time = formatter.string(from: retryAt)
            return notice == .reset ? L10n.t("update.error.rateLimit.reset", time)
                : L10n.t("update.error.rateLimit.retry", time)
        }
    }

    private struct GitHubError: Decodable { let message: String }

    private static func updatesDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else {
            throw UpdateError.noCacheDirectory
        }
        let root = caches.appendingPathComponent("HourGlow/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func stageDownloadedArchive(_ temporaryURL: URL,
                                               release: AppRelease) throws -> URL {
        let manager = FileManager.default
        let root = try updatesDirectory()
        removeStaleItems(in: root)

        let run = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = run.appendingPathComponent("HourGlow.zip")
        let unpacked = run.appendingPathComponent("unpacked", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        do {
            try manager.moveItem(at: temporaryURL, to: archive)
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard sha256(of: data) == release.sha256 else { throw UpdateError.digestMismatch }

            let result = try runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            guard result.status == 0 else { throw UpdateError.unarchiveFailed(result.output) }

            let app = unpacked.appendingPathComponent("HourGlow.app", isDirectory: true)
            try validate(app: app, expectedVersion: release.version)
            try? manager.removeItem(at: archive)
            return app
        } catch {
            try? manager.removeItem(at: run)
            throw error
        }
    }

    private static func validate(app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == expectedVersion else {
            throw UpdateError.bundleMismatch
        }
        guard let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.bundleMismatch
        }

        let verification = try runProcess("/usr/bin/codesign",
                                          ["--verify", "--deep", "--strict", app.path])
        guard verification.status == 0 else {
            throw UpdateError.invalidSignature(verification.output)
        }
        let requirement = try runProcess("/usr/bin/codesign", ["-d", "-r-", app.path])
        guard requirement.status == 0,
              requirement.output.contains("designated => identifier \"\(bundleIdentifier)\"") else {
            throw UpdateError.invalidSignature(requirement.output)
        }
    }

    static func runProcess(_ executable: String,
                           _ arguments: [String]) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe while waiting. Calling waitUntilExit first can deadlock when the child
        // fills the pipe and waits for the parent to read while the parent waits for the child to exit.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func removeStaleItems(in root: URL) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let items = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true { try? manager.removeItem(at: item) }
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case draft, prerelease, assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum UpdateError: LocalizedError {
        case invalidVersion(String)
        case missingAsset(String)
        case missingDigest
        case unexpectedDownloadURL
        case badResponse(Int?)
        case forbidden
        case rateLimited(RateLimit)
        case noCacheDirectory
        case digestMismatch
        case unarchiveFailed(String)
        case bundleMismatch
        case invalidSignature(String)
        case notRunningAsApp
        case appUnavailable
        case helperUnavailable
        case installDirectoryNotWritable(String)

        var errorDescription: String? {
            switch self {
            case .invalidVersion(let version): return L10n.t("update.error.invalidVersion", version)
            case .missingAsset(let name): return L10n.t("update.error.missingAsset", name)
            case .missingDigest: return L10n.t("update.error.missingDigest")
            case .unexpectedDownloadURL: return L10n.t("update.error.unexpectedURL")
            case .badResponse(let status):
                return status.map { L10n.t("update.error.http", $0) }
                    ?? L10n.t("update.error.badResponse")
            case .forbidden: return L10n.t("update.error.forbidden")
            case .rateLimited(let limit): return limit.localizedDescription
            case .noCacheDirectory: return L10n.t("update.error.noCacheDirectory")
            case .digestMismatch: return L10n.t("update.error.digestMismatch")
            case .unarchiveFailed(let detail):
                return detail.isEmpty ? L10n.t("update.error.unarchive")
                                      : L10n.t("update.error.unarchive.detail", detail)
            case .bundleMismatch: return L10n.t("update.error.bundleMismatch")
            case .invalidSignature(let detail):
                return detail.isEmpty ? L10n.t("update.error.signature")
                                      : L10n.t("update.error.signature.detail", detail)
            case .notRunningAsApp: return L10n.t("update.error.notApp")
            case .appUnavailable: return L10n.t("update.error.appUnavailable")
            case .helperUnavailable: return L10n.t("update.error.helperUnavailable")
            case .installDirectoryNotWritable(let path):
                return L10n.t("update.error.readOnly", path)
            }
        }
    }
}

/// SemVer comparison sufficient for GitHub tags: ignore build metadata, rank stable above
/// matching prereleases, and order numeric prerelease identifiers below textual ones.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    private let numbers: [Int]
    private let prerelease: [Identifier]
    private let rendered: String

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        value = String(value.split(separator: "+", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0])
        let pieces = value.split(separator: "-", maxSplits: 1,
                                 omittingEmptySubsequences: false)
        let rawNumbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !rawNumbers.isEmpty,
              rawNumbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let parsed = try? rawNumbers.map({ part -> Int in
                  guard let number = Int(part) else { throw VersionError.overflow }
                  return number
              }) else { return nil }
        let rawPrerelease = pieces.count > 1
            ? pieces[1].split(separator: ".", omittingEmptySubsequences: false) : []
        guard rawPrerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        numbers = parsed
        prerelease = rawPrerelease.map { Identifier(String($0)) }
        rendered = value
    }

    /// Preserve the tag's spelling: a `v1.2` release produces an asset and Info.plist version of `1.2`.
    /// Zero-padding for comparison must not cause a lookup for a nonexistent `HourGlow-1.2.0.zip`.
    var description: String { rendered }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalizedNumbers == rhs.normalizedNumbers && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left != right { return left < right }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private var normalizedNumbers: [Int] {
        var value = numbers
        while value.count > 3, value.last == 0 { value.removeLast() }
        while value.count < 3 { value.append(0) }
        return value
    }

    private struct Identifier: Comparable, Sendable {
        let raw: String
        let number: Int?

        init(_ raw: String) {
            self.raw = raw
            number = raw.allSatisfy(\.isNumber) ? Int(raw) : nil
        }

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs.number, rhs.number) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.raw < rhs.raw
            }
        }
    }

    private enum VersionError: Error { case overflow }
}
