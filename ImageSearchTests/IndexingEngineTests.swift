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
        { item, embedder in
            let g = gen.current
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return nil }
            switch item {
            case .photo(let id, _, let modified):
                var r = Fixture.record(id, ocr: "gen\(g)", modified: modified)
                if let embedder { r.clipEmbedding = [1, 0]; r.clipModel = embedder.modelID }
                return r
            case .imported(let id, _):
                return Fixture.record(id, ocr: "gen\(g)")
            case .embedding(var record, _):
                // 只补算向量：其它内容原样保留
                if let embedder { record.clipEmbedding = [0, 1]; record.clipModel = embedder.modelID }
                return record
            }
        }
    }

    /// store 为 nil 表示数据库打不开
    private func makeEngine(photos: FakePhotos, store: FakeStore?,
                            analyze: @escaping IndexingEngine.Analyzer) -> IndexingEngine {
        let imports = ImportedImageStore(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        return IndexingEngine(imports: imports, photos: photos,
                              openStore: {
                                  guard let store else { throw FakeStore.Failure() }
                                  return store
                              },
                              analyze: analyze)
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
}
