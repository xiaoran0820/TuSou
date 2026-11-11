import Foundation
import Testing
@testable import ImageSearch

@Suite("中文查询的整句翻译（系统翻译）")
struct TranslationTests {
    private typealias F = Fixture

    private func engine(_ vectors: [String: [Float]] = [:], options: SearchOptions = .all) -> SearchEngine {
        SearchEngine(textEmbedder: FakeTextEmbedder(vectors: vectors), options: options)
    }

    /// 交给系统翻译的文本
    private func source(_ q: String, _ e: SearchEngine? = nil) -> String? {
        (e ?? engine()).textForTranslation(q, now: F.now, calendar: F.calendar)
    }

    private func record(_ id: String, _ embedding: [Float]) -> ImageRecord {
        var r = F.record(id)
        r.clipEmbedding = embedding
        r.clipModel = "fake-clip"
        return r
    }

    @Test("整句翻译的查询：有词逐词翻不出来、有词的英文只来自中英对照表、或者有三个词以上")
    func translatedQueries() {
        #expect(source("草地上的白色大狗") == "草地上的白色大狗")   // 三个词都有现成英文，但逐词拼不出「在草地上」
        #expect(source("海边沙滩上穿黑色衣服的男人和白色的伞") == "海边沙滩上穿黑色衣服的男人和白色的伞")
        #expect(source("石头旁边成丛的白色小花") == "石头旁边成丛的白色小花")   // 「小花」在对照表里是 popular young actress
        #expect(source("坐在长椅上的一群人") == "坐在长椅上的一群人")
        #expect(source("日本麦当劳双层芝士汉堡和麦乐鸡") == "日本麦当劳双层芝士汉堡和麦乐鸡")
    }

    @Test("不整句翻译的查询：英文、只有日期或照片属性、单个词有现成英文、两个词都有专门挑好的英文、没有 MobileCLIP 或只用 Vision")
    func untranslatedQueries() {
        #expect(source("red car") == nil)
        #expect(source("去年拍的照片") == nil)
        #expect(source("自拍") == nil)
        // 单个词没有上下文，系统翻译容易翻错：「汉堡」→ Hamburg，「建筑」→ Construct
        for q in ["面", "汉堡", "建筑", "太平山顶"] { #expect(source(q) == nil, "\(q)") }
        // 常用词表和标签词典里的词拼出来的短查询，逐词翻译本来就准
        for q in ["红色的汽车", "骑自行车的人", "去年的海边日落", "猫的截图", "太平山顶夜景"] { #expect(source(q) == nil, "\(q)") }
        #expect(source("坐在长椅上的一群人", SearchEngine()) == nil)
        #expect(source("坐在长椅上的一群人", engine(options: SearchOptions(semantic: false))) == nil)
    }

    @Test("交给翻译的文本不含日期、照片属性、开头的「帮我找」和结尾的「的照片」；地名表里的地名先换成英文名")
    func sourceText() {
        #expect(source("去年坐在长椅上的一群人") == "坐在长椅上的一群人")
        #expect(source("我收藏的坐在长椅上的一群人") == "坐在长椅上的一群人")
        #expect(source("帮我找一下坐在长椅上的一群人的照片") == "坐在长椅上的一群人")
        #expect(source("在太平山顶看到的香港夜景") == "在 Victoria Peak 看到的香港夜景")
        // 套话按词判断，只去掉确定是套话的
        func text(_ q: String) -> String { QueryParser.descriptiveText(q, now: F.now, calendar: F.calendar) }
        #expect(text("显示器") == "显示器")
        #expect(text("地图") == "地图")
        #expect(text("给新娘打伞的男人") == "给新娘打伞的男人")               // 「给」不是「给我找」
        #expect(text("车库里的公交车黑白照片") == "车库里的公交车黑白照片")     // 「黑白照片」是画面内容
        #expect(text("一个人的照片") == "一个人")
        #expect(text("所有的猫") == "猫")
        #expect(text("去年拍的照片") == "")
    }

    @Test("译文整理成描述：去掉两头的标点和开头的 a photo of；夹着中文或没有内容就不用")
    func cleaning() {
        #expect(SearchEngine.cleanedTranslation("A man in black on the beach.") == "A man in black on the beach")
        #expect(SearchEngine.cleanedTranslation("  Photos of  two dogs  in the park ") == "two dogs in the park")
        #expect(SearchEngine.cleanedTranslation("\"Victoria Peak night view\"") == "Victoria Peak night view")
        #expect(SearchEngine.cleanedTranslation("Taiping 山顶") == nil)
        #expect(SearchEngine.cleanedTranslation("。") == nil)
        #expect(SearchEngine.cleanedTranslation(nil) == nil)
    }

    @Test("有整句译文时，MobileCLIP 用译文比对画面，整句里的词都算被描述覆盖；没有译文时照旧逐词拼描述")
    func searchUsesTranslation() {
        let q = "坐在长椅上的一群人"
        let plain = engine()
        let wordByWord = plain.semanticPrompt(for: plain.plan(for: q, now: F.now, calendar: F.calendar), query: q)!
        let sentence = "a photo of A group of people sitting on a bench"
        #expect(wordByWord != sentence)
        let e = engine([sentence: [1, 0, 0], wordByWord: [0, 1, 0]])
        let records = [record("sentenceMatch", [1, 0, 0]), record("wordMatch", [0, 1, 0])]
        let dict = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        func search(_ translation: String?) -> SearchOutcome {
            e.search(query: q, ids: records.map(\.id), records: dict, metas: [:], translation: translation,
                     now: F.now, calendar: F.calendar)
        }

        let translated = search("A group of people sitting on a bench.")
        #expect(translated.semanticPrompt == sentence)
        #expect(translated.promptIsTranslated)
        #expect(translated.fullHits.map(\.id) == ["sentenceMatch"])   // 每个词都由整句的画面语义满足

        let fallback = search(nil)
        #expect(fallback.semanticPrompt == wordByWord)
        #expect(!fallback.promptIsTranslated)
        #expect(fallback.hits.first?.id == "wordMatch")

        // 译文里还夹着中文（没翻出来）：不用它
        let untranslated = search("一群人 on a bench")
        #expect(untranslated.semanticPrompt == wordByWord)
        #expect(!untranslated.promptIsTranslated)

        // 只用 MobileCLIP 的排序也用译文
        let ranked = e.rankBySimilarity(query: q, ids: records.map(\.id), records: dict,
                                        translation: "A group of people sitting on a bench.", now: F.now, calendar: F.calendar)
        #expect(ranked.semanticPrompt == sentence)
        #expect(ranked.promptIsTranslated)
        #expect(ranked.hits.map(\.id) == ["sentenceMatch", "wordMatch"])
    }

    @Test("日期不进译文，仍然按拍摄时间判断：画面相符但不是去年拍的，只算符合部分条件")
    func datesStayOutOfTheSentence() {
        let q = "去年坐在长椅上的一群人"
        #expect(source(q) == "坐在长椅上的一群人")
        let e = engine(["a photo of A group of people sitting on a bench": [1, 0, 0]])
        let records = [record("lastYear", [1, 0, 0]), record("thisYear", [1, 0, 0])]
        let metas = ["lastYear": ImageMeta(creationDate: F.date(2025, 8, 1), fileName: "a.jpg"),
                     "thisYear": ImageMeta(creationDate: F.date(2026, 8, 1), fileName: "b.jpg")]
        let out = e.search(query: q, ids: records.map(\.id),
                           records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), metas: metas,
                           translation: "A group of people sitting on a bench", now: F.now, calendar: F.calendar)
        #expect(out.semanticPrompt == "a photo of A group of people sitting on a bench")
        #expect(out.fullHits.map(\.id) == ["lastYear"])
        #expect(out.collapsedHits.map(\.id) == ["thisYear"])
    }
}
