import UIKit

/// 统一加载缩略图 / 大图（相册照片走 PhotoKit，导入图片读沙盒文件），带内存缓存
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()

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

    private func load(id: String, maxPixel: CGFloat, highQuality: Bool) async -> UIImage? {
        let key = "\(id)#\(Int(maxPixel))" as NSString
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
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}
