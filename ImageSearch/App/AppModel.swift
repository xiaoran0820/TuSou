import Foundation
import Observation
import Photos
import UIKit

/// 全局状态：持有各个服务，处理权限与深链接。
/// 整个 App 不包含任何网络请求：识别、索引、检索全部在本机完成。
@Observable @MainActor
final class AppModel {
    enum Tab: Hashable { case search, imported, settings }

    var tab: Tab = .search
    private(set) var photoStatus: PHAuthorizationStatus = PhotoLibraryService.authorizationStatus

    let imports: ImportedImageStore
    let engine: IndexingEngine
    let search: SearchModel

    @ObservationIgnored private var started = false

    init() {
        imports = ImportedImageStore()
        engine = IndexingEngine(imports: imports)
        search = SearchModel(engine: engine)
    }

    var canReadPhotos: Bool { PhotoLibraryService.canRead(photoStatus) }

    /// 作为单元测试的宿主启动时为 true：此时不扫描相册、不建索引，测试只用自己构造的数据
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func start() async {
        guard !started, !Self.isHostingUnitTests else { return }
        started = true
        Task.detached(priority: .utility) { SemanticExpander.shared.warmUp() }
        await engine.bootstrap()
    }

    func requestPhotoAccess() async {
        photoStatus = await PhotoLibraryService.requestAuthorization()
        if canReadPhotos { engine.scheduleRescan() }
    }

    /// 回到前台时刷新权限（用户可能去系统设置里改过）
    func refreshPhotoStatus() {
        let old = photoStatus
        photoStatus = PhotoLibraryService.authorizationStatus
        if old != photoStatus { engine.scheduleRescan() }
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    /// 深链接：tusou://search?q=海边（可用于快捷指令、Spotlight 等，不联网）
    func handle(url: URL) {
        guard url.scheme == "tusou",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return }
        tab = .search
        search.query = q
    }

    /// 详情页需要的图片列表（与当前所在页面一致，可左右翻页）
    func ids(for context: GridContext) -> [String] {
        switch context {
        case .results: return search.outcome.hits.map(\.id)
        case .all: return engine.orderedIDs
        case .imported: return imports.items.map(\.id)
        }
    }
}

enum GridContext: Hashable { case results, all, imported }

struct DetailRoute: Hashable {
    let context: GridContext
    let id: String
}
