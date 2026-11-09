import Foundation
import Testing
@testable import ImageSearch

@Suite("查询解析：日期")
struct QueryParserDateTests {
    private typealias F = Fixture

    private func range(_ start: Date, _ end: Date) -> QueryTerm.Kind {
        .date(.range(start: start, end: end))
    }

    @Test("纯年份")
    func yearOnly() {
        #expect(F.parse("2024") == [QueryTerm(text: "2024", kind: range(F.date(2024, 1, 1), F.date(2025, 1, 1)))])
        #expect(F.parse("2024年") == [QueryTerm(text: "2024年", kind: range(F.date(2024, 1, 1), F.date(2025, 1, 1)))])
    }

    @Test("年月：中文、横杠、点号三种写法")
    func yearAndMonth() {
        let october2025 = range(F.date(2025, 10, 1), F.date(2025, 11, 1))
        #expect(F.parse("2025年10月") == [QueryTerm(text: "2025年10月", kind: october2025)])
        #expect(F.parse("2025-10") == [QueryTerm(text: "2025-10", kind: october2025)])
        #expect(F.parse("2024.5") == [QueryTerm(text: "2024.5", kind: range(F.date(2024, 5, 1), F.date(2024, 6, 1)))])
    }

    @Test("只有月份：任何一年的这个月")
    func monthOnly() {
        #expect(F.parse("3月") == [QueryTerm(text: "3月", kind: .date(.month(3)))])
        #expect(F.parse("12月份") == [QueryTerm(text: "12月份", kind: .date(.month(12)))])
    }

    @Test("相对日期以 2026-11-09（周一）为准")
    func relativeDates() {
        #expect(F.parse("今天") == [QueryTerm(text: "今天", kind: range(F.date(2026, 11, 9), F.date(2026, 11, 10)))])
        #expect(F.parse("昨天") == [QueryTerm(text: "昨天", kind: range(F.date(2026, 11, 8), F.date(2026, 11, 9)))])
        #expect(F.parse("上周") == [QueryTerm(text: "上周", kind: range(F.date(2026, 11, 2), F.date(2026, 11, 9)))])
        #expect(F.parse("上个月") == [QueryTerm(text: "上个月", kind: range(F.date(2026, 10, 1), F.date(2026, 11, 1)))])
        #expect(F.parse("去年") == [QueryTerm(text: "去年", kind: range(F.date(2025, 1, 1), F.date(2026, 1, 1)))])
        #expect(F.parse("last year") == [QueryTerm(text: "last year", kind: range(F.date(2025, 1, 1), F.date(2026, 1, 1)))])
    }

    @Test("日期和普通词一起出现：日期在前，普通词保留")
    func dateWithWord() {
        #expect(F.parse("海边 去年") == [
            QueryTerm(text: "去年", kind: range(F.date(2025, 1, 1), F.date(2026, 1, 1))),
            QueryTerm(text: "海边", kind: .word),
        ])
    }

    @Test("金额和单号不会被当成年份")
    func numbersThatAreNotYears() {
        #expect(F.parse("119.20").allSatisfy { $0.kind == .word })
        #expect(F.parse("48213") == [QueryTerm(text: "48213", kind: .word)])
    }
}

@Suite("查询解析：分词")
struct QueryParserWordTests {
    private typealias F = Fixture

    @Test("词典里的整词不会被拆开")
    func knownWordsStayWhole() {
        #expect(F.words("萨摩耶") == ["萨摩耶"])
        #expect(F.words("生日蛋糕") == ["生日蛋糕"])
        #expect(F.words("截图") == ["截图"])
    }

    @Test("停用词被去掉")
    func stopWordsRemoved() {
        #expect(F.words("海边的日落") == ["海边", "日落"])
        #expect(F.words("cat photos") == ["cat"])
    }

    @Test("繁体、全角、大写统一成简体半角小写")
    func normalization() {
        #expect(F.words("貓") == ["猫"])
        #expect(F.words("ＣＡＴ") == ["cat"])
        #expect(F.words("Beach") == ["beach"])
    }

    @Test("英文多词短语合并成一个检索词")
    func englishPhrase() {
        #expect(F.words("birthday cake") == ["birthday cake"])
    }

    @Test("单个数字丢弃，两位以上的数字保留（用来匹配金额、单号）")
    func numbers() {
        #expect(F.words("5").isEmpty)
        #expect(F.words("119") == ["119"])
    }
}
