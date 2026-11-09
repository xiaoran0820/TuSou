import Foundation
import Observation
import UIKit

/// 索引调度：对比相册/导入图片与已有索引，增量分析新增或修改过的图片，删除已不存在的。
/// 新照片优先（按时间倒序处理），分批写库，边建边可搜。全部在本机完成，不联网。
@Observable @MainActor
final class IndexingEngine {
    enum Phase: Equatable { case idle, loading, scanning, indexing, done }

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
    /// 当前版本索引里，有图片没跑成的识别项（如 iOS 模拟器跑不了画面识别和人脸检测，真机正常）
    private(set) var unavailableAnalyses: RecordFlags = []
    /// 当前设备无法运行 Vision 场景分类（iOS 模拟器的已知限制）
    var classifierUnavailable: Bool { unavailableAnalyses.contains(.classifierUnavailable) }
    /// 所有图片（相册 + 导入）按时间倒序
    private(set) var orderedIDs: [String] = []

    @ObservationIgnored private(set) var records: [String: ImageRecord] = [:]
    @ObservationIgnored private(set) var metas: [String: ImageMeta] = [:]

    @ObservationIgnored let photos = PhotoLibraryService()
    @ObservationIgnored private let imports: ImportedImageStore
    @ObservationIgnored private var store: IndexStore?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var retryFailedRequested = false
    @ObservationIgnored private var bootstrapped = false

    /// 同时分析的图片数
    static let concurrency = 2

    init(imports: ImportedImageStore) {
        self.imports = imports
    }

    var isBusy: Bool { phase == .loading || phase == .scanning || phase == .indexing }

    func record(for id: String) -> ImageRecord? { records[id] }
    func meta(for id: String) -> ImageMeta? { metas[id] }

    // MARK: - 启动

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        phase = .loading
        do {
            let store = try IndexStore(url: IndexStore.defaultURL)
            self.store = store
            let loaded = try await store.loadAll()
            var map: [String: ImageRecord] = [:]
            for r in loaded { map[r.id] = r }
            records = map
            unavailableAnalyses = loaded.reduce(into: []) { $0.formUnion(Self.unavailableAnalyses(of: $1)) }
        } catch {
            lastError = error.localizedDescription
        }
        photos.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        photos.startObserving()
        scheduleRescan()
    }

    /// 请求重新扫描（相册变化、导入新图、权限变化时调用）
    func scheduleRescan(retryFailed: Bool = false) {
        if retryFailed { retryFailedRequested = true }
        rescanRequested = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while self.rescanRequested {
                self.rescanRequested = false
                await self.scanAndIndex()
            }
            self.worker = nil
            self.phase = .done
        }
    }

    /// 清空索引并全部重建
    func rebuildAll() async {
        try? await store?.deleteAll()
        records.removeAll()
        refreshCounts()
        revision += 1
        photos.startObserving()
        scheduleRescan()
    }

    // MARK: - 扫描 + 增量索引

    private enum WorkItem: Sendable {
        case photo(id: String, localIdentifier: String, modificationDate: Date?)
        case imported(id: String, url: URL)
    }

    private func scanAndIndex() async {
        phase = .scanning
        photos.startObserving()
        let service = photos
        let snapshots = await Task.detached(priority: .utility) { service.fetchSnapshots() }.value
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

        // 删除已不存在的图片的索引
        let valid = Set(orderedIDs)
        let stale = records.keys.filter { !valid.contains($0) }
        if !stale.isEmpty {
            for id in stale { records[id] = nil }
            try? await store?.delete(ids: Array(stale))
        }

        // 找出需要（重新）分析的图片
        let retryFailed = retryFailedRequested
        retryFailedRequested = false
        let snapshotByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let importByID = Dictionary(importItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var work: [WorkItem] = []
        for id in orderedIDs {
            let existing = records[id]
            if let s = snapshotByID[id] {
                if let r = existing, r.analyzerVersion == ImageAnalyzer.version,
                   !Self.isModified(r.sourceModificationDate, s.modificationDate),
                   !(retryFailed && Self.isPartial(r)) {
                    continue
                }
                work.append(.photo(id: id, localIdentifier: s.localIdentifier, modificationDate: s.modificationDate))
            } else if let item = importByID[id] {
                if let r = existing, r.analyzerVersion == ImageAnalyzer.version,
                   !(retryFailed && Self.isPartial(r)) {
                    continue
                }
                work.append(.imported(id: id, url: imports.fileURL(forFileName: item.fileName)))
            }
        }
        refreshCounts()
        revision += 1
        guard !work.isEmpty else { return }
        await index(work)
    }

    /// 分析失败，或有某一项识别没跑成：「重新扫描」时重试
    nonisolated static func isPartial(_ r: ImageRecord) -> Bool {
        r.flags.contains(.analysisFailed) || !r.flags.isDisjoint(with: .incompleteAnalysis)
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

    private func index(_ work: [WorkItem]) async {
        phase = .indexing
        progressTotal = work.count
        progressDone = 0
        var buffer: [ImageRecord] = []
        var lastFlush = Date()

        await withTaskGroup(of: ImageRecord?.self) { group in
            var iterator = work.makeIterator()
            for _ in 0..<Self.concurrency {
                if let w = iterator.next() { group.addTask { await Self.process(w) } }
            }
            while let result = await group.next() {
                progressDone += 1
                if let r = result { buffer.append(r) }
                if buffer.count >= 12 || Date().timeIntervalSince(lastFlush) > 1.2 {
                    await flush(&buffer)
                    lastFlush = Date()
                }
                // 相册又变了：先停下，回到外层重新扫描（已完成的不会丢）
                if rescanRequested { group.cancelAll(); break }
                if let w = iterator.next() { group.addTask { await Self.process(w) } }
            }
        }
        await flush(&buffer)
    }

    private func flush(_ buffer: inout [ImageRecord]) async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        for r in batch { records[r.id] = r }
        refreshCounts()
        revision += 1
        do { try await store?.upsert(batch) } catch { lastError = error.localizedDescription }
    }

    private func refreshCounts() {
        var indexed = 0, failed = 0
        // 重试成功后标记会消失，所以每次都按现有记录重新统计
        var unavailable: RecordFlags = []
        for id in orderedIDs {
            guard let r = records[id] else { continue }
            indexed += 1
            if r.flags.contains(.analysisFailed) { failed += 1 }
            unavailable.formUnion(Self.unavailableAnalyses(of: r))
        }
        indexedCount = indexed
        failedCount = failed
        unavailableAnalyses = unavailable
    }

    // MARK: - 单张图片的分析（后台线程）

    nonisolated private static func process(_ item: WorkItem) async -> ImageRecord? {
        if Task.isCancelled { return nil }
        switch item {
        case let .photo(id, localIdentifier, modificationDate):
            guard let ui = await PhotoLibraryService.loadImage(localIdentifier: localIdentifier,
                                                              maxPixel: ImageAnalyzer.analysisMaxPixel),
                  let cg = ui.cgImage ?? render(ui) else {
                return failedRecord(id, .photoLibrary, modificationDate)
            }
            return analyze(id: id, source: .photoLibrary, modificationDate: modificationDate,
                           image: cg, orientation: CGImagePropertyOrientation(ui.imageOrientation))
        case let .imported(id, url):
            guard let cg = ImageAnalyzer.downsampledImage(at: url, maxPixel: ImageAnalyzer.analysisMaxPixel) else {
                return failedRecord(id, .imported, nil)
            }
            return analyze(id: id, source: .imported, modificationDate: nil, image: cg, orientation: .up)
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

    /// 出现最多的标签（用于搜索页的"热门标签"）
    func topLabels(limit: Int, dictionary: LabelDictionary = .shared) -> [(name: String, count: Int)] {
        let generic: Set<String> = ["outdoor", "structure", "material", "textile", "sky", "land", "liquid", "water",
                                    "plant", "conveyance", "people", "adult", "art", "machine", "recreation",
                                    "interior_room", "tableware", "utensil", "wood_processed", "wood_natural",
                                    "furniture", "container", "light", "daytime", "cloudy", "mammal", "printed_page"]
        var counts: [String: Int] = [:]
        for r in records.values {
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
