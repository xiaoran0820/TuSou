import Foundation
import Photos
import UIKit

/// 相册里一张照片的快照（只读元数据）
struct AssetSnapshot: Sendable {
    let id: String               // ImageID（带 p: 前缀）
    let localIdentifier: String
    let modificationDate: Date?
    let meta: ImageMeta
}

/// PhotoKit 封装：权限、读取照片列表、监听相册变化、按需取图
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    /// 相册有变化（新拍照片、删除、编辑、有限访问的选择变化）时回调
    var onChange: (@Sendable () -> Void)?
    private var isObserving = false

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func canRead(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    func startObserving() {
        guard !isObserving, Self.canRead(Self.authorizationStatus) else { return }
        isObserving = true
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }

    /// 读取全部照片（不含视频），按拍摄时间倒序
    func fetchSnapshots() -> [AssetSnapshot] {
        guard Self.canRead(Self.authorizationStatus) else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        // 自拍相簿（系统智能相簿）
        var selfies = Set<String>()
        if let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).firstObject {
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in selfies.insert(a.localIdentifier) }
        }

        var out: [AssetSnapshot] = []
        out.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let sub = asset.mediaSubtypes
            let meta = ImageMeta(
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                isScreenshot: sub.contains(.photoScreenshot),
                isSelfie: selfies.contains(asset.localIdentifier),
                isPanorama: sub.contains(.photoPanorama),
                isLivePhoto: sub.contains(.photoLive),
                isPortrait: sub.contains(.photoDepthEffect))
            out.append(AssetSnapshot(id: ImageID.photo(asset.localIdentifier), localIdentifier: asset.localIdentifier,
                                     modificationDate: asset.modificationDate, meta: meta))
        }
        return out
    }

    /// 取一张图（用于 Vision 分析或显示）。只读本机数据，绝不从 iCloud 下载：
    /// 若开启了「优化 iPhone 储存空间」而原图只在 iCloud，就退而使用本机保存的预览图。
    static func loadImage(localIdentifier: String, maxPixel: CGFloat, highQuality: Bool = true) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        if let image = await request(asset, maxPixel: maxPixel, highQuality: highQuality) { return image }
        return highQuality ? await request(asset, maxPixel: maxPixel, highQuality: false) : nil
    }

    private static func request(_ asset: PHAsset, maxPixel: CGFloat, highQuality: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = highQuality ? .highQualityFormat : .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false   // 完全本地运行：不联网
        options.isSynchronous = false
        options.version = .current
        let target = CGSize(width: maxPixel, height: maxPixel)

        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let once = ResumeOnce(cont)
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                  options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded && highQuality { return }   // 等高质量版本
                once.resume(image)
            }
        }
    }

    static func originalFileName(localIdentifier: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }
}

/// 保证 continuation 只 resume 一次（PhotoKit 回调可能多次触发）
final class ResumeOnce<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
