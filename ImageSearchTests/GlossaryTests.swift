import Foundation
import Testing
@testable import ImageSearch

@Suite("中英对照表（CC-CEDICT）")
struct GlossaryTests {
    private typealias F = Fixture

    @Test("App 包里的对照表能加载；地名、地标、物品有合适的英文")
    func lookups() {
        let g = Glossary.shared
        #expect(g.count > 75_000)
        #expect(g.english(for: "富士山") == "Mt. Fuji")
        #expect(g.english(for: "东京塔") == "Tokyo Tower")
        #expect(g.english(for: "金阁寺") == "Kinkakuji or Golden pavilion")   // 太长的释义去掉地点短语
        #expect(g.english(for: "汉堡") == "hamburger")    // 普通名词优先于德国城市 Hamburg
        #expect(g.english(for: "温泉") == "hot spring")   // 跳过「见某词」的条目
        #expect(g.english(for: "滑雪") == "skiing")       // 名词释义优先于 to ski
        #expect(g.english(for: "这不是一个词") == nil)
        // 不合适的义项宁可不翻：日本姓氏、只有动词义的词
        #expect(g.english(for: "中岛") == nil)    // 原来是 Nakajima or Nakashima
        #expect(g.english(for: "停车") == nil)    // 原来是 pull up
        #expect(g.english(for: "开放") == nil)    // 原来是 unrestrained by convention
    }

    @Test("数量短语不当检索条件；「停车标志」有准确英文")
    func countingPhrasesAndLexicon() {
        for q in ["围栏里的两头大象", "两只长颈鹿", "坐在长椅上的一群人"] {
            let terms = QueryParser.parse(q, dictionary: .shared, now: F.now, calendar: F.calendar).map(\.text)
            #expect(!terms.contains { QueryParser.isCountingPhrase($0) }, "\(q) → \(terms)")
        }
        let engine = SearchEngine(textEmbedder: FakeTextEmbedder())
        #expect(engine.semanticPrompt(for: engine.plan(for: "停车标志", now: F.now, calendar: F.calendar), query: "停车标志")
                == "a photo of stop sign")
    }

    @Test("「富士山」整体成词并翻成英文，不再被当成「山」")
    func mountFuji() {
        let engine = SearchEngine(textEmbedder: FakeTextEmbedder())
        let plans = engine.plan(for: "富士山", now: F.now, calendar: F.calendar)
        #expect(plans.map(\.term) == ["富士山"])
        #expect(plans.first?.labels.isEmpty == true)   // 有 MobileCLIP 时不拆出「山」去匹配所有的山
        #expect(engine.semanticPrompt(for: plans, query: "富士山") == "a photo of Mt. Fuji")
    }

    @Test("能整个拆成已知词的不被对照表合并：「串串狗」保留「狗」，照常用画面标签找狗")
    func keepsKnownParts() {
        let terms = QueryParser.parse("串串狗", dictionary: .shared, glossary: .shared, now: F.now, calendar: F.calendar)
        #expect(terms.map(\.text).contains("狗"))   // 合并的话会变成 mixed-breed dog，狗的标签就用不上了
    }

    @Test("能拆成已知词的照旧拆开：对照表不改变原有查询的切分")
    func knownWordsStillSplit() {
        let empty = Glossary(entries: [:])
        for q in ["骑自行车的人", "红色的汽车", "海边的日落", "生日蛋糕", "下雨的街道", "一碗面条", "小孩在玩耍", "夜晚的城市"] {
            let with = QueryParser.parse(q, dictionary: .shared, glossary: .shared, now: F.now, calendar: F.calendar)
            let without = QueryParser.parse(q, dictionary: .shared, glossary: empty, now: F.now, calendar: F.calendar)
            #expect(with == without, "\(q)")
        }
    }
}
