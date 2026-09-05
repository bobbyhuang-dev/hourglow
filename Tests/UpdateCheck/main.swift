import Foundation

// The subprocess caches Bundle.main before an external move of the entire directory, covering the real-world case where the process stays alive but its path changes.
if CommandLine.arguments.contains("--installation-probe") {
    let initialBundle = Bundle.main.bundleURL.path
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    while readLine() != nil {
        var result: [String: Any] = ["initialBundle": initialBundle,
                                     "available": AppUpdater.isAvailable,
                                     "legacyAvailable": Bundle.main.bundleURL.pathExtension == "app"
                                         && FileManager.default.isExecutableFile(atPath:
                                             Bundle.main.bundleURL.appendingPathComponent(
                                                 "Contents/Helpers/HourGlowUpdater").path)]
        do {
            let location = try AppUpdater.installation()
            try AppUpdater.requireInstallableLocation()
            result["app"] = location.app.path
            result["helper"] = location.helper.path
        } catch {
            switch error {
            case AppUpdater.UpdateError.notRunningAsApp: result["error"] = "notApp"
            case AppUpdater.UpdateError.appUnavailable: result["error"] = "appUnavailable"
            case AppUpdater.UpdateError.helperUnavailable: result["error"] = "helperUnavailable"
            default: result["error"] = error.localizedDescription
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    exit(0)
}

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

let responseNow = Date(timeIntervalSince1970: 1_788_566_400)
func responseError(_ status: Int, headers: [String: String] = [:],
                   message: String? = nil) -> AppUpdater.UpdateError? {
    let response = HTTPURLResponse(url: URL(string: "https://api.github.com/fixture")!,
                                   statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
    let data = message.map { try! JSONEncoder().encode(["message": $0]) }
    do {
        try AppUpdater.requireSuccess(response, data: data, now: responseNow)
        return nil
    } catch { return error as? AppUpdater.UpdateError }
}

let resetHeaders = ["x-ratelimit-remaining": "0",
                    "x-ratelimit-reset": String(responseNow.timeIntervalSince1970 + 600)]
if case .rateLimited(let limit) = responseError(403, headers: resetHeaders) {
    check(limit.notice == .reset && limit.retryAt == responseNow.addingTimeInterval(601),
          "403 primary quota exhaustion reads the reset time with a one-second boundary margin")
    let suiteName = "hourglow-updatecheck-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    AppUpdater.rememberRateLimit(limit, defaults: defaults)
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == limit,
          "The rate-limit deadline can be restored from preferences and survives restarts")
    check(AppUpdater.pendingRateLimit(now: limit.retryAt.addingTimeInterval(-1),
                                      defaults: defaults) != nil,
          "Do not send further requests before the reset deadline")
    check(AppUpdater.pendingRateLimit(now: limit.retryAt, defaults: defaults) == nil,
          "Allow checking again once the deadline arrives")
    AppUpdater.rememberRateLimit(nil, defaults: defaults)
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == nil,
          "A successful request can clear the previous rate-limit state")
    defaults.set(Data("broken".utf8), forKey: "updates.rateLimit")
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == nil,
          "Damaged rate-limit preferences do not block updates")
    for language in ["zh-Hans", "en"] {
        setenv("HOURGLOW_LANG", language, 1)
        L10n.invalidate()
        let description = limit.localizedDescription
        check(!description.contains("update.error") && description.contains("GitHub")
              && description.contains("\n"), "\(language) rate-limit notice includes the reason and a separate recovery-time line")
    }
} else { check(false, "403 quota exhaustion must be recognized as rate limiting") }

for status in [403, 429] {
    if case .rateLimited(let limit) = responseError(status, headers: ["Retry-After": "120"]) {
        check(limit.notice == .retry && limit.retryAt == responseNow.addingTimeInterval(121),
              "\(status) Retry-After seconds are converted to a retry time")
    } else { check(false, "\(status) Retry-After must be recognized as rate limiting") }
}
var combinedHeaders = resetHeaders
combinedHeaders["retry-after"] = "900"
if case .rateLimited(let limit) = responseError(403, headers: combinedHeaders) {
    check(limit.notice == .retry && limit.retryAt == responseNow.addingTimeInterval(901),
          "Honor the later deadline when both are present")
} else { check(false, "Combined rate-limit headers should parse") }

let httpDate = DateFormatter()
httpDate.locale = Locale(identifier: "en_US_POSIX")
httpDate.timeZone = TimeZone(secondsFromGMT: 0)
httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
if case .rateLimited(let limit) = responseError(429, headers: [
    "Retry-After": httpDate.string(from: responseNow.addingTimeInterval(180))]) {
    check(limit.retryAt == responseNow.addingTimeInterval(181), "Retry-After also supports HTTP dates")
} else { check(false, "HTTP dates should parse") }

for value in ["missing", "NaN", "inf", "-1", "1e100", "0"] {
    if case .rateLimited(let limit) = responseError(403, headers: [
        "x-ratelimit-remaining": "0", "x-ratelimit-reset": value]) {
        check(limit.notice == .unknown && limit.retryAt == responseNow.addingTimeInterval(60),
              "Invalid or expired reset value \(value) does not invent a recovery time and waits at least one minute")
    } else { check(false, "Primary rate limiting must still be recognized without a valid time") }
}
if case .rateLimited(let limit) = responseError(403, headers: [
    "x-ratelimit-remaining": "12", "x-ratelimit-reset": resetHeaders["x-ratelimit-reset"]!
], message: "You have exceeded a secondary rate limit.") {
    check(limit.notice == .unknown, "Recognize secondary rate limiting from the response body without misusing the primary quota reset time")
} else { check(false, "Secondary rate limiting should be recognized") }
if case .rateLimited(let limit) = responseError(429) {
    check(limit.notice == .unknown, "Report honestly when a 429 has no recovery time")
} else { check(false, "A 429 without response headers is still rate limiting") }
if case .forbidden = responseError(403) {
    check(true, "An ordinary 403 reports a rejected request, not quota exhaustion")
} else { check(false, "An ordinary 403 must not be misreported as rate limiting") }
if case .badResponse(500) = responseError(500, headers: resetHeaders) {
    check(true, "A 500 is still handled as a server error")
} else { check(false, "Server errors must not be treated as rate limiting") }
check(responseError(200, headers: resetHeaders) == nil, "A successful response is handled normally even if it just exhausted the quota")

check(AppVersion("1.2.0")! > AppVersion("1.1.9")!, "Compare versions numerically rather than lexicographically")
check(AppVersion("1.10.0")! > AppVersion("1.9.0")!, "Multi-digit version components are still compared numerically")
check(AppVersion("v1.2")! == AppVersion("1.2.0")!, "A v prefix and omitted trailing zeros do not affect version equality")
check(AppVersion("v1.2")!.description == "1.2", "Release asset names preserve the tag's version spelling")
check(AppVersion("1.2.0")! > AppVersion("1.2.0-beta.2")!, "A stable release ranks above a prerelease with the same version")
check(AppVersion("1.2.0-beta.10")! > AppVersion("1.2.0-beta.2")!, "Numeric prerelease identifiers are compared numerically")
check(AppVersion("不是版本") == nil, "Reject invalid version strings")
check(AppUpdater.sha256(of: Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "SHA-256 matches the standard test vector")

do {
    // 200,000 bytes greatly exceeds the macOS pipe buffer. The old implementation waited for exit before reading output, deadlocking parent and child here.
    let result = try AppUpdater.runProcess(
        "/usr/bin/awk",
        [#"BEGIN { for (i = 0; i < 20000; i++) printf "0123456789" }"#])
    check(result.status == 0 && result.output.utf8.count == 200_000,
          "Large subprocess output does not fill the pipe and deadlock")
} catch {
    check(false, "Large subprocess output can be read completely: \(error)")
}

let fixture = Data(#"""
{
  "tag_name": "v1.2.0",
  "body": "改进更新功能",
  "html_url": "https://github.com/bobbyhuang-dev/hourglow/releases/tag/v1.2.0",
  "draft": false,
  "prerelease": false,
  "assets": [{
    "name": "HourGlow-1.2.0.zip",
    "browser_download_url": "https://github.com/bobbyhuang-dev/hourglow/releases/download/v1.2.0/HourGlow-1.2.0.zip",
    "size": 654321,
    "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }]
}
"""#.utf8)

do {
    let release = try AppUpdater.release(from: fixture, currentVersion: "1.1.0")
    check(release?.version == "1.2.0", "Parse a stable release newer than the current version")
    check(release?.byteCount == 654321, "Preserve the download size")
    check(release?.sha256.hasPrefix("01234567") == true, "Use the GitHub asset digest")
    let same = try AppUpdater.release(from: fixture, currentVersion: "1.2.0")
    let newer = try AppUpdater.release(from: fixture, currentVersion: "1.3.0")
    check(same == nil, "Do not update to the same version again")
    check(newer == nil, "Do not downgrade a newer development version")
} catch {
    check(false, "The release fixture should parse: \(error)")
}

let untrusted = Data(String(decoding: fixture, as: UTF8.self)
    .replacingOccurrences(of: "https://github.com/bobbyhuang-dev/hourglow/releases/download/",
                          with: "https://example.com/").utf8)
do {
    _ = try AppUpdater.release(from: untrusted, currentVersion: "1.1.0")
    check(false, "Reject download URLs outside the repository")
} catch AppUpdater.UpdateError.unexpectedDownloadURL {
    check(true, "Reject download URLs outside the repository")
} catch {
    check(false, "The download URL error has the correct type: \(error)")
}

let noDigest = Data(String(decoding: fixture, as: UTF8.self)
    .replacingOccurrences(of: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                          with: "").utf8)
do {
    _ = try AppUpdater.release(from: noDigest, currentVersion: "1.1.0")
    check(false, "Reject release packages without SHA-256")
} catch AppUpdater.UpdateError.missingDigest {
    check(true, "Reject release packages without SHA-256")
} catch {
    check(false, "The digest error has the correct type: \(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) update tests failed\n".utf8))
    exit(1)
}
print("\nAll update tests passed")
