import Foundation

// 子进程先缓存 Bundle.main，再由外部移动整个目录，覆盖「进程没退、路径已变」的实机场景。
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
          "403 主额度耗尽读取重置时刻，并留一秒边界余量")
    let suiteName = "hourglow-updatecheck-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    AppUpdater.rememberRateLimit(limit, defaults: defaults)
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == limit,
          "限流期限可从偏好中恢复，重启不丢失")
    check(AppUpdater.pendingRateLimit(now: limit.retryAt.addingTimeInterval(-1),
                                      defaults: defaults) != nil,
          "重置期限之前不再发请求")
    check(AppUpdater.pendingRateLimit(now: limit.retryAt, defaults: defaults) == nil,
          "期限到达后允许重新检查")
    AppUpdater.rememberRateLimit(nil, defaults: defaults)
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == nil,
          "请求成功后可清除旧限流状态")
    defaults.set(Data("broken".utf8), forKey: "updates.rateLimit")
    check(AppUpdater.pendingRateLimit(now: responseNow, defaults: defaults) == nil,
          "损坏的限流偏好不会阻止更新")
    for language in ["zh-Hans", "en"] {
        setenv("HOURGLOW_LANG", language, 1)
        L10n.invalidate()
        let description = limit.localizedDescription
        check(!description.contains("update.error") && description.contains("GitHub")
              && description.contains("\n"), "\(language) 限流提示包含原因与独立的恢复时间行")
    }
} else { check(false, "403 额度耗尽必须识别为限流") }

for status in [403, 429] {
    if case .rateLimited(let limit) = responseError(status, headers: ["Retry-After": "120"]) {
        check(limit.notice == .retry && limit.retryAt == responseNow.addingTimeInterval(121),
              "\(status) Retry-After 秒数转成可重试的时刻")
    } else { check(false, "\(status) Retry-After 必须识别为限流") }
}
var combinedHeaders = resetHeaders
combinedHeaders["retry-after"] = "900"
if case .rateLimited(let limit) = responseError(403, headers: combinedHeaders) {
    check(limit.notice == .retry && limit.retryAt == responseNow.addingTimeInterval(901),
          "同时存在两个期限时遵守更晚的那个")
} else { check(false, "组合限流头应能解析") }

let httpDate = DateFormatter()
httpDate.locale = Locale(identifier: "en_US_POSIX")
httpDate.timeZone = TimeZone(secondsFromGMT: 0)
httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
if case .rateLimited(let limit) = responseError(429, headers: [
    "Retry-After": httpDate.string(from: responseNow.addingTimeInterval(180))]) {
    check(limit.retryAt == responseNow.addingTimeInterval(181), "Retry-After 也支持 HTTP 日期")
} else { check(false, "HTTP 日期应能解析") }

for value in ["missing", "NaN", "inf", "-1", "1e100", "0"] {
    if case .rateLimited(let limit) = responseError(403, headers: [
        "x-ratelimit-remaining": "0", "x-ratelimit-reset": value]) {
        check(limit.notice == .unknown && limit.retryAt == responseNow.addingTimeInterval(60),
              "无效或已过期的重置值 \(value) 不编造恢复时间，并至少等待一分钟")
    } else { check(false, "无有效时刻的主限流仍应识别") }
}
if case .rateLimited(let limit) = responseError(403, headers: [
    "x-ratelimit-remaining": "12", "x-ratelimit-reset": resetHeaders["x-ratelimit-reset"]!
], message: "You have exceeded a secondary rate limit.") {
    check(limit.notice == .unknown, "二次限流从响应正文识别，不误用主额度重置时间")
} else { check(false, "二次限流应能识别") }
if case .rateLimited(let limit) = responseError(429) {
    check(limit.notice == .unknown, "429 无恢复时间时如实说明")
} else { check(false, "无响应头的 429 仍属于限流") }
if case .forbidden = responseError(403) {
    check(true, "普通 403 报请求被拒绝，不误报额度耗尽")
} else { check(false, "普通 403 不能误报限流") }
if case .badResponse(500) = responseError(500, headers: resetHeaders) {
    check(true, "500 仍按服务器错误处理")
} else { check(false, "不能把服务器错误当成限流") }
check(responseError(200, headers: resetHeaders) == nil, "成功响应即使恰好耗尽额度也正常处理")

check(AppVersion("1.2.0")! > AppVersion("1.1.9")!, "版本按数字而不是字符串比较")
check(AppVersion("1.10.0")! > AppVersion("1.9.0")!, "多位版本号仍按数值比较")
check(AppVersion("v1.2")! == AppVersion("1.2.0")!, "v 前缀与省略的补零不影响版本")
check(AppVersion("v1.2")!.description == "1.2", "发布资源名保留 tag 的版本写法")
check(AppVersion("1.2.0")! > AppVersion("1.2.0-beta.2")!, "正式版高于同号预发布版")
check(AppVersion("1.2.0-beta.10")! > AppVersion("1.2.0-beta.2")!, "预发布数字标识按数值比较")
check(AppVersion("不是版本") == nil, "拒绝无效版本号")
check(AppUpdater.sha256(of: Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "SHA-256 与标准向量一致")

do {
    // 20 万字节远大于 macOS 管道缓冲区。旧实现先等进程退出再读输出，父子会在这里互等。
    let result = try AppUpdater.runProcess(
        "/usr/bin/awk",
        [#"BEGIN { for (i = 0; i < 20000; i++) printf "0123456789" }"#])
    check(result.status == 0 && result.output.utf8.count == 200_000,
          "子进程大量输出不会堵满管道而卡死")
} catch {
    check(false, "大量子进程输出可以完整读取：\(error)")
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
    check(release?.version == "1.2.0", "解析比当前版本新的正式 Release")
    check(release?.byteCount == 654321, "保留下载大小")
    check(release?.sha256.hasPrefix("01234567") == true, "采用 GitHub asset digest")
    let same = try AppUpdater.release(from: fixture, currentVersion: "1.2.0")
    let newer = try AppUpdater.release(from: fixture, currentVersion: "1.3.0")
    check(same == nil, "同版本不重复更新")
    check(newer == nil, "不会把开发中的较新版本降级")
} catch {
    check(false, "Release fixture 应能解析：\(error)")
}

let untrusted = Data(String(decoding: fixture, as: UTF8.self)
    .replacingOccurrences(of: "https://github.com/bobbyhuang-dev/hourglow/releases/download/",
                          with: "https://example.com/").utf8)
do {
    _ = try AppUpdater.release(from: untrusted, currentVersion: "1.1.0")
    check(false, "拒绝仓库之外的下载地址")
} catch AppUpdater.UpdateError.unexpectedDownloadURL {
    check(true, "拒绝仓库之外的下载地址")
} catch {
    check(false, "下载地址错误类型正确：\(error)")
}

let noDigest = Data(String(decoding: fixture, as: UTF8.self)
    .replacingOccurrences(of: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                          with: "").utf8)
do {
    _ = try AppUpdater.release(from: noDigest, currentVersion: "1.1.0")
    check(false, "拒绝没有 SHA-256 的发布包")
} catch AppUpdater.UpdateError.missingDigest {
    check(true, "拒绝没有 SHA-256 的发布包")
} catch {
    check(false, "digest 错误类型正确：\(error)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项更新测试失败\n".utf8))
    exit(1)
}
print("\n全部更新测试通过")
