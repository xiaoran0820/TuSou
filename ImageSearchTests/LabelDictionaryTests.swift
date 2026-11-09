import Testing
@testable import ImageSearch

@Suite("词典")
struct LabelDictionaryTests {
    private let dict = LabelDictionary.shared

    @Test("覆盖 Vision 的全部 1303 个分类，每个都有中文名")
    func coversAllLabelsInChinese() {
        #expect(dict.allLabels.count == 1303)
        let missing = dict.allLabels.filter { !TextNormalizer.containsCJK(dict.displayName(for: $0)) }.sorted()
        #expect(missing.isEmpty, "缺中文名：\(missing.prefix(10))")
    }

    @Test("字面包含、但意思不同的复合标签不会被命中")
    func misleadingComponentsExcluded() {
        #expect(!dict.lookupEnglish("dog").contains { $0.label == "prairie_dog" })
        #expect(!dict.lookupEnglish("ice").contains { $0.label == "ice_cream" })
    }

    @Test("「~联想词」的权重低于正式同义词")
    func relatedTermsWeighLess() {
        let samoyed = dict.lookupChinese("萨摩耶").first { $0.label == "dog" }
        #expect(samoyed?.weight == LabelDictionary.relatedWeight)
        #expect(dict.lookupChinese("狗").first { $0.label == "dog" }?.weight == 1.0)
    }

    @Test("英文复数还原")
    func plurals() {
        #expect(dict.lookupEnglish("cats").contains { $0.label == "cat" })
        #expect(dict.lookupEnglish("berries").contains { $0.label == "berry" })
    }
}
