import Foundation
import Testing
import UIKit
@testable import ImageSearch

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Suite("SQLite 索引库：出错时如实报错、不留半截数据")
struct IndexStoreTests {
    private func makeStore() throws -> IndexStore {
        try IndexStore(url: temporaryDirectory().appendingPathComponent("index.sqlite"))
    }

    @Test("写入、读取、删除")
    func roundTrip() async throws {
        let store = try makeStore()
        try await store.upsert([Fixture.record("a", labels: ["cat": 0.9], ocr: "发票"), Fixture.record("b")])
        let loaded = try await store.loadAll()
        #expect(Set(loaded.map(\.id)) == ["a", "b"])
        #expect(loaded.first { $0.id == "a" }?.ocrText == "发票")
        #expect(loaded.first { $0.id == "a" }?.confidence(of: "cat") == 0.9)
        try await store.delete(ids: ["a"])
        #expect(try await store.loadAll().map(\.id) == ["b"])
    }

    @Test("写到一半出错：写入报错并整体回滚，原有数据不变")
    func failedUpsertLeavesDataUntouched() async throws {
        let store = try makeStore()
        try await store.upsert([Fixture.record("a")])
        try await store.setSimulatedWriteFailure(true)
        await #expect(throws: (any Error).self) { try await store.upsert([Fixture.record("b"), Fixture.record("c")]) }
        try await store.setSimulatedWriteFailure(false)
        #expect(try await store.loadAll().map(\.id) == ["a"])
    }

    @Test("删除语句执行失败：删除报错（不再假装成功），记录还在")
    func failedDeleteIsReported() async throws {
        let store = try makeStore()
        try await store.upsert([Fixture.record("a"), Fixture.record("b")])
        try await store.setSimulatedWriteFailure(true)
        await #expect(throws: (any Error).self) { try await store.delete(ids: ["a"]) }
        await #expect(throws: (any Error).self) { try await store.deleteAll() }
        try await store.setSimulatedWriteFailure(false)
        #expect(Set(try await store.loadAll().map(\.id)) == ["a", "b"])
    }
}

@MainActor
@Suite("导入图片的清单：失败时不丢图、不留孤儿")
struct ImportedImageStoreTests {
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// 在清单的位置放一个文件夹，让写清单失败
    private func breakManifest(in base: URL) throws {
        let manifest = base.appendingPathComponent("imported.json")
        try? FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
    }

    private func files(in store: ImportedImageStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
    }

    @Test("正常导入后重新打开，图片都在")
    func importSurvivesRelaunch() async throws {
        let base = temporaryDirectory()
        let store = ImportedImageStore(baseDirectory: base)
        let r = await store.importData([(png(), "a.png", "png"), (png(), "b.png", "png")])
        #expect(r == .init(imported: 2, failed: 0, errorMessage: nil))
        #expect(ImportedImageStore(baseDirectory: base).items.count == 2)
    }

    @Test("清单写不进去：导入算失败，刚复制的文件被删掉")
    func manifestFailureRollsBackImport() async throws {
        let base = temporaryDirectory()
        let store = ImportedImageStore(baseDirectory: base)
        try breakManifest(in: base)
        let r = await store.importData([(png(), "a.png", "png")])
        #expect(r.imported == 0 && r.failed == 1 && r.errorMessage != nil)
        #expect(store.items.isEmpty)
        #expect(try files(in: store).isEmpty)
    }

    @Test("删除时清单写不进去：什么都不删，并报错")
    func deleteFailureKeepsEverything() async throws {
        let base = temporaryDirectory()
        let store = ImportedImageStore(baseDirectory: base)
        _ = await store.importData([(png(), "a.png", "png")])
        let item = try #require(store.items.first)
        try breakManifest(in: base)
        #expect(throws: (any Error).self) { try store.delete(ids: [item.id]) }
        #expect(store.items.map(\.id) == [item.id])
        #expect(FileManager.default.fileExists(atPath: store.fileURL(forFileName: item.fileName).path))
    }

    @Test("启动时清理不在清单里的孤儿文件")
    func orphanFilesRemovedOnLaunch() async throws {
        let base = temporaryDirectory()
        _ = await ImportedImageStore(baseDirectory: base).importData([(png(), "a.png", "png")])
        let orphan = base.appendingPathComponent("Imported/orphan.png")
        try png().write(to: orphan)
        let reopened = ImportedImageStore(baseDirectory: base)
        #expect(reopened.items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("清单损坏：一个文件都不删，把图片重新登记，并保留损坏的清单备份")
    func corruptManifestRecoversFiles() async throws {
        let base = temporaryDirectory()
        _ = await ImportedImageStore(baseDirectory: base).importData([(png(), "a.png", "png"), (png(), "b.png", "png")])
        try Data("not json".utf8).write(to: base.appendingPathComponent("imported.json"))
        let reopened = ImportedImageStore(baseDirectory: base)
        #expect(reopened.items.count == 2)
        #expect(try files(in: reopened).count == 2)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("imported.json.corrupt").path))
    }
}

@Suite("缩略图缓存失效")
struct ImageLoaderTests {
    @Test("照片被编辑或删除后缓存键会变，其他照片不受影响")
    func invalidateChangesOnlyThatKey() {
        let loader = ImageLoader()
        let a = loader.cacheKey(for: "p:a", maxPixel: 300)
        let b = loader.cacheKey(for: "p:b", maxPixel: 300)
        loader.invalidate(ids: ["p:a"])
        #expect(loader.cacheKey(for: "p:a", maxPixel: 300) != a)
        #expect(loader.cacheKey(for: "p:b", maxPixel: 300) == b)
        #expect(loader.version(of: "p:a") == 1)
    }
}
