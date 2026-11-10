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
        // 高质量版本拿不到（原图只在 iCloud、出错、超时）时退回本机预览图；任务已取消就不再发请求
        guard highQuality, !Task.isCancelled else { return nil }
        return await request(asset, maxPixel: maxPixel, highQuality: false)
    }

    /// 单次请求最长等多久：本机取图远快于这个值，超过说明 PhotoKit 没有给出最终回调
    static let requestTimeout: TimeInterval = 15

    private static func request(_ asset: PHAsset, maxPixel: CGFloat, highQuality: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = highQuality ? .highQualityFormat : .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false   // 完全本地运行：不联网
        options.isSynchronous = false
        options.version = .current
        let target = CGSize(width: maxPixel, height: maxPixel)
        let state = ImageRequestState(highQuality: highQuality)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                guard state.begin(cont) else { return }   // 发请求前任务就被取消了
                let id = PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                               options: options) { image, info in
                    state.handle(image: image, info: info)
                }
                state.setRequestID(id)
                // 兜底：最终回调一直不来，就取消请求、结束等待（不会永远卡住索引）
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout) {
                    state.cancel()
                }
            }
        } onCancel: {
            state.cancel()   // Swift 任务被取消：同时取消 PhotoKit 请求
        }
    }

    static func originalFileName(localIdentifier: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }
}

/// 一次 PhotoKit 取图请求的状态。等待只会结束一次，结束的原因可能是：
/// 最终回调（有图或无图）、取消/出错的回调、Swift 任务取消、超时。
/// 高质量请求中途送来的降级预览不算结束：PhotoKit 之后还会给最终回调，若一直不给，由超时兜底。
final class ImageRequestState: @unchecked Sendable {
    enum CallbackKind: Equatable {
        case keepWaiting   // 高质量请求的降级预览
        case finished      // 最终结果（图可能为空，如原图只在 iCloud）
        case failed        // 请求被取消或出错
    }

    private let lock = NSLock()
    private let highQuality: Bool
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var finished = false

    init(highQuality: Bool,
         cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void = { PHImageManager.default().cancelImageRequest($0) }) {
        self.highQuality = highQuality
        self.cancelRequest = cancelRequest
    }

    static func classify(info: [AnyHashable: Any]?, highQuality: Bool) -> CallbackKind {
        if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil { return .failed }
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        return degraded && highQuality ? .keepWaiting : .finished
    }

    /// 开始等待。若在这之前已经被取消，立即以 nil 结束并返回 false（不必再发请求）
    func begin(_ c: CheckedContinuation<UIImage?, Never>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); c.resume(returning: nil); return false }
        continuation = c
        lock.unlock()
        return true
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let alreadyFinished = finished
        lock.unlock()
        // 发请求的同时已被取消：请求本身也撤掉（对已正常完成的请求没有影响）
        if alreadyFinished { cancelRequest(id) }
    }

    /// PhotoKit 的回调（可能来不止一次）
    func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        switch Self.classify(info: info, highQuality: highQuality) {
        case .keepWaiting: break
        case .finished: finish(image)
        case .failed: finish(nil)
        }
    }

    /// 任务取消或超时：以 nil 结束，并取消 PhotoKit 请求
    func cancel() {
        lock.lock()
        let id = requestID
        lock.unlock()
        if finish(nil), let id { cancelRequest(id) }
    }

    @discardableResult
    private func finish(_ image: UIImage?) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: image)
        return true
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
