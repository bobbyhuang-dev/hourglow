import Foundation

struct AerialAsset: Identifiable, Equatable {
    let id: String
    let name: String
    let shotID: String
    let categories: [String]
    let order: Int
    let thumbnailURL: URL
    let videoURL: URL

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: videoURL.path)
    }

    /// 已下载视频的体积，单位 MB。未下载时为 nil。
    var sizeMB: Int? {
        guard let values = try? videoURL.resourceValues(forKeys: [.fileSizeKey]),
              let bytes = values.fileSize else { return nil }
        return bytes / 1_000_000
    }
}

/// 系统 aerial 素材库的只读视图。
enum AerialCatalog {

    static var rootURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    static var entriesURL: URL { rootURL.appendingPathComponent("manifest/entries.json") }

    private struct Manifest: Decodable {
        struct Asset: Decodable {
            let id: String
            let accessibilityLabel: String?
            let shotID: String?
            let categories: [String]?
            let preferredOrder: Int?
        }
        struct Category: Decodable {
            let id: String
            let localizedNameKey: String?
        }
        let assets: [Asset]
        let categories: [Category]
    }

    static func load() throws -> [AerialAsset] {
        let data = try Data(contentsOf: entriesURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)

        var categoryNames: [String: String] = [:]
        for category in manifest.categories {
            let key = category.localizedNameKey ?? category.id
            categoryNames[category.id] = key.hasPrefix("AerialCategory")
                ? String(key.dropFirst("AerialCategory".count))
                : key
        }

        return manifest.assets.map { asset in
            AerialAsset(
                id: asset.id,
                name: asset.accessibilityLabel ?? asset.shotID ?? asset.id,
                shotID: asset.shotID ?? "",
                categories: (asset.categories ?? []).compactMap { categoryNames[$0] },
                order: asset.preferredOrder ?? Int.max,
                thumbnailURL: rootURL.appendingPathComponent("thumbnails/\(asset.id).png"),
                videoURL: rootURL.appendingPathComponent("videos/\(asset.id).mov")
            )
        }
        .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// 便于把 assetID 显示成人类可读的名字。
    static func name(for assetID: String) -> String? {
        try? load().first { $0.id == assetID }?.name
    }
}
