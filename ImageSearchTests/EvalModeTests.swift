import Foundation
import Testing
@testable import ImageSearch

@Suite("评测模式（第 0 轮）")
struct EvalModeTests {
    private typealias F = Fixture

    private func record(_ id: String, labels: [String: Float] = [:], embedding: [Float]?) -> ImageRecord {
        var r = F.record(id, labels: labels)
        r.clipEmbedding = embedding
        r.clipModel = embedding == nil ? nil : "fake-clip"
        return r
    }

    @Test("只用 MobileCLIP：有向量的图全部按相似度从高到低列出，不设门槛；没算好向量的会提示")
    func rankBySimilarity() {
        let records = [record("low", embedding: [0, 0, 1]), record("high", embedding: [1, 0, 0]),
                       record("mid", embedding: [0, 1, 0]), record("noVector", embedding: nil)]
        let engine = SearchEngine(textEmbedder: FakeTextEmbedder(vectors: ["a photo of red car": [0.30, 0.12, 0.05]]))
        let out = engine.rankBySimilarity(query: "红色的汽车", ids: records.map(\.id) + ["notIndexed"],
                                          records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                                          now: F.now, calendar: F.calendar)
        #expect(out.semanticPrompt == "a photo of red car")
        #expect(out.hits.map(\.id) == ["high", "mid", "low"])     // 0.05 远低于平常的门槛，也照样列出
        #expect(out.hits.map(\.similarity) == [0.30, 0.12, 0.05])
        #expect(out.primaryHits.count == 3 && out.collapsedHits.isEmpty)
        #expect(out.incomplete == [IncompleteAnalysis(name: "画面语义比对", count: 1)])
        #expect(out.pendingCount == 1)
    }

    @Test("只用 MobileCLIP：查询转不成英文描述、或没有模型时没有结果")
    func rankBySimilarityWithoutPrompt() {
        let records = [record("a", embedding: [1, 0, 0])]
        let dict = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let engine = SearchEngine(textEmbedder: FakeTextEmbedder(vectors: [:]))
        #expect(engine.rankBySimilarity(query: "去年", ids: ["a"], records: dict, now: F.now, calendar: F.calendar).hits.isEmpty)
        #expect(SearchEngine().rankBySimilarity(query: "cat", ids: ["a"], records: dict, now: F.now, calendar: F.calendar).hits.isEmpty)
    }

    @Test("只用 Vision：不做画面语义比对，结果和关掉 MobileCLIP 时一样")
    func visionOnlyIgnoresSemantic() {
        let dict = ["redCar": record("redCar", labels: ["car": 0.9], embedding: [1, 0, 0]),
                    "cat": record("cat", embedding: [0, 0, 1])]
        let clip = FakeTextEmbedder(vectors: ["a photo of cat": [0.05, 0, 0.35]])
        let vision = SearchEngine(textEmbedder: clip,
                                  options: SearchOptions(labels: true, text: true, expansion: true, semantic: false))
        let out = vision.search(query: "cat", ids: ["redCar", "cat"], records: dict, metas: [:], now: F.now, calendar: F.calendar)
        #expect(out.semanticPrompt == nil)
        #expect(out.hits.isEmpty)   // 「cat」那张没有猫的画面标签，只有 MobileCLIP 能找到它
        let fusion = SearchEngine(textEmbedder: clip)
            .search(query: "cat", ids: ["redCar", "cat"], records: dict, metas: [:], now: F.now, calendar: F.calendar)
        #expect(fusion.hits.map(\.id) == ["cat"])
    }

    @Test("相册选择器导入的编号：按选择顺序取最小的空闲编号，iPhone 相机自己的 IMG_1234 不算")
    func evalNumbering() {
        #expect(ImportedImageStore.evalNames(count: 3, existingNames: []) == ["IMG_01", "IMG_02", "IMG_03"])
        #expect(ImportedImageStore.evalNames(count: 2, existingNames: ["IMG_01.jpg", "IMG_02.heic", "IMG_04.png"])
                == ["IMG_03", "IMG_05"])
        #expect(ImportedImageStore.evalNames(count: 1, existingNames: ["IMG_4821.HEIC", "相册图片.jpg", "img_01.jpg"])
                == ["IMG_01"])
        #expect(ImportedImageStore.evalNames(count: 2, existingNames: (1...99).map { String(format: "IMG_%02d.jpg", $0) })
                == ["IMG_100", "IMG_101"])
        #expect(ImportedImageStore.evalNumber(in: "IMG_07.jpg") == 7)
        #expect(ImportedImageStore.evalNumber(in: "IMG_1234.HEIC") == nil)
        #expect(ImportedImageStore.displayStem(of: "IMG_07.jpg") == "IMG_07")
        #expect(ImportedImageStore.displayStem(of: "猫") == "猫")
    }

    @Test("相册里的原文件名已经是测试编号（改好名再隔空投送的 IMG_07.JPG）就沿用，其余按顺序取空闲编号，不和沿用的撞号")
    func evalNumberingKeepsNumberedOriginals() {
        #expect(ImportedImageStore.evalNames(originalNames: ["IMG_07.JPG", "IMG_02.JPG"], existingNames: [])
                == ["IMG_07", "IMG_02"])
        // 相机原名、拿不到原名的，按顺序编号，跳过已导入的 IMG_01 和这一批沿用的 IMG_02
        #expect(ImportedImageStore.evalNames(originalNames: ["IMG_4821.HEIC", "IMG_02.JPG", nil],
                                             existingNames: ["IMG_01.jpeg"])
                == ["IMG_03", "IMG_02", "IMG_04"])
        #expect(ImportedImageStore.evalNames(originalNames: [nil, nil], existingNames: []) == ["IMG_01", "IMG_02"])
    }
}
