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

    /// 只统计当前存在的图片（ids）；已移除、但数据库还没删掉的旧记录不算
    static func compute(ids: [String], records: [String: ImageRecord], embeddingModel: String? = nil) -> IndexStats {
        var s = IndexStats()
        for id in ids {
            guard let r = records[id] else { continue }
            s.indexed += 1
            if r.flags.contains(.analysisFailed) { s.failed += 1 }
            s.unavailable.formUnion(IndexingEngine.unavailableAnalyses(of: r))
            if let m = embeddingModel, r.hasEmbedding(from: m) { s.embedded += 1 }
        }
        return s
    }
}

/// 索引调度：对比相册/导入图片与已有索引，增量分析新增或修改过的图片，删除已不存在的。
/// 新照片优先（按时间倒序处理），分批写库，边建边可搜。全部在本机完成，不联网。
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

        var id: String {
            switch self {
            case .photo(let id, _, _), .imported(let id, _): return id
            case .embedding(let record, _): return record.id
            }
        }
    }

    /// 补算向量时到哪里重新读图
    enum ImageLocation: Sendable {
        case photo(localIdentifier: String)
        case file(URL)
    }

    /// 分析一张图片得到索引记录；返回 nil 表示任务被取消、这次不算。
    /// 第二个参数是当前可用的 MobileCLIP（没有就是 nil）。默认是 `IndexingEngine.process`
    typealias Analyzer = @Sendable (WorkItem, (any ImageEmbedder)?) async -> ImageRecord?

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

    /// 同时分析的图片数
    static let concurrency = 2

    init(imports: ImportedImageStore,
         photos: any PhotoSource = PhotoLibraryService(),
         openStore: @escaping @Sendable () throws -> any IndexPersistence = { try IndexStore(url: IndexStore.defaultURL) },
         analyze: @escaping Analyzer = { await IndexingEngine.process($0, embedder: $1) }) {
        self.imports = imports
        self.photos = photos
        self.openStore = openStore
        self.analyze = analyze
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
        refreshCounts()
        revision += 1
        guard !work.isEmpty else { return }
        await index(work, epoch: epoch)
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

    private func index(_ work: [WorkItem], epoch: Int) async {
        phase = .indexing
        progressTotal = work.count
        progressDone = 0
        var buffer: [ImageRecord] = []
        var lastFlush = Date()
        let analyze = self.analyze

        await withTaskGroup(of: ImageRecord?.self) { group in
            var iterator = work.makeIterator()
            for _ in 0..<Self.concurrency {
                if let w = iterator.next() {
                    let e = embedder
                    group.addTask { await analyze(w, e) }
                }
            }
            while let result = await group.next() {
                progressDone += 1
                if let r = result { buffer.append(r) }
                if buffer.count >= 12 || Date().timeIntervalSince(lastFlush) > 1.2 {
                    await flush(&buffer, epoch: epoch)
                    lastFlush = Date()
                }
                // 相册又变了、开始重建或任务被取消、数据库写不进去：先停下（已保存的不会丢）
                if rescanRequested || Task.isCancelled || epoch != self.epoch || persistFailedThisRound {
                    group.cancelAll()
                    break
                }
                if let w = iterator.next() {
                    let e = embedder   // 模型中途加载完成的话，之后的图片就会用上
                    group.addTask { await analyze(w, e) }
                }
            }
        }
        await flush(&buffer, epoch: epoch)
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
        refreshCounts()
        revision += 1
    }

    private func refreshCounts() {
        let s = IndexStats.compute(ids: orderedIDs, records: records, embeddingModel: semanticModel)
        indexedCount = s.indexed
        failedCount = s.failed
        unavailableAnalyses = s.unavailable
        embeddedCount = s.embedded
    }

    // MARK: - 单张图片的分析（后台线程）

    /// 默认的分析：PhotoKit 取图（只用本机数据）+ Vision，有 MobileCLIP 时顺带算图片向量
    nonisolated static func process(_ item: WorkItem, embedder: (any ImageEmbedder)?) async -> ImageRecord? {
        if Task.isCancelled { return nil }
        switch item {
        case let .photo(id, localIdentifier, modificationDate):
            guard let ui = await PhotoLibraryService.loadImage(localIdentifier: localIdentifier,
                                                              maxPixel: ImageAnalyzer.analysisMaxPixel),
                  let cg = ui.cgImage ?? render(ui) else {
                // 被取消导致没拿到图，不算分析失败
                return Task.isCancelled ? nil : failedRecord(id, .photoLibrary, modificationDate)
            }
            var r = analyze(id: id, source: .photoLibrary, modificationDate: modificationDate,
                            image: cg, orientation: CGImagePropertyOrientation(ui.imageOrientation))
            if let embedder { attachEmbedding(&r, image: ui.imageOrientation == .up ? cg : (render(ui) ?? cg), embedder) }
            return r
        case let .imported(id, url):
            guard let cg = ImageAnalyzer.downsampledImage(at: url, maxPixel: ImageAnalyzer.analysisMaxPixel) else {
                return failedRecord(id, .imported, nil)
            }
            var r = analyze(id: id, source: .imported, modificationDate: nil, image: cg, orientation: .up)
            if let embedder { attachEmbedding(&r, image: cg, embedder) }
            return r
        case let .embedding(record, location):
            guard let embedder else { return nil }
            var r = record
            if let cg = await uprightImage(at: location) {
                attachEmbedding(&r, image: cg, embedder)
            } else if Task.isCancelled {
                return nil
            } else {
                r.clipModel = embedder.modelID   // 读不到图：记下已尝试，「重新扫描」时再试
            }
            return r
        }
    }

    /// 算向量：模型需要画面方向正确的图（Vision 有方向参数，MobileCLIP 没有）
    nonisolated private static func attachEmbedding(_ r: inout ImageRecord, image: CGImage, _ embedder: any ImageEmbedder) {
        r.clipEmbedding = autoreleasepool { embedder.embed(image: image) }
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

    nonisolated private static func analyze(id: String, source: ImageSourceKind, modificationDate: Date?,
                                            image: CGImage, orientation: CGImagePropertyOrientation) -> ImageRecord {
        autoreleasepool {
            let r = ImageAnalyzer.analyze(image, orientation: orientation)
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

    /// 出现最多的标签（用于搜索页的"热门标签"）；只统计当前存在的图片
    func topLabels(limit: Int, dictionary: LabelDictionary = .shared) -> [(name: String, count: Int)] {
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
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}
