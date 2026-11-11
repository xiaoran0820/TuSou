import Foundation
import Observation
import Photos
import UIKit

/// 全局状态：持有各个服务，处理权限与深链接。
/// 整个 App 不包含任何网络请求：识别、索引、检索全部在本机完成。
@Observable @MainActor
final class AppModel {
    enum Tab: Hashable { case search, imported, settings }

    /// MobileCLIP 的状态：加载中 / 可用 / 不可用（模型文件不在 App 里，或这台设备跑不了）
    enum SemanticStatus: Equatable { case loading, ready, unavailable }

    var tab: Tab = .search
    private(set) var photoStatus: PHAuthorizationStatus = PhotoLibraryService.authorizationStatus
    private(set) var semanticStatus: SemanticStatus = .loading

    let imports: ImportedImageStore
    let engine: IndexingEngine
    let search: SearchModel
    /// iOS 自带的翻译（本机完成）：中文查询整句译成英文，交给 MobileCLIP
    let translator: SystemTranslator

    @ObservationIgnored private var started = false

    init() {
        imports = ImportedImageStore()
        engine = IndexingEngine(imports: imports)
        search = SearchModel(engine: engine)
        translator = SystemTranslator()
        search.translator = translator
        translator.onChange = { [weak search] in search?.translationChanged() }
    }

    var canReadPhotos: Bool { PhotoLibraryService.canRead(photoStatus) }

    /// 作为单元测试的宿主启动时为 true：此时不扫描相册、不建索引，测试只用自己构造的数据
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func start() async {
        guard !started, !Self.isHostingUnitTests else { return }
        started = true
        Task.detached(priority: .utility) { SemanticExpander.shared.warmUp() }
        Task.detached(priority: .utility) { _ = Glossary.shared.count }   // 中英对照表约 10 万条，提前在后台读好
        await translator.refreshStatus()
        // MobileCLIP 和已有索引同时加载；模型好了以后，新分析的图片顺带算向量，已有的图片补算向量
        let clipLoad = Task.detached(priority: .userInitiated) { MobileCLIP.load() }
        await engine.bootstrap()
        let clip = await clipLoad.value
        semanticStatus = clip == nil ? .unavailable : .ready
        search.setTextEmbedder(clip)
        engine.setEmbedder(clip)
    }

    func requestPhotoAccess() async {
        photoStatus = await PhotoLibraryService.requestAuthorization()
        if canReadPhotos { engine.scheduleRescan() }
    }

    /// 回到前台时刷新权限（用户可能去系统设置里改过）；翻译语言也可能刚下载好或被删掉
    func refreshPhotoStatus() {
        let old = photoStatus
        photoStatus = PhotoLibraryService.authorizationStatus
        if old != photoStatus { engine.scheduleRescan() }
        if started { Task { await translator.refreshStatus() } }
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
        case .results: return search.showsAllHits ? search.outcome.hits.map(\.id) : search.outcome.primaryHits.map(\.id)
        case .partialResults: return search.outcome.collapsedHits.map(\.id)
        case .all: return engine.orderedIDs
        case .imported: return importedItems.map(\.id)
        }
    }

    /// 「导入」页的顺序：平常按导入时间倒序；评测模式按文件名排（IMG_01、IMG_02 …），方便对照编号
    var importedItems: [ImportedImageStore.Item] {
        guard search.evalMode else { return imports.items }
        return imports.items.sorted { $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending }
    }

    /// 评测模式下缩略图左上角显示的编号：导入图片的文件名去掉扩展名；相册照片没有
    func evalNames() -> [String: String] {
        Dictionary(imports.items.map { ($0.id, ImportedImageStore.displayStem(of: $0.originalName)) },
                   uniquingKeysWith: { a, _ in a })
    }
}

/// results：搜索结果主列表；partialResults：展开后的「只符合部分条件」
enum GridContext: Hashable { case results, partialResults, all, imported }

struct DetailRoute: Hashable {
    let context: GridContext
    let id: String
}
