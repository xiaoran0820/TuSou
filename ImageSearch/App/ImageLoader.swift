import UIKit

/// 统一加载缩略图 / 大图（相册照片走 PhotoKit，导入图片读沙盒文件），带内存缓存。
/// 照片被编辑或删除时，索引引擎调用 `invalidate(ids:)`：该图片的版本号 +1，旧缓存不会再被用到，界面会重新加载。
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()
    private let lock = NSLock()
    private var versions: [String: Int] = [:]

    static var importedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imported", isDirectory: true)
    }

    func thumbnail(for id: String, pixelSize: CGFloat) async -> UIImage? {
        await load(id: id, maxPixel: pixelSize, highQuality: true)
    }

    /// 详情页大图（只用本机数据）
    func fullImage(for id: String) async -> UIImage? {
        await load(id: id, maxPixel: 2400, highQuality: true)
    }

    /// 图片内容的版本：照片被编辑或删除后会变
    func version(of id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return versions[id] ?? 0
    }

    /// 照片被编辑或删除：作废这些图片已缓存的缩略图和大图
    func invalidate(ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in ids { versions[id, default: 0] += 1 }
    }

    /// 缓存键带版本号：版本一变，旧图就不会再命中
    func cacheKey(for id: String, maxPixel: CGFloat) -> NSString {
        "\(id)#v\(version(of: id))#\(Int(maxPixel))" as NSString
    }

    private func load(id: String, maxPixel: CGFloat, highQuality: Bool) async -> UIImage? {
        let key = cacheKey(for: id, maxPixel: maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let raw = ImageID.rawValue(of: id)
        let image: UIImage?
        switch ImageID.source(of: id) {
        case .photoLibrary:
            image = await PhotoLibraryService.loadImage(localIdentifier: raw, maxPixel: maxPixel, highQuality: highQuality)
        case .imported:
            let url = Self.importedDirectory.appendingPathComponent(raw)
            image = await Task.detached(priority: .userInitiated) {
                ImageAnalyzer.downsampledImage(at: url, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
            }.value
        }
        // 用开始加载时的键存：加载期间若照片被编辑，这张旧图只会存在旧版本下
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}
