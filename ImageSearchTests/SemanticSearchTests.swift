import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import ImageSearch

/// 假的 MobileCLIP 文字编码：按描述原文返回预先设好的向量
struct FakeTextEmbedder: TextEmbedder {
    let modelID = "fake-clip"
    var vectors: [String: [Float]] = [:]
    func embed(text: String) -> [Float]? { vectors[text] }
}

@Suite("CLIP 分词器")
struct CLIPTokenizerTests {
    private let tok = CLIPTokenizer()!   // App 包里的词表

    // 标准答案由一份按 OpenAI CLIP simple_tokenizer 原逻辑写的参考实现生成
    @Test("与 OpenAI CLIP 的分词结果一致（含大小写、标点、缩写、数字、生僻词）")
    func matchesReference() {
        let cases: [(String, [Int])] = [
            ("a photo of a cat", [320, 1125, 539, 320, 2368]),
            ("A photo of a RED car at night!", [320, 1125, 539, 320, 736, 1615, 536, 930, 256]),
            ("person riding a bicycle in the rain", [2533, 6765, 320, 11652, 530, 518, 2443]),
            ("Samoyed", [30006, 3301]),
            ("hot-air balloons over Cappadocia", [2069, 268, 1922, 18130, 962, 16718, 4775, 4019]),
            ("it's 2024's best sunset", [585, 568, 273, 271, 273, 275, 568, 949, 3424]),
            ("xylophone quokka", [20023, 549, 1951, 666, 1944, 1525]),
        ]
        for (text, expected) in cases {
            #expect(tok.encode(text) == expected, "\(text)")
        }
    }

    @Test("模型输入：首尾加起止符、补 0 到 77 个；太长时截断，不会越界")
    func inputIDs() {
        let ids = tok.inputIDs(for: "a photo of a cat")
        #expect(ids.count == 77)
        #expect(Array(ids.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(ids[7...].allSatisfy { $0 == 0 })
        let long = tok.inputIDs(for: Array(repeating: "cat", count: 200).joined(separator: " "))
        #expect(long.count == 77 && long.first == 49406 && long.last == 49407)
    }
}

@Suite("MobileCLIP 向量的存储")
struct EmbeddingStorageTests {
    @Test("半精度存取：每张图 1 KB，误差小于 0.001")
    func halfPrecisionRoundTrip() {
        let v = MobileCLIP.normalized((0..<512).map { Float(sin(Double($0))) })
        let data = IndexStore.encodeEmbedding(v)
        let back = IndexStore.decodeEmbedding(data)
        #expect(data.count == 1024)
        #expect(back.count == 512)
        #expect(zip(v, back).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test("旧版数据库（没有向量列）打开时自动补列，原有数据保留，之后能存向量")
    func migratesOldDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("old.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let created = sqlite3_exec(db, """
            CREATE TABLE images (id TEXT PRIMARY KEY, source INTEGER NOT NULL, mod_date REAL, labels TEXT NOT NULL,
              ocr TEXT NOT NULL, faces INTEGER NOT NULL, flags INTEGER NOT NULL, width INTEGER NOT NULL,
              height INTEGER NOT NULL, version INTEGER NOT NULL, indexed_at REAL NOT NULL);
            INSERT INTO images VALUES ('p:old', 0, NULL, 'cat:0.900', '发票', 0, 0, 10, 10, 2, 0);
            """, nil, nil, nil)
        #expect(created == SQLITE_OK)
        sqlite3_close(db)

        let store = try IndexStore(url: url)
        let loaded = try await store.loadAll()
        #expect(loaded.map(\.id) == ["p:old"])
        #expect(loaded.first?.ocrText == "发票" && loaded.first?.clipEmbedding == nil)

        var r = try #require(loaded.first)
        r.clipEmbedding = MobileCLIP.normalized([1, 2, 3])
        r.clipModel = "fake-clip"
        try await store.upsert([r])
        let again = try await store.loadAll()
        #expect(again.first?.clipModel == "fake-clip" && again.first?.clipEmbedding?.count == 3)
    }
}

@Suite("MobileCLIP 与原有检索的融合")
struct SemanticSearchTests {
    private typealias F = Fixture
    private let red: [Float] = [1, 0, 0], blue: [Float] = [0, 1, 0], catVec: [Float] = [0, 0, 1]

    private func record(_ id: String, labels: [String: Float], embedding: [Float]?) -> ImageRecord {
        var r = F.record(id, labels: labels)
        r.clipEmbedding = embedding
        r.clipModel = embedding == nil ? nil : "fake-clip"
        return r
    }

    private func search(_ query: String, _ records: [ImageRecord], vectors: [String: [Float]],
                        metas: [String: ImageMeta] = [:]) -> SearchOutcome {
        SearchEngine(textEmbedder: FakeTextEmbedder(vectors: vectors))
            .search(query: query, ids: records.map(\.id), records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                    metas: metas, now: F.now, calendar: F.calendar)
    }

    private var cars: [ImageRecord] {
        [record("blueCar", labels: ["car": 0.9], embedding: blue),
         record("redCar", labels: ["car": 0.9], embedding: red),
         record("cat", labels: ["cat": 0.9], embedding: catVec)]
    }

    @Test("「红色的汽车」：Vision 不认颜色，MobileCLIP 把红车排到蓝车前面")
    func colorComesFromSemanticMatch() {
        let out = search("红色的汽车", cars, vectors: ["a photo of red car": [0.30, 0.10, 0.05]])
        #expect(out.semanticPrompt == "a photo of red car")
        #expect(out.hits.map(\.id) == ["redCar", "blueCar"])
        #expect(out.hits.first?.matchedTerms == 2)
        #expect(out.hits.first?.reasons.contains("画面语义相符 · 相似度 0.30") == true)
        #expect(out.interpretations.first { $0.term == "红色" }?.bySemantic == true)
    }

    @Test("没有 MobileCLIP 时：两辆车只按「汽车」匹配，排序不受颜色影响")
    func withoutModelColorIsIgnored() {
        let out = SearchEngine().search(query: "红色的汽车", ids: cars.map(\.id),
                                        records: Dictionary(uniqueKeysWithValues: cars.map { ($0.id, $0) }),
                                        metas: [:], now: F.now, calendar: F.calendar)
        #expect(out.semanticPrompt == nil)
        #expect(out.hits.map(\.id) == ["blueCar", "redCar"])
    }

    @Test("全英文的查询直接用原文作描述")
    func englishQueryUsesOriginalText() {
        let out = search("red car", cars, vectors: ["a photo of red car": [0.30, 0.10, 0.05]])
        #expect(out.semanticPrompt == "a photo of red car")
        #expect(out.hits.first?.id == "redCar")
    }

    @Test("日期条件不能被画面语义绕过")
    func semanticDoesNotSatisfyDates() {
        let metas: [String: ImageMeta] = ["redCar": ImageMeta(creationDate: F.date(2023, 5, 1)),
                                          "blueCar": ImageMeta(creationDate: F.date(2024, 5, 1))]
        let out = search("红色的汽车 2024", cars, vectors: ["a photo of red car": [0.30, 0.10, 0.05]], metas: metas)
        #expect(out.semanticPrompt == "a photo of red car")
        #expect(out.fullMatchCount == 0)          // 红车不是 2024 年拍的，蓝车不是红色
        #expect(out.hits.first { $0.id == "redCar" }?.matchedTerms == 2)
    }

    @Test("语义过线的 z 门槛随图库变大而提高：118 张取下限 2.5，5,000 张约 3.1，再大最多 3.5")
    func adaptiveZ() {
        #expect(SearchEngine.requiredZ(count: 118, floor: 2.5) == 2.5)
        let z5000 = SearchEngine.requiredZ(count: 5000, floor: 2.5)
        #expect(z5000 > 3.0 && z5000 < 3.2)
        #expect(SearchEngine.requiredZ(count: 1_000_000, floor: 2.5) == SearchEngine.semanticMaxZ)
    }

    @Test("语义过线：比平均高出的标准差数要达到门槛（原来 1.5，图库越大混进的不相关图越多）")
    func zThreshold() {
        // 100 张图、平均 0.06、标准差 0.07：门槛 3.0 时，0.24 只高 2.6 个标准差，不算；0.29 高 3.3 个，算
        #expect(SearchEngine.semanticScore(similarity: 0.24, mean: 0.06, std: 0.07, count: 100, minZ: 3.0) == 0)
        #expect(SearchEngine.semanticScore(similarity: 0.29, mean: 0.06, std: 0.07, count: 100, minZ: 3.0) > 0)
        // 图片少于 30 张时标准差不可靠，只看绝对相似度
        #expect(SearchEngine.semanticScore(similarity: 0.20, mean: 0.06, std: 0.07, count: 10) > 0)
    }

    @Test("语义分数封顶（相似度 ≥ 0.30）后按相似度排，不按拍摄时间")
    func saturatedScoresOrderedBySimilarity() {
        // ids 按时间倒序，newer 在前；但 older 和描述更像
        let records = [record("newer", labels: [:], embedding: [0.31, 0, 0]),
                       record("older", labels: [:], embedding: [0.40, 0, 0])]
        // 「car」有画面标签，多个词时要单独再比一次，所以也给它一个向量
        let out = search("red car", records, vectors: ["a photo of red car": [1, 0, 0], "a photo of car": [1, 0, 0]])
        #expect(out.hits.map(\.score) == [1, 1])
        #expect(out.hits.map(\.id) == ["older", "newer"])
    }

    @Test("多个词时，有画面标签的词要单独再和画面比一次：只像猫的图不算「猫 狗」的完全匹配")
    func eachTermChecked() {
        let probe = SearchEngine(textEmbedder: FakeTextEmbedder())
        let plans = probe.plan(for: "猫 狗", now: F.now, calendar: F.calendar)
        let combined = probe.semanticPrompt(for: plans, query: "猫 狗")!
        let vectors: [String: [Float]] = [combined: [1, 0, 0],
                                          "a photo of " + plans[0].promptWord!: [0, 1, 0],
                                          "a photo of " + plans[1].promptWord!: [0, 0, 1]]
        let records = [record("both", labels: [:], embedding: [0.22, 0.3, 0.3]),
                       record("catOnly", labels: [:], embedding: [0.22, 0.3, 0.05]),     // 整句勉强像，单独看不像狗
                       record("strongOverall", labels: [:], embedding: [0.30, 0.3, 0.05])] // 整句很像（≥ 0.25）：不再逐词核对
        let out = search("猫 狗", records, vectors: vectors)
        #expect(out.primaryHits.map(\.id) == ["strongOverall", "both"])
        #expect(out.collapsedHits.map(\.id) == ["catOnly"])
    }

    @Test("比这次最像的那张低 0.10 以上的，不算画面语义匹配")
    func gapFromBest() {
        let records = [record("best", labels: [:], embedding: [0.40, 0, 0]),
                       record("close", labels: [:], embedding: [0.31, 0, 0]),
                       record("far", labels: [:], embedding: [0.25, 0, 0])]   // 过了 0.18，但比最像的低 0.15
        let out = search("red car", records, vectors: ["a photo of red car": [1, 0, 0], "a photo of car": [1, 0, 0]])
        #expect(out.hits.map(\.id) == ["best", "close"])
    }

    @Test("只有一个汉字出现在图中文字里（菜单上的「花生」），排在画面语义匹配后面")
    func singleCharacterTextIsWeak() {
        var menu = F.record("menu", ocr: "花生米 12元")
        menu.clipEmbedding = [0.05, 0, 0]
        menu.clipModel = "fake-clip"
        let flower = record("flower", labels: [:], embedding: [0.20, 0, 0])
        let out = search("花", [menu, flower], vectors: ["a photo of flower": [1, 0, 0]])
        #expect(out.hits.map(\.id) == ["flower", "menu"])
        #expect(out.hits.last?.score == SearchEngine.ocrSingleCharScore)
    }

    @Test("有 MobileCLIP 时，词表里有英文的词不再拆字猜标签（「菜单」不会因为「菜」去匹配食物）")
    func lexiconWordsSkipGuessing() {
        let withModel = SearchEngine(textEmbedder: FakeTextEmbedder()).plan(for: "菜单", now: F.now, calendar: F.calendar)
        let withoutModel = SearchEngine().plan(for: "菜单", now: F.now, calendar: F.calendar)
        #expect(withModel.first?.labels.isEmpty == true)
        #expect(withoutModel.first?.labels.isEmpty == false)   // 没有模型时仍然按原来的办法猜
    }

    @Test("相册属性（收藏、自拍等）不进描述，也不能被画面语义绕过")
    func semanticDoesNotSatisfyAttributes() {
        let vectors = ["a photo of red car": [Float(0.30), 0.10, 0.05]]
        let english = search("favorite red car", cars, vectors: vectors, metas: ["blueCar": ImageMeta(isFavorite: true)])
        #expect(english.semanticPrompt == "a photo of red car")
        #expect(english.fullMatchCount == 0)      // 红车没收藏，收藏的蓝车不是红色
        #expect(english.hits.first { $0.id == "redCar" }?.matchedTerms == 2)

        let mixed = search("红色的汽车 selfie", cars, vectors: vectors)
        #expect(mixed.semanticPrompt == "a photo of red car")
        #expect(mixed.fullMatchCount == 0)        // 没有一张是自拍
    }

    @Test("相似度不够的不算匹配；还没算好向量的图片会被提示")
    func thresholdAndPendingEmbeddings() {
        let records = cars + [record("noVector", labels: ["car": 0.9], embedding: nil)]
        let out = search("红色的汽车", records, vectors: ["a photo of red car": [0.17, 0.10, 0.05]])
        #expect(!(out.hits.first?.reasons.contains { $0.hasPrefix("画面语义") } ?? false))
        #expect(out.incomplete.contains(IncompleteAnalysis(name: "画面语义比对", count: 1)))
    }

    @Test("中文描述：常用词表优先，其次取词典标签的英文名；转不了的词不进描述")
    func promptConstruction() {
        let engine = SearchEngine(textEmbedder: FakeTextEmbedder())
        func prompt(_ q: String) -> String? { engine.semanticPrompt(for: engine.plan(for: q, now: F.now, calendar: F.calendar), query: q) }
        #expect(prompt("海边的日落") == "a photo of beach sunset")
        #expect(prompt("萨摩耶") == "a photo of samoyed")
        #expect(prompt("生日蛋糕") == "a photo of birthday cake")
        #expect(prompt("去年") == nil)
        #expect(prompt("screenshots") == nil)
        #expect(prompt("骑自行车的人") == "a photo of cycling person")   // 「人」是人脸条件，属于画面内容，照常进描述
        // 介词短语放到名词后面
        #expect(prompt("夜晚的城市") == "a photo of city at night")
        #expect(prompt("下雨的街道") == "a photo of street in the rain")
        #expect(prompt("dog on the beach") == "a photo of dog on the beach")
    }
}

@Suite("结果列表")
struct ResultListTests {
    private typealias F = Fixture

    @Test("有完全匹配时，只符合部分条件的结果收起；一张完全匹配都没有时全部列出")
    func partialMatchesCollapsed() {
        let out = F.search("海边 日落", [
            F.record("beach", labels: ["beach": 0.95]),
            F.record("both", labels: ["beach": 0.7, "sunset_sunrise": 0.7]),
            F.record("sunset", labels: ["sunset_sunrise": 0.95]),
        ])
        #expect(out.primaryHits.map(\.id) == ["both"])
        #expect(Set(out.collapsedHits.map(\.id)) == ["beach", "sunset"])

        let none = F.search("海边 日落", [F.record("beach", labels: ["beach": 0.95])])
        #expect(none.primaryHits.map(\.id) == ["beach"])
        #expect(none.collapsedHits.isEmpty)
    }
}

@Suite("App 包里的 MobileCLIP 模型")
struct BundledMobileCLIPTests {
    /// 纯色图片
    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    @Test("模型能从 App 包加载，文字和图片编码的结果合理", .enabled(if: MobileCLIP.load() != nil))
    func loadsAndProducesSensibleEmbeddings() throws {
        let clip = try #require(MobileCLIP.load())
        let cat = try #require(clip.embed(text: "a photo of a cat"))
        let kitten = try #require(clip.embed(text: "a photo of a kitten"))
        let receipt = try #require(clip.embed(text: "a photo of a receipt"))
        #expect(cat.count == 512)
        #expect(MobileCLIP.similarity(cat, kitten) > MobileCLIP.similarity(cat, receipt))

        let red = try #require(clip.embed(image: solid(0.9, 0.05, 0.05)))
        let green = try #require(clip.embed(image: solid(0.05, 0.8, 0.1)))
        let redText = try #require(clip.embed(text: "a plain red color"))
        let greenText = try #require(clip.embed(text: "a plain green color"))
        #expect(MobileCLIP.similarity(red, redText) > MobileCLIP.similarity(red, greenText))
        #expect(MobileCLIP.similarity(green, greenText) > MobileCLIP.similarity(green, redText))
    }
}
