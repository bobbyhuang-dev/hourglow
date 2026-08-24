import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

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
