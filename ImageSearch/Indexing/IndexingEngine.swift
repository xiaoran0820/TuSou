import Foundation
import Observation
import UIKit

/// 相册照片的来源。默认是 PhotoKit（PhotoLibraryService）；测试时换成假的照片列表。
protocol PhotoSource: AnyObject, Sendable {
    /// 相册有变化（新拍、删除、编辑、有限访问的选择变化）时回调
    var onChange: (@Sendable () -> Void)? { get set }
    func startObserving()
    func fetchSnapshots() -> [AssetSnapshot]
}

extension PhotoLibraryService: PhotoSource {}

/// 界面上显示的索引统计
struct IndexStats: Equatable, Sendable {
    var indexed = 0
    var failed = 0
    var unavailable: RecordFlags = []
    /// 已有当前 MobileCLIP 模型向量的图片数
    var embedded = 0
    /// 画面已识别、图中文字还在等第二步的图片数
    var textPending = 0
    /// 只拿到很小预览图的图片数
    var smallPreview = 0

    /// 只统计当前存在的图片（ids）；已移除、但数据库还没删掉的旧记录不算
    static func compute(ids: [String], records: [String: ImageRecord], embeddingModel: String? = nil) -> IndexStats {
        var s = IndexStats()
        for id in ids {
            guard let r = records[id] else { continue }
            s.indexed += 1
            if r.flags.contains(.analysisFailed) { s.failed += 1 }
            s.unavailable.formUnion(IndexingEngine.unavailableAnalyses(of: r))
            if let m = embeddingModel, r.hasEmbedding(from: m) { s.embedded += 1 }
            if r.flags.contains(.textRecognitionPending) { s.textPending += 1 }
            if r.flags.contains(.smallPreview) { s.smallPreview += 1 }
        }
        return s
    }
}

/// 已经读进内存、做完画面识别的图，交给文字识别接着用（流水线），不用再读一次
final class AnalysisImage: @unchecked Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
    init(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) {
        self.cgImage = cgImage
        self.orientation = orientation
    }
}

/// 第一步做完的图放在这里，等建索引的调度把它们排进文字识别（多个线程同时用，加锁）
final class ImageHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: AnalysisImage] = [:]

    func put(_ id: String, _ image: AnalysisImage) { lock.lock(); images[id] = image; lock.unlock() }

    func take(_ id: String) -> AnalysisImage? {
        lock.lock(); defer { lock.unlock() }
        return images.removeValue(forKey: id)
    }
}

/// 索引调度：对比相册/导入图片与已有索引，增量分析新增或修改过的图片，删除已不存在的。
/// 新照片优先（按时间倒序处理），分批写库，边建边可搜。全部在本机完成，不联网。
///
/// 默认分两步：第一步做画面分类、人脸、二维码条码和 MobileCLIP，多开几路并行，做完整个相册就能按画面搜；
/// 文字识别（最花时间）同时以流水线的方式跟着做：第一步读进来的图直接在内存里交给最多 2 路文字识别，
/// 跟不上的标「文字待识别」，第一步做完后再重新读图补上（第二步）。
/// 设置 › 评测模式里可以关掉，回到一张图一次做完的原来方式。
///
/// 一致性约定：
/// - 先写数据库，成功后才更新内存索引；写库失败的图片不算"已索引"，下次扫描重新分析。
/// - 删除也先删数据库，成功后才从内存移除；删除失败的记录留在内存里等下次扫描重试（不参与检索和计数）。
/// - 重建索引会换一个新的批次编号（epoch），并等旧任务完全停下；旧批次的结果一律丢弃，不会写回。
@Observable @MainActor
final class IndexingEngine {
    enum Phase: Equatable { case idle, loading, scanning, indexing, done }

    /// 待分析的一张图片
    enum WorkItem: Sendable {
        case photo(id: String, localIdentifier: String, modificationDate: Date?)
        case imported(id: String, url: URL)
        /// 其它识别都已完成，只缺 MobileCLIP 向量（例如刚装上模型）：只补算向量，不重跑画面和文字识别
        case embedding(record: ImageRecord, location: ImageLocation)
        /// 第一步已经做完，只差文字识别（建索引的第二步）
        case text(record: ImageRecord, location: ImageLocation)
        /// 第一步刚做完、图还在内存里：直接做文字识别（流水线），不用再读一次
        case textInMemory(record: ImageRecord, image: AnalysisImage)

        var id: String {
            switch self {
            case .photo(let id, _, _), .imported(let id, _): return id
            case .embedding(let record, _), .text(let record, _), .textInMemory(let record, _): return record.id
            }
        }
    }

    /// 补算向量时到哪里重新读图
    enum ImageLocation: Sendable {
        case photo(localIdentifier: String)
        case file(URL)
    }

    /// 分析一张图片时用到的设置
    struct AnalysisContext: Sendable {
        /// 当前可用的 MobileCLIP（没有就是 nil）
        var embedder: (any ImageEmbedder)?
        /// 文字识别留到第二步：记录标上「文字待识别」
        var deferText = false
        /// 第一步做完后，把还在内存里的图放进这里，交给流水线上的文字识别（没有就不交）
        var handoff: ImageHandoff?
    }

    /// 分析一张图片得到索引记录；返回 nil 表示任务被取消、这次不算。默认是 `IndexingEngine.process`
    typealias Analyzer = @Sendable (WorkItem, AnalysisContext) async -> ImageRecord?

    private(set) var phase: Phase = .idle
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    /// 索引内容每次变化 +1，界面据此刷新检索结果
    private(set) var revision = 0
    private(set) var indexedCount = 0
    private(set) var photoCount = 0
    private(set) var importedCount = 0
    private(set) var failedCount = 0
    private(set) var lastError: String?
    /// 索引数据库打不开：此时索引只在本次运行中有效，界面要明确提示
    private(set) var storageProblem: String?
    /// 最近一次扫描中没能写进数据库的图片数（不算已索引，下次扫描会重新分析）
    private(set) var unsavedCount = 0
    /// 当前版本索引里，有图片没跑成的识别项（如 iOS 模拟器跑不了画面识别和人脸检测，真机正常）
    private(set) var unavailableAnalyses: RecordFlags = []
    /// 当前设备无法运行 Vision 场景分类（iOS 模拟器的已知限制）
    var classifierUnavailable: Bool { unavailableAnalyses.contains(.classifierUnavailable) }
    /// 所有图片（相册 + 导入）按时间倒序
    private(set) var orderedIDs: [String] = []
    /// 正在清空并重建索引
    private(set) var isRebuilding = false
    /// 正在使用的 MobileCLIP 模型（nil 表示没有：模型未安装或还在加载）
    private(set) var semanticModel: String?
    /// 已有 MobileCLIP 向量的图片数
    private(set) var embeddedCount = 0
    /// 画面已识别、图中文字还在等第二步的图片数
    private(set) var textPendingCount = 0
    /// 只拿到很小预览图（原图多半只在 iCloud）的图片数
    private(set) var smallPreviewCount = 0
    /// 正在进行哪一步（界面显示「第 1 步：识别画面」「第 2 步：识别图中文字」）
    private(set) var currentPass: IndexPass?
    /// 最近一次建索引（20 张以上）各步的耗时，只在内存里
    private(set) var lastPassStats: [IndexPassStats] = []
    /// 建索引分两步（默认）。关掉就回到一张图一次做完的原来方式，用来在手机上对比速度
    var textInSecondPass: Bool {
        didSet { UserDefaults.standard.set(textInSecondPass, forKey: Self.textInSecondPassKey) }
    }
    static let textInSecondPassKey = "indexTextInSecondPass"
    /// 每次扫描最多分析多少张新图片（0 = 全部）。开发时用来跳过全量重建：设成 200，就每次只做 200 张，
    /// 其余的留到下次扫描，不会删记录、不会把图当成已索引
    var indexLimit: Int {
        didSet {
            UserDefaults.standard.set(indexLimit, forKey: Self.indexLimitKey)
            if indexLimit != oldValue { scheduleRescan() }
        }
    }
    static let indexLimitKey = "indexLimit"
    /// 开发用：先不做文字识别。记录标「文字待识别」，第二步也不跑，搜索会如实报告这些图还没检查
    var skipTextRecognition: Bool {
        didSet {
            UserDefaults.standard.set(skipTextRecognition, forKey: Self.skipTextRecognitionKey)
            if skipTextRecognition != oldValue { scheduleRescan() }
        }
    }
    static let skipTextRecognitionKey = "indexSkipText"
    /// 实验：小预览图（原图多半只在 iCloud）先不建语义向量。这类图本来画面识别就不准，
    /// 先跳过 CLIP 能明显缩短第一步；「重新扫描」时原图下载好了会重新识别
    nonisolated static let skipSmallPreviewEmbeddingKey = "skipSmallPreviewEmbedding"
    nonisolated static var skipSmallPreviewEmbedding: Bool {
        UserDefaults.standard.bool(forKey: skipSmallPreviewEmbeddingKey)
    }

    @ObservationIgnored private(set) var records: [String: ImageRecord] = [:]
    @ObservationIgnored private(set) var metas: [String: ImageMeta] = [:]

    @ObservationIgnored let photos: any PhotoSource
    @ObservationIgnored private let imports: ImportedImageStore
    @ObservationIgnored private let openStore: @Sendable () throws -> any IndexPersistence
    @ObservationIgnored private let analyze: Analyzer
    @ObservationIgnored private var embedder: (any ImageEmbedder)?
    @ObservationIgnored private var store: (any IndexPersistence)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var retryFailedRequested = false
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var ready = false
    /// 批次编号：每次重建 +1，旧批次的结果不再写回
    @ObservationIgnored private var epoch = 0
    /// 本轮扫描写库失败：停止继续分析（数据库恢复前，分析了也存不下）
    @ObservationIgnored private var persistFailedThisRound = false
    /// 统计信息最多每秒刷新一次：每写一批都全量统计一遍，在大图库上是主线程上的 O(n) 开销
    @ObservationIgnored private var lastCountsRefresh = Date.distantPast

    /// 同时分析的图片数。第一步不做文字识别，多开几路明显更快：Mac 上 1 路每张 32 毫秒、4 路 12 毫秒；
    /// iPhone 上 4 路跑完了 6,938 张（每张 78 毫秒的活摊成 20 毫秒）。
    /// 文字识别不能超过 2 路：模拟器里同时跑 4 个，Vision 内部限制并发的队列（VNControlledCapacityTasksQueue）
    /// 在第 2,861 张时互相等待、卡死不动（11-13）；2 路在 iPhone 上跑完了 6,938 张。原来的一步做完也是 2 路
    static func concurrency(for pass: IndexPass) -> Int {
        pass == .content ? 4 : 2
    }

    /// 只统计 20 张以上的建索引：新拍一两张照片的增量更新不覆盖整体建索引的耗时
    static let minImagesForStats = 20
    /// 第一步时，流水线上同时做文字识别的图片数：不能超过 2（见 concurrency(for:)）
    static let pipelineTextConcurrency = 2
    /// 排队等文字识别、留在内存里的图最多几张（每张最长边 1280，约 5 MB）；排满了的标「文字待识别」，第二步再读
    static let handoffLimit = 8

    /// 多久没有任何一张图做完，就算卡住了
    @ObservationIgnored private let stallTimeout: TimeInterval
    /// 卡住时怎么处理：默认取消正在执行的 Vision 请求，让卡住的识别以失败返回
    @ObservationIgnored private let onStall: @Sendable () -> Void
    @ObservationIgnored private var lastProgress = Date()
    /// 本次运行里因为卡住而取消过几次（界面和测试用）
    private(set) var stallCount = 0

    init(imports: ImportedImageStore,
         photos: any PhotoSource = PhotoLibraryService(),
         openStore: @escaping @Sendable () throws -> any IndexPersistence = { try IndexStore(url: IndexStore.defaultURL) },
         textInSecondPass: Bool? = nil,
         stallTimeout: TimeInterval = 120,
         onStall: @escaping @Sendable () -> Void = { ImageAnalyzer.cancelInFlightRequests() },
         analyze: @escaping Analyzer = { await IndexingEngine.process($0, context: $1) },
         indexLimit: Int? = nil,
         skipTextRecognition: Bool? = nil) {
        self.imports = imports
        self.photos = photos
        self.openStore = openStore
        self.analyze = analyze
        self.stallTimeout = stallTimeout
        self.onStall = onStall
        self.textInSecondPass = textInSecondPass
            ?? (UserDefaults.standard.object(forKey: Self.textInSecondPassKey) as? Bool ?? true)
        self.indexLimit = indexLimit ?? UserDefaults.standard.integer(forKey: Self.indexLimitKey)
        self.skipTextRecognition = skipTextRecognition
            ?? UserDefaults.standard.bool(forKey: Self.skipTextRecognitionKey)
    }

    var isBusy: Bool { isRebuilding || phase == .loading || phase == .scanning || phase == .indexing }

    func record(for id: String) -> ImageRecord? { records[id] }
    func meta(for id: String) -> ImageMeta? { metas[id] }

    // MARK: - 启动

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        phase = .loading
        do {
            store = try openStore()
        } catch {
            storageProblem = "索引数据库打不开（\(error.localizedDescription)）。本次建立的索引不会保存，下次启动需要重新建立。"
        }
        if let store {
            do {
                let loaded = try await store.loadAll()
                var map: [String: ImageRecord] = [:]
                for r in loaded { map[r.id] = r }
                records = map
                unavailableAnalyses = loaded.reduce(into: []) { $0.formUnion(Self.unavailableAnalyses(of: $1)) }
            } catch {
                lastError = "读取已有索引失败：\(error.localizedDescription)"
            }
        }
        photos.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        photos.startObserving()
        ready = true
        scheduleRescan()
    }

    /// 请求重新扫描（相册变化、导入新图、权限变化时调用）
    func scheduleRescan(retryFailed: Bool = false) {
        if retryFailed { retryFailedRequested = true }
        rescanRequested = true
        // 还没启动完成或正在重建：先记下请求，由 bootstrap / 重建结束时统一开始
        guard ready, !isRebuilding, worker == nil else { return }
        let epoch = self.epoch
        worker = Task { [weak self] in
            guard let self else { return }
            while self.rescanRequested, !Task.isCancelled {
                self.rescanRequested = false
                await self.scanAndIndex(epoch: epoch)
            }
            self.worker = nil
            if !self.isRebuilding { self.phase = .done }
        }
    }

    /// MobileCLIP 加载完成后调用：之后分析的图片会顺带算向量，已有索引的图片补算向量
    func setEmbedder(_ e: (any ImageEmbedder)?) {
        embedder = e
        semanticModel = e?.modelID
        // 把「等 CLIP 门」的时间单独记进耗时统计，用来判断瓶颈是排队还是在算
        if e is MobileCLIP {
            MobileCLIP.timingObserver = { waited, predicted in
                IndexTimer.shared.add(.embeddingWait, seconds: waited)
                IndexTimer.shared.add(.embedding, seconds: predicted)
            }
        } else {
            MobileCLIP.timingObserver = nil
        }
        refreshCounts()
        if e != nil { scheduleRescan() }
    }

    /// 等当前的扫描/索引任务全部结束（测试用）
    func waitUntilIdle() async {
        while let w = worker { await w.value }
    }

    /// 清空索引并全部重建。先停掉正在进行的扫描并等它结束，旧任务的结果不会写回。
    func rebuildAll() async {
        guard !isRebuilding else { return }
        isRebuilding = true
        epoch += 1
        phase = .loading
        if let w = worker {
            w.cancel()
            await w.value
        }
        do {
            try await store?.deleteAll()
        } catch {
            lastError = "清空索引失败，原有索引保持不变：\(error.localizedDescription)"
            isRebuilding = false
            scheduleRescan()
            return
        }
        records.removeAll()
        unsavedCount = 0
        refreshCounts()
        revision += 1
        isRebuilding = false
        photos.startObserving()
        scheduleRescan()
    }

    // MARK: - 扫描 + 增量索引

    private func scanAndIndex(epoch: Int) async {
        phase = .scanning
        unsavedCount = 0
        persistFailedThisRound = false
        photos.startObserving()
        let service = photos
        let snapshots = await Task.detached(priority: .utility) { service.fetchSnapshots() }.value
        guard epoch == self.epoch, !Task.isCancelled else { return }
        let importItems = imports.items

        var newMetas: [String: ImageMeta] = [:]
        var dated: [(String, Date)] = []
        for s in snapshots {
            newMetas[s.id] = s.meta
            dated.append((s.id, s.meta.creationDate ?? .distantPast))
        }
        for item in importItems {
            let m = imports.meta(for: item)
            newMetas[item.id] = m
            dated.append((item.id, m.creationDate ?? .distantPast))
        }
        dated.sort { $0.1 > $1.1 }
        metas = newMetas
        orderedIDs = dated.map(\.0)
        photoCount = snapshots.count
        importedCount = importItems.count

        // 已不存在的图片（照片被删、权限收回、导入图片被删）：先删数据库，成功后再从内存移除
        let valid = Set(orderedIDs)
        let stale = records.keys.filter { !valid.contains($0) }
        if !stale.isEmpty {
            ImageLoader.shared.invalidate(ids: stale)
            do {
                try await store?.delete(ids: stale)
                guard epoch == self.epoch else { return }
                for id in stale { records[id] = nil }
            } catch {
                // 留在内存里（不在 orderedIDs 中，不参与检索和计数），下次扫描再删
                lastError = "\(stale.count) 张已移除图片的索引没能删除，下次扫描会重试：\(error.localizedDescription)"
            }
        }

        // 找出需要（重新）分析的图片
        let retryFailed = retryFailedRequested
        retryFailedRequested = false
        let snapshotByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let importByID = Dictionary(importItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var work: [WorkItem] = []
        var edited: [String] = []
        let model = embedder?.modelID
        for id in orderedIDs {
            let existing = records[id]
            if let s = snapshotByID[id] {
                let modified = existing.map { Self.isModified($0.sourceModificationDate, s.modificationDate) } ?? false
                if let r = existing, r.analyzerVersion == ImageAnalyzer.version, !modified,
                   !(retryFailed && Self.isPartial(r)) {
                    if let model, Self.needsEmbedding(r, model: model, retryFailed: retryFailed) {
                        work.append(.embedding(record: r, location: .photo(localIdentifier: s.localIdentifier)))
                    }
                    continue
                }
                if modified { edited.append(id) }
                work.append(.photo(id: id, localIdentifier: s.localIdentifier, modificationDate: s.modificationDate))
            } else if let item = importByID[id] {
                let url = imports.fileURL(forFileName: item.fileName)
                if let r = existing, r.analyzerVersion == ImageAnalyzer.version,
                   !(retryFailed && Self.isPartial(r)) {
                    if let model, Self.needsEmbedding(r, model: model, retryFailed: retryFailed) {
                        work.append(.embedding(record: r, location: .file(url)))
                    }
                    continue
                }
                work.append(.imported(id: id, url: url))
            }
        }
        // 编辑过的照片：缓存里的旧缩略图作废，界面会重新加载
        if !edited.isEmpty { ImageLoader.shared.invalidate(ids: edited) }
        if indexLimit > 0, work.count > indexLimit { work = Array(work.prefix(indexLimit)) }
        refreshCounts()
        revision += 1
        if !work.isEmpty {
            await index(work, epoch: epoch, pass: textInSecondPass ? .content : .single)
            // 相册又变了、开始重建、任务取消或写不进数据库：先停下，下次扫描从头安排
            guard epoch == self.epoch, !Task.isCancelled, !rescanRequested, !persistFailedThisRound else { return }
        }
        // 开发用：先不做文字识别。记录保持「文字待识别」，搜索会报告这些图还没检查
        guard !skipTextRecognition else { return }
        // 第二步：画面已识别、只差图中文字的图片（包括刚在第一步做完的，以及上次没做完的）
        var textWork = pendingTextWork(snapshots: snapshotByID, imports: importByID)
        if indexLimit > 0, textWork.count > indexLimit { textWork = Array(textWork.prefix(indexLimit)) }
        guard !textWork.isEmpty else { return }
        await index(textWork, epoch: epoch, pass: .text)
    }

    /// 还在等文字识别的图片，按时间倒序（新照片先补上文字）
    private func pendingTextWork(snapshots: [String: AssetSnapshot],
                                 imports importByID: [String: ImportedImageStore.Item]) -> [WorkItem] {
        var out: [WorkItem] = []
        for id in orderedIDs {
            guard let r = records[id], r.flags.contains(.textRecognitionPending),
                  r.analyzerVersion == ImageAnalyzer.version, !r.flags.contains(.analysisFailed) else { continue }
            if let s = snapshots[id] {
                out.append(.text(record: r, location: .photo(localIdentifier: s.localIdentifier)))
            } else if let item = importByID[id] {
                out.append(.text(record: r, location: .file(imports.fileURL(forFileName: item.fileName))))
            }
        }
        return out
    }

    /// 分析失败，或有某一项识别没跑成：「重新扫描」时重试
    nonisolated static func isPartial(_ r: ImageRecord) -> Bool {
        r.flags.contains(.analysisFailed) || !r.flags.isDisjoint(with: .incompleteAnalysis)
    }

    /// 是否要用当前模型补算向量：还没用这个模型算过；或上次没算成、这次要求重试（「重新扫描」）
    nonisolated static func needsEmbedding(_ r: ImageRecord, model: String, retryFailed: Bool) -> Bool {
        guard !r.flags.contains(.analysisFailed) else { return false }
        if r.clipModel != model { return true }
        return retryFailed && r.clipEmbedding == nil
    }

    /// 这条记录里"没跑成"的识别项（旧版本的记录会被重建，不计入）
    nonisolated static func unavailableAnalyses(of r: ImageRecord) -> RecordFlags {
        r.analyzerVersion == ImageAnalyzer.version ? r.flags.intersection(.incompleteAnalysis) : []
    }

    private static func isModified(_ old: Date?, _ new: Date?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        return new.timeIntervalSince(old) > 1
    }

    private func index(_ work: [WorkItem], epoch: Int, pass: IndexPass) async {
        phase = .indexing
        currentPass = pass
        progressTotal = work.count
        progressDone = 0
        var buffer: [ImageRecord] = []
        var lastFlush = Date()
        var stopped = false
        let analyze = self.analyze
        let width = Self.concurrency(for: pass)
        // 开发用：跳过文字识别时，第一步也不做、也不留到第二步，记录保持「文字待识别」
        let deferText = pass == .content || skipTextRecognition
        // 流水线：第一步做完的图还在内存里时，直接交给最多 2 路文字识别（只在第一步时）
        let textWidth = pass == .content && !skipTextRecognition ? Self.pipelineTextConcurrency : 0
        // 跳过文字识别时不要交接图：没有人来取，交接的图会一直留在内存里
        let handoff = pass == .content && !skipTextRecognition ? ImageHandoff() : nil
        var textQueue: [WorkItem] = []
        var running = 0, textRunning = 0
        let timer = IndexTimer.shared
        timer.reset()
        let started = Date()
        lastProgress = Date()
        let watchdog = startWatchdog()
        defer { watchdog.cancel() }

        await withTaskGroup(of: (WorkItem, ImageRecord?).self) { group in
            var iterator = work.makeIterator()
            while running < width, let w = iterator.next() {
                running += 1
                let context = AnalysisContext(embedder: embedder, deferText: deferText, handoff: handoff)
                group.addTask { (w, await analyze(w, context)) }
            }
            while let finished = await group.next() {
                lastProgress = Date()
                let (item, result) = finished
                let inMemoryText: Bool
                if case .textInMemory = item { inMemoryText = true } else { inMemoryText = false }
                if inMemoryText {
                    textRunning -= 1
                } else {
                    running -= 1
                    progressDone += 1
                }
                if let r = result {
                    buffer.append(r)
                    // 第一步刚做完、还在等文字识别的图：排进流水线；排满了就留给第二步重新读图
                    if !inMemoryText, !skipTextRecognition, let image = handoff?.take(r.id),
                       r.flags.contains(.textRecognitionPending), textQueue.count < Self.handoffLimit {
                        textQueue.append(.textInMemory(record: r, image: image))
                    }
                }
                if buffer.count >= 12 || Date().timeIntervalSince(lastFlush) > 1.2 {
                    await flush(&buffer, epoch: epoch)
                    lastFlush = Date()
                }
                // 相册又变了、开始重建或任务被取消、数据库写不进去：先停下（已保存的不会丢，没做完文字的留到下次）
                if rescanRequested || Task.isCancelled || epoch != self.epoch || persistFailedThisRound {
                    stopped = true
                    group.cancelAll()
                    break
                }
                while running < width, let w = iterator.next() {
                    running += 1
                    // 模型中途加载完成的话，之后的图片就会用上
                    let context = AnalysisContext(embedder: embedder, deferText: deferText, handoff: handoff)
                    group.addTask { (w, await analyze(w, context)) }
                }
                while textRunning < textWidth, !textQueue.isEmpty {
                    let w = textQueue.removeFirst()
                    textRunning += 1
                    let context = AnalysisContext(embedder: embedder)
                    group.addTask { (w, await analyze(w, context)) }
                }
            }
        }
        await flush(&buffer, epoch: epoch)
        refreshCounts()
        if progressDone >= Self.minImagesForStats {
            record(timer.stats(pass: pass, images: progressDone, seconds: Date().timeIntervalSince(started),
                               finished: !stopped && progressDone == work.count, concurrency: width))
        }
        currentPass = nil
    }

    /// 卡死保护：建索引时，超过 stallTimeout 没有任何一张图做完（Vision 内部可能互相等待、不再返回），
    /// 就取消正在执行的 Vision 请求，并提示把图搜关掉重开。模拟器里实测（11-13）：取消解不开 Vision 文字识别的这种死锁，
    /// 只有重开 App 才行；重开后没做完的图会接着做（文字待识别的从第二步继续）
    private func startWatchdog() -> Task<Void, Never> {
        let timeout = stallTimeout
        let onStall = self.onStall
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(timeout / 4, 0.05)))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastProgress) > timeout {
                    self.stallCount += 1
                    self.lastProgress = Date()
                    self.lastError = "建索引有 \(Int(timeout.rounded())) 秒没有进展，系统的图片识别可能卡住了。请把图搜从后台划掉再打开，会从没做完的地方接着做。"
                    onStall()
                }
            }
        }
    }

    /// 第二步接在第一步后面记；其它情况都从这一轮重新记
    private func record(_ stats: IndexPassStats) {
        if stats.pass == .text, let last = lastPassStats.last, last.pass == .content {
            lastPassStats = [last, stats]
        } else {
            lastPassStats = [stats]
        }
    }

    /// 先写数据库，成功后才更新内存索引
    private func flush(_ buffer: inout [ImageRecord], epoch: Int) async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        guard epoch == self.epoch else { return }               // 已经开始重建：旧批次作废
        if let store {
            do {
                try await store.upsert(batch)
            } catch {
                // 没写进数据库：不放进内存索引（否则重启后会凭空消失），下次扫描重新分析
                unsavedCount += batch.count
                persistFailedThisRound = true
                lastError = "有 \(batch.count) 张图片的索引没能保存，下次扫描会重试：\(error.localizedDescription)"
                return
            }
            guard epoch == self.epoch else { return }           // 写库期间开始了重建：重建会清掉数据库
        }
        // 数据库打不开时（storageProblem 已提示）只更新内存：本次运行内可搜，重启后需要重建
        for r in batch { records[r.id] = r }
        refreshCountsThrottled()
        revision += 1
    }

    /// 建索引期间最多每秒重新统计一次：原来每写一批（12 张）就把整个图库遍历一遍，
    /// 在几万张的图库上是主线程上明显的开销。这一轮结束时会再精确统计一次（见 index(_:epoch:pass:)）
    private func refreshCountsThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastCountsRefresh) >= 1 else { return }
        lastCountsRefresh = now
        refreshCounts()
    }

    private func refreshCounts() {
        let s = IndexStats.compute(ids: orderedIDs, records: records, embeddingModel: semanticModel)
        indexedCount = s.indexed
        failedCount = s.failed
        unavailableAnalyses = s.unavailable
        embeddedCount = s.embedded
        textPendingCount = s.textPending
        smallPreviewCount = s.smallPreview
    }

    // MARK: - 单张图片的分析（后台线程）

    /// 默认的分析：PhotoKit 取图（只用本机数据）+ Vision，有 MobileCLIP 时顺带算图片向量。
    /// 各步骤的耗时记进 IndexTimer.shared，设置页据此显示「最近一次建索引的耗时」
    nonisolated static func process(_ item: WorkItem, context: AnalysisContext) async -> ImageRecord? {
        if Task.isCancelled { return nil }
        let timer = IndexTimer.shared
        switch item {
        case let .photo(id, localIdentifier, modificationDate):
            guard let loaded = await loadPhoto(localIdentifier, timer: timer) else {
                // 被取消导致没拿到图，不算分析失败
                return Task.isCancelled ? nil : failedRecord(id, .photoLibrary, modificationDate)
            }
            let (ui, cg) = loaded
            let orientation = CGImagePropertyOrientation(ui.imageOrientation)
            var r = analyze(id: id, source: .photoLibrary, modificationDate: modificationDate, image: cg,
                            orientation: orientation, deferText: context.deferText, timer: timer)
            if let embedder = context.embedder {
                if Self.skipSmallPreviewEmbedding, isSmallPreview(cg) {
                    r.clipModel = embedder.modelID   // 记下已尝试，免得每次扫描都重算；重新扫描时会再试
                } else {
                    attachEmbedding(&r, image: ui.imageOrientation == .up ? cg : (render(ui) ?? cg), embedder, timer: timer)
                }
            }
            // 还等着文字识别：图留在内存里交给流水线，用的是同一张图、同样的方向
            if r.flags.contains(.textRecognitionPending) { context.handoff?.put(id, AnalysisImage(cg, orientation: orientation)) }
            return r
        case let .imported(id, url):
            guard let cg = loadFile(url, timer: timer) else {
                return failedRecord(id, .imported, nil)
            }
            var r = analyze(id: id, source: .imported, modificationDate: nil, image: cg, orientation: .up,
                            deferText: context.deferText, timer: timer)
            if let embedder = context.embedder {
                if Self.skipSmallPreviewEmbedding, isSmallPreview(cg) {
                    r.clipModel = embedder.modelID
                } else {
                    attachEmbedding(&r, image: cg, embedder, timer: timer)
                }
            }
            if r.flags.contains(.textRecognitionPending) { context.handoff?.put(id, AnalysisImage(cg, orientation: .up)) }
            return r
        case let .embedding(record, location):
            guard let embedder = context.embedder else { return nil }
            var r = record
            if let cg = await uprightImage(at: location) {
                attachEmbedding(&r, image: cg, embedder, timer: timer)
            } else if Task.isCancelled {
                return nil
            } else {
                r.clipModel = embedder.modelID   // 读不到图：记下已尝试，「重新扫描」时再试
            }
            return r
        case let .textInMemory(record, image):
            var r = record
            r.flags.remove(.textRecognitionPending)
            let result = autoreleasepool {
                ImageAnalyzer.recognizeText(image.cgImage, orientation: image.orientation) {
                    timer.add(IndexStep(request: $0), seconds: $1)
                }
            }
            r.ocrText = result.text
            if result.failed { r.flags.insert(.textRecognitionFailed) }
            return r
        case let .text(record, location):
            var r = record
            // 和第一步读同样大小的图、用同样的方向，识别结果和一步做完时一样
            var loaded: (image: CGImage, orientation: CGImagePropertyOrientation)?
            switch location {
            case .photo(let localIdentifier):
                if let photo = await loadPhoto(localIdentifier, timer: timer) {
                    loaded = (photo.1, CGImagePropertyOrientation(photo.0.imageOrientation))
                }
            case .file(let url):
                if let cg = loadFile(url, timer: timer) { loaded = (cg, .up) }
            }
            guard let loaded else {
                if Task.isCancelled { return nil }
                // 读不到图：算文字识别没跑成（不再是「待识别」），「重新扫描」时整张图重做
                r.flags.remove(.textRecognitionPending)
                r.flags.insert(.textRecognitionFailed)
                return r
            }
            r.flags.remove(.textRecognitionPending)
            // 这次只拿到很小的预览图：认不出字，不做识别，标记出来等「重新扫描」
            if isSmallPreview(loaded.image) {
                r.flags.insert(.smallPreview)
                return r
            }
            let result = autoreleasepool {
                ImageAnalyzer.recognizeText(loaded.image, orientation: loaded.orientation) {
                    timer.add(IndexStep(request: $0), seconds: $1)
                }
            }
            r.ocrText = result.text
            if result.failed { r.flags.insert(.textRecognitionFailed) }
            return r
        }
    }

    /// 从相册取分析用的图（最长边 1280），记下耗时和实际拿到的尺寸
    nonisolated private static func loadPhoto(_ localIdentifier: String, timer: IndexTimer) async -> (UIImage, CGImage)? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let ui = await PhotoLibraryService.loadImage(localIdentifier: localIdentifier,
                                                          maxPixel: ImageAnalyzer.analysisMaxPixel),
              let cg = ui.cgImage ?? render(ui) else { return nil }
        timer.add(.load, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        timer.addImage(width: cg.width, height: cg.height)
        return (ui, cg)
    }

    /// 读导入的图片文件（缩到最长边 1280）
    nonisolated private static func loadFile(_ url: URL, timer: IndexTimer) -> CGImage? {
        guard let cg = timer.measure(.load, {
            ImageAnalyzer.downsampledImage(at: url, maxPixel: ImageAnalyzer.analysisMaxPixel)
        }) else { return nil }
        timer.addImage(width: cg.width, height: cg.height)
        return cg
    }

    /// 算向量：模型需要画面方向正确的图（Vision 有方向参数，MobileCLIP 没有）
    nonisolated private static func attachEmbedding(_ r: inout ImageRecord, image: CGImage, _ embedder: any ImageEmbedder,
                                                    timer: IndexTimer) {
        if embedder is MobileCLIP {
            // 等门和预测由 MobileCLIP 自己分别计时（等门时间也要能看出来），这里不再重复计
            r.clipEmbedding = autoreleasepool { embedder.embed(image: image) }
        } else {
            r.clipEmbedding = timer.measure(.embedding) { autoreleasepool { embedder.embed(image: image) } }
        }
        r.clipModel = embedder.modelID   // 没算成也记下，避免每次扫描都重试
    }

    /// 补算向量时读图：MobileCLIP 的输入是 256×256，读 512 像素的图就够了
    nonisolated private static func uprightImage(at location: ImageLocation) async -> CGImage? {
        switch location {
        case .photo(let localIdentifier):
            guard let ui = await PhotoLibraryService.loadImage(localIdentifier: localIdentifier, maxPixel: 512) else { return nil }
            return ui.imageOrientation == .up ? (ui.cgImage ?? render(ui)) : render(ui)
        case .file(let url):
            return ImageAnalyzer.downsampledImage(at: url, maxPixel: 512)
        }
    }

    /// 拿到的图太小（最长边不到 ImageAnalyzer.minTextPixel）
    nonisolated static func isSmallPreview(_ image: CGImage) -> Bool {
        max(image.width, image.height) < ImageAnalyzer.minTextPixel
    }

    /// deferText 为 true 时不做文字识别，记录标上「文字待识别」。
    /// 图太小时也不做文字识别，标上「只拿到小预览图」，不再进第二步
    nonisolated private static func analyze(id: String, source: ImageSourceKind, modificationDate: Date?, image: CGImage,
                                            orientation: CGImagePropertyOrientation, deferText: Bool,
                                            timer: IndexTimer) -> ImageRecord {
        autoreleasepool {
            let small = isSmallPreview(image)
            var r = ImageAnalyzer.analyze(image, orientation: orientation, includeText: !deferText && !small) {
                timer.add(IndexStep(request: $0), seconds: $1)
            }
            if small {
                r.flags.remove(.textRecognitionPending)
                r.flags.insert(.smallPreview)
            }
            return ImageRecord(id: id, source: source, sourceModificationDate: modificationDate, labels: r.labels,
                               ocrText: r.ocrText, faceCount: r.faceCount, flags: r.flags,
                               pixelWidth: image.width, pixelHeight: image.height,
                               analyzerVersion: ImageAnalyzer.version, indexedAt: Date())
        }
    }

    nonisolated private static func failedRecord(_ id: String, _ source: ImageSourceKind, _ mod: Date?) -> ImageRecord {
        ImageRecord(id: id, source: source, sourceModificationDate: mod, labels: [], ocrText: "", faceCount: 0,
                    flags: .analysisFailed, pixelWidth: 0, pixelHeight: 0,
                    analyzerVersion: ImageAnalyzer.version, indexedAt: Date())
    }

    nonisolated private static func render(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    // MARK: - 统计（设置页、热门标签）

    /// 热门标签的缓存：搜索页每次重绘都会调用 topLabels，图库大时全量遍历会掉帧。
    /// 索引每变一次 revision 加一，缓存跟着失效
    @ObservationIgnored private var topLabelsCache: (revision: Int, limit: Int, values: [(name: String, count: Int)])?

    /// 出现最多的标签（用于搜索页的"热门标签"）；只统计当前存在的图片
    func topLabels(limit: Int, dictionary: LabelDictionary = .shared) -> [(name: String, count: Int)] {
        // 只有用内置词典时才缓存（测试会传自己的词典）
        let cacheable = dictionary === LabelDictionary.shared
        if cacheable, let c = topLabelsCache, c.revision == revision, c.limit == limit { return c.values }
        let generic: Set<String> = ["outdoor", "structure", "material", "textile", "sky", "land", "liquid", "water",
                                    "plant", "conveyance", "people", "adult", "art", "machine", "recreation",
                                    "interior_room", "tableware", "utensil", "wood_processed", "wood_natural",
                                    "furniture", "container", "light", "daytime", "cloudy", "mammal", "printed_page"]
        var counts: [String: Int] = [:]
        for id in orderedIDs {
            guard let r = records[id] else { continue }
            var names = Set<String>()   // 同一张图里同名标签（猫/成年猫）只算一次
            for l in r.labels where l.confidence >= 0.5 && !generic.contains(l.id) {
                names.insert(dictionary.displayName(for: l.id))
            }
            for n in names { counts[n, default: 0] += 1 }
        }
        let values = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value) }
        if cacheable { topLabelsCache = (revision, limit, values) }
        return values
    }
}
