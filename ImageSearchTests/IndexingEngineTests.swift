import CoreGraphics
import Foundation
import Testing
@testable import ImageSearch

/// 假的照片来源：一组固定的照片，可以删除或"编辑"（更新修改时间）
final class FakePhotos: PhotoSource, @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var ids: [String]
    private var modified: [String: Date] = [:]

    init(count: Int, prefix: String = "") {
        ids = (0..<count).map { "p:\(prefix)\($0)" }
    }

    func startObserving() {}

    func fetchSnapshots() -> [AssetSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return ids.enumerated().map { i, id in
            AssetSnapshot(id: id, localIdentifier: ImageID.rawValue(of: id), modificationDate: modified[id],
                          meta: ImageMeta(creationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 - i))))
        }
    }

    func remove(_ id: String) {
        lock.lock(); ids.removeAll { $0 == id }; lock.unlock()
    }

    func edit(_ id: String) {
        lock.lock(); modified[id] = Date(); lock.unlock()
    }
}

/// 假的数据库：可以让写入、删除、清空失败
actor FakeStore: IndexPersistence {
    struct Failure: LocalizedError {
        var errorDescription: String? { "模拟的数据库错误" }
    }

    private(set) var rows: [String: ImageRecord] = [:]
    private var failUpserts = false
    private var failDeletes = false
    private var failDeleteAll = false

    func loadAll() throws -> [ImageRecord] { Array(rows.values) }

    func upsert(_ records: [ImageRecord]) throws {
        if failUpserts { throw Failure() }
        for r in records { rows[r.id] = r }
    }

    func delete(ids: [String]) throws {
        if failDeletes { throw Failure() }
        for id in ids { rows[id] = nil }
    }

    func deleteAll() throws {
        if failDeleteAll { throw Failure() }
        rows.removeAll()
    }

    func set(failUpserts: Bool? = nil, failDeletes: Bool? = nil, failDeleteAll: Bool? = nil) {
        if let failUpserts { self.failUpserts = failUpserts }
        if let failDeletes { self.failDeletes = failDeletes }
        if let failDeleteAll { self.failDeleteAll = failDeleteAll }
    }
}

/// 假的 MobileCLIP 图片编码：不跑模型
struct FakeImageEmbedder: ImageEmbedder {
    let modelID = "fake-clip"
    func embed(image: CGImage) -> [Float]? { [1, 0] }
}

/// 记下假分析被调用的顺序（第一步 content:<id>，第二步 text:<id>）和第一步是否要求把文字留到第二步
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _deferText: Set<Bool> = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var deferText: Set<Bool> { lock.lock(); defer { lock.unlock() }; return _deferText }
    func add(_ call: String, deferText: Bool? = nil) {
        lock.lock()
        _calls.append(call)
        if let deferText { _deferText.insert(deferText) }
        lock.unlock()
    }
}

/// 记下某类任务同时在跑的数量和最大值
final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
}

/// 打开之前一直让假分析等着（模拟卡住）
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func open() { lock.lock(); opened = true; lock.unlock() }
}

/// 1×1 的假图，流水线测试里当作「读进来的图」交出去
func makeDummyImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

/// 分析时给记录打上当前的"代数"，用来判断结果来自重建前还是重建后
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
}

@MainActor
@Suite("索引引擎：持久化一致性与重建", .serialized)
struct IndexingEngineTests {
    /// 假的分析：不跑 Vision，直接生成一条记录
    private func analyzer(_ gen: Generation, delay: Duration = .zero) -> IndexingEngine.Analyzer {
        { item, context in
            let g = gen.current
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return nil }
            switch item {
            case .photo(let id, _, let modified):
                // 一次做完全部识别（不理会 deferText），所以不会出现第二步
                var r = Fixture.record(id, ocr: "gen\(g)", modified: modified)
                if let embedder = context.embedder { r.clipEmbedding = [1, 0]; r.clipModel = embedder.modelID }
                return r
            case .imported(let id, _):
                return Fixture.record(id, ocr: "gen\(g)")
            case .embedding(var record, _):
                // 只补算向量：其它内容原样保留
                if let embedder = context.embedder { record.clipEmbedding = [0, 1]; record.clipModel = embedder.modelID }
                return record
            case .text(var record, _), .textInMemory(var record, _):
                record.flags.remove(.textRecognitionPending)
                return record
            }
        }
    }

    /// 照着 deferText 分两步的假分析：第一步留下「文字待识别」，第二步补上文字 text-<id>
    private func twoPassAnalyzer(_ log: CallLog) -> IndexingEngine.Analyzer {
        { item, context in
            if Task.isCancelled { return nil }
            switch item {
            case .photo(let id, _, let modified):
                log.add("content:\(id)", deferText: context.deferText)
                return Fixture.record(id, ocr: context.deferText ? "" : "text-\(id)",
                                      flags: context.deferText ? .textRecognitionPending : [], modified: modified)
            case .imported(let id, _):
                log.add("content:\(id)", deferText: context.deferText)
                return Fixture.record(id, ocr: context.deferText ? "" : "text-\(id)",
                                      flags: context.deferText ? .textRecognitionPending : [])
            case .embedding(let record, _):
                return record
            case .text(var record, _):
                log.add("text:\(record.id)")
                record.ocrText = "text-\(record.id)"
                record.flags.remove(.textRecognitionPending)
                return record
            case .textInMemory(var record, _):
                log.add("memtext:\(record.id)")
                record.ocrText = "text-\(record.id)"
                record.flags.remove(.textRecognitionPending)
                return record
            }
        }
    }

    /// 流水线用的假分析：第一步把一张 1×1 的假图交出去；文字识别（内存里的和重新读图的）都慢一点，好让它们和第一步重叠
    private func pipelineAnalyzer(_ log: CallLog, content: Concurrency, text: Concurrency) -> IndexingEngine.Analyzer {
        { item, context in
            if Task.isCancelled { return nil }
            switch item {
            case .photo(let id, _, let modified):
                content.enter(); defer { content.leave() }
                try? await Task.sleep(for: .milliseconds(3))
                log.add("content:\(id)", deferText: context.deferText)
                if context.deferText { context.handoff?.put(id, AnalysisImage(makeDummyImage(), orientation: .up)) }
                return Fixture.record(id, flags: context.deferText ? .textRecognitionPending : [], modified: modified)
            case .imported(let id, _):
                return Fixture.record(id)
            case .embedding(let record, _):
                return record
            case .text(var record, _), .textInMemory(var record, _):
                text.enter(); defer { text.leave() }
                try? await Task.sleep(for: .milliseconds(8))
                if case .textInMemory = item { log.add("memtext:\(record.id)") } else { log.add("text:\(record.id)") }
                record.ocrText = "text-\(record.id)"
                record.flags.remove(.textRecognitionPending)
                return record
            }
        }
    }

    @Test("流水线：第一步还在做时文字识别就开始了（图直接从内存交过去）；同时识别文字的不超过 2 张、画面不超过 4 张；做完每张都有文字")
    func pipelineOverlapsAndLimitsConcurrency() async {
        let log = CallLog()
        let store = FakeStore()
        let content = Concurrency(), text = Concurrency()
        let engine = makeEngine(photos: FakePhotos(count: 40), store: store,
                                analyze: pipelineAnalyzer(log, content: content, text: text))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        let calls = log.calls
        let inMemory = calls.filter { $0.hasPrefix("memtext:") }.count
        let reloaded = calls.filter { $0.hasPrefix("text:") }.count
        #expect(inMemory > 0)
        #expect(inMemory + reloaded == 40)
        let firstText = calls.firstIndex { $0.hasPrefix("memtext:") } ?? .max
        let lastContent = calls.lastIndex { $0.hasPrefix("content:") } ?? -1
        #expect(firstText < lastContent)
        #expect(text.maximum <= 2)
        #expect(content.maximum <= 4)
        #expect(engine.textPendingCount == 0)
        #expect(await store.rows.values.allSatisfy { $0.ocrText == "text-\($0.id)" && !$0.flags.contains(.textRecognitionPending) })
    }

    @Test("卡死保护：一段时间没有任何一张图做完，就调用取消（默认是取消卡住的 Vision 请求），提示出来，之后照常做完",
          .timeLimit(.minutes(1)))
    func watchdogBreaksStall() async {
        let gate = Gate()
        let store = FakeStore()
        let imports = ImportedImageStore(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let engine = IndexingEngine(imports: imports, photos: FakePhotos(count: 3), openStore: { store },
                                    textInSecondPass: false, stallTimeout: 0.2, onStall: { gate.open() },
                                    analyze: { item, _ in
                                        while !gate.isOpen {
                                            if Task.isCancelled { return nil }
                                            try? await Task.sleep(for: .milliseconds(10))
                                        }
                                        if case .photo(let id, _, let modified) = item { return Fixture.record(id, modified: modified) }
                                        return nil
                                    })
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(engine.stallCount >= 1)
        #expect(engine.lastError?.contains("没有进展") == true)
        #expect(engine.indexedCount == 3)
    }

    /// store 为 nil 表示数据库打不开
    private func makeEngine(photos: FakePhotos, store: FakeStore?, textInSecondPass: Bool = true,
                            analyze: @escaping IndexingEngine.Analyzer,
                            indexLimit: Int? = 0, skipTextRecognition: Bool? = false) -> IndexingEngine {
        let imports = ImportedImageStore(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        return IndexingEngine(imports: imports, photos: photos,
                              openStore: {
                                  guard let store else { throw FakeStore.Failure() }
                                  return store
                              },
                              textInSecondPass: textInSecondPass,
                              analyze: analyze,
                              indexLimit: indexLimit,
                              skipTextRecognition: skipTextRecognition)
    }

    @Test("两步建索引：第一步全部做完才开始第二步；做完后每张图都有文字，不再「待识别」；两步的耗时都记下")
    func twoPassesInOrder() async {
        let log = CallLog()
        let store = FakeStore()
        let engine = makeEngine(photos: FakePhotos(count: 30), store: store, analyze: twoPassAnalyzer(log))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        let calls = log.calls
        #expect(calls.filter { $0.hasPrefix("content:") }.count == 30)
        #expect(calls.filter { $0.hasPrefix("text:") }.count == 30)
        let lastContent = calls.lastIndex { $0.hasPrefix("content:") } ?? .max
        let firstText = calls.firstIndex { $0.hasPrefix("text:") } ?? -1
        #expect(lastContent < firstText)
        #expect(log.deferText == [true])
        #expect(engine.indexedCount == 30)
        #expect(engine.textPendingCount == 0)
        let rows = await store.rows
        #expect(rows.count == 30)
        #expect(rows.values.allSatisfy { !$0.flags.contains(.textRecognitionPending) && $0.ocrText == "text-\($0.id)" })
        #expect(engine.lastPassStats.map(\.pass) == [.content, .text])
        #expect(engine.lastPassStats.allSatisfy { $0.images == 30 && $0.finished })
        #expect(engine.lastPassStats.map(\.concurrency) == [4, 2])
    }

    @Test("关掉两步：一张图一次做完，不出现「待识别」，也没有第二步")
    func singlePassWhenSwitchedOff() async {
        let log = CallLog()
        let store = FakeStore()
        let engine = makeEngine(photos: FakePhotos(count: 25), store: store, textInSecondPass: false,
                                analyze: twoPassAnalyzer(log))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(log.deferText == [false])
        #expect(log.calls.filter { $0.hasPrefix("text:") }.isEmpty)
        #expect(engine.textPendingCount == 0)
        #expect(await store.rows.values.allSatisfy { $0.ocrText == "text-\($0.id)" })
        #expect(engine.lastPassStats.map(\.pass) == [.single])
        #expect(engine.lastPassStats.first?.concurrency == 2)
    }

    @Test("上次关掉 App 时还有文字没识别：再打开只做第二步，不重做第一步")
    func resumesPendingTextOnly() async {
        let log = CallLog()
        let store = FakeStore()
        try? await store.upsert((0..<3).map { Fixture.record("p:\($0)", flags: .textRecognitionPending) })
        let engine = makeEngine(photos: FakePhotos(count: 3), store: store, analyze: twoPassAnalyzer(log))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(Set(log.calls) == ["text:p:0", "text:p:1", "text:p:2"])
        #expect(engine.textPendingCount == 0)
        #expect(await store.rows.values.allSatisfy { $0.ocrText == "text-\($0.id)" })
        // 少于 20 张：不覆盖耗时统计
        #expect(engine.lastPassStats.isEmpty)
    }

    @Test("写库失败：结果不放进内存索引并提示没保存；数据库恢复后再扫描全部补上")
    func failedWriteIsNotShownAsIndexed() async {
        let store = FakeStore()
        await store.set(failUpserts: true)
        let engine = makeEngine(photos: FakePhotos(count: 5), store: store, analyze: analyzer(Generation()))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(engine.indexedCount == 0)
        #expect(engine.records.isEmpty)
        #expect(engine.unsavedCount == 5)
        #expect(engine.lastError != nil)
        #expect(await store.rows.isEmpty)

        await store.set(failUpserts: false)
        engine.scheduleRescan()
        await engine.waitUntilIdle()
        #expect(engine.indexedCount == 5)
        #expect(engine.unsavedCount == 0)
        #expect(await store.rows.count == 5)
    }

    @Test("删除失败：已移除的照片不再计数、不参与检索，记录留到下次扫描再删")
    func failedDeleteIsRetried() async {
        let store = FakeStore()
        let photos = FakePhotos(count: 3)
        let engine = makeEngine(photos: photos, store: store, analyze: analyzer(Generation()))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(await store.rows.count == 3)

        photos.remove("p:1")
        await store.set(failDeletes: true)
        engine.scheduleRescan()
        await engine.waitUntilIdle()
        #expect(engine.indexedCount == 2)
        #expect(!engine.orderedIDs.contains("p:1"))
        #expect(engine.record(for: "p:1") != nil)
        #expect(await store.rows["p:1"] != nil)
        #expect(engine.lastError != nil)

        await store.set(failDeletes: false)
        engine.scheduleRescan()
        await engine.waitUntilIdle()
        #expect(engine.record(for: "p:1") == nil)
        #expect(await store.rows["p:1"] == nil)
    }

    @Test("扫描进行到一半时重建：旧任务的结果不会写回内存或数据库")
    func rebuildDiscardsInFlightWork() async throws {
        let store = FakeStore()
        let gen = Generation()
        let engine = makeEngine(photos: FakePhotos(count: 40), store: store,
                                analyze: analyzer(gen, delay: .milliseconds(15)))
        await engine.bootstrap()
        // 等第一批写进去，这时还有很多图片正在分析
        let deadline = Date().addingTimeInterval(10)
        while engine.indexedCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.indexedCount > 0 && engine.indexedCount < 40)

        gen.set(2)
        await engine.rebuildAll()
        await engine.waitUntilIdle()

        #expect(engine.indexedCount == 40)
        #expect(engine.records.values.allSatisfy { $0.ocrText == "gen2" })
        #expect(await store.rows.count == 40)
        #expect(await store.rows.values.allSatisfy { $0.ocrText == "gen2" })
    }

    @Test("重建时清空数据库失败：保留原有索引，并提示")
    func failedRebuildKeepsIndex() async {
        let store = FakeStore()
        let engine = makeEngine(photos: FakePhotos(count: 3), store: store, analyze: analyzer(Generation()))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        await store.set(failDeleteAll: true)
        await engine.rebuildAll()
        await engine.waitUntilIdle()
        #expect(engine.indexedCount == 3)
        #expect(engine.lastError != nil)
        #expect(!engine.isRebuilding)
        #expect(await store.rows.count == 3)
    }

    @Test("数据库打不开：照常建立索引供本次使用，但明确提示不会保存")
    func storageUnavailableIsReported() async {
        let engine = makeEngine(photos: FakePhotos(count: 3), store: nil, analyze: analyzer(Generation()))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(engine.storageProblem != nil)
        #expect(engine.indexedCount == 3)
    }

    @Test("照片被编辑：重新分析，并作废缓存的缩略图")
    func editedPhotoIsReindexedAndCacheInvalidated() async {
        let photos = FakePhotos(count: 2, prefix: "edit-")
        let gen = Generation()
        let engine = makeEngine(photos: photos, store: FakeStore(), analyze: analyzer(gen))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        let edited = "p:edit-0", untouched = "p:edit-1"
        let before = (ImageLoader.shared.version(of: edited), ImageLoader.shared.version(of: untouched))

        gen.set(2)
        photos.edit(edited)
        engine.scheduleRescan()
        await engine.waitUntilIdle()
        #expect(engine.record(for: edited)?.ocrText == "gen2")
        #expect(engine.record(for: untouched)?.ocrText == "gen1")
        #expect(ImageLoader.shared.version(of: edited) == before.0 + 1)
        #expect(ImageLoader.shared.version(of: untouched) == before.1)
    }

    @Test("装上 MobileCLIP 后：已有索引的图片只补算向量，不重跑画面和文字识别")
    func embeddingBackfill() async {
        let store = FakeStore()
        let gen = Generation()
        let engine = makeEngine(photos: FakePhotos(count: 3, prefix: "clip-"), store: store, analyze: analyzer(gen))
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(engine.records.values.allSatisfy { $0.clipEmbedding == nil })

        gen.set(2)
        engine.setEmbedder(FakeImageEmbedder())
        await engine.waitUntilIdle()
        #expect(engine.embeddedCount == 3)
        // 图中文字还是第一次分析的结果，说明没有重跑识别
        #expect(engine.records.values.allSatisfy { $0.ocrText == "gen1" && $0.clipModel == "fake-clip" })
        #expect(await store.rows.values.allSatisfy { $0.clipModel == "fake-clip" && $0.clipEmbedding == [0, 1] })

    }

    @Test("每次扫描最多分析 N 张：其余的留到下次扫描，不会被当成已索引")
    func indexLimitCapsEachScan() async {
        let log = CallLog()
        let store = FakeStore()
        let engine = makeEngine(photos: FakePhotos(count: 10), store: store,
                                analyze: twoPassAnalyzer(log), indexLimit: 3)
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(log.calls.filter { $0.hasPrefix("content:") }.count == 3)
        #expect(log.calls.filter { $0.hasPrefix("text:") }.count == 3)
        #expect(engine.indexedCount == 3)
        #expect(engine.records.count == 3)
        #expect(engine.orderedIDs.count == 10)

        engine.indexLimit = 0   // 改成「全部」会重新扫描，补齐剩下的
        await engine.waitUntilIdle()
        #expect(engine.indexedCount == 10)
        #expect(await store.rows.count == 10)
    }

    @Test("开发用：跳过文字识别后，图片留成「文字待识别」，不跑第二步，搜索能报告出来")
    func skippingTextLeavesPending() async {
        let log = CallLog()
        let engine = makeEngine(photos: FakePhotos(count: 5), store: FakeStore(),
                                analyze: twoPassAnalyzer(log), skipTextRecognition: true)
        await engine.bootstrap()
        await engine.waitUntilIdle()
        #expect(log.calls.filter { $0.hasPrefix("content:") }.count == 5)
        #expect(log.calls.filter { $0.hasPrefix("text:") || $0.hasPrefix("memtext:") }.isEmpty)
        #expect(engine.textPendingCount == 5)
        #expect(engine.records.values.allSatisfy { $0.flags.contains(.textRecognitionPending) })
    }
}
