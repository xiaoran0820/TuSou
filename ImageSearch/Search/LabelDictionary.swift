import Foundation

struct WeightedLabel: Sendable, Hashable {
    let label: String
    let weight: Float
}

/// Vision 英文标签 ⇄ 中文词典（资源文件 LabelDictionary.txt）。
/// 负责：中文/英文关键词 → Vision 标签（带权重），以及标签的中文显示名。
final class LabelDictionary: Sendable {
    static let relatedWeight: Float = 0.75     // "~联想词" 的权重
    static let componentWeight: Float = 0.7    // 英文词命中复合标签的一部分，如 cake → birthday_cake

    let displayNames: [String: String]         // 标签 → 中文显示名
    let allLabels: Set<String>
    private let zhIndex: [String: [WeightedLabel]]
    private let enIndex: [String: [WeightedLabel]]
    /// 标签的同义词（中文 ≥2 字、英文 ≥3 字母），用于跨语言匹配图中文字，如 收据 → 小票/发票/receipt
    private let textSynonyms: [String: [String]]
    let maxChineseKeyLength: Int

    var chineseKeys: Dictionary<String, [WeightedLabel]>.Keys { zhIndex.keys }
    var englishKeys: Dictionary<String, [WeightedLabel]>.Keys { enIndex.keys }

    static let shared: LabelDictionary = {
        guard let url = Bundle.main.url(forResource: "LabelDictionary", withExtension: "txt"),
              let dict = try? LabelDictionary(contentsOf: url) else {
            assertionFailure("LabelDictionary.txt 缺失")
            return LabelDictionary(text: "")
        }
        return dict
    }()

    convenience init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    init(text: String) {
        var names: [String: String] = [:]
        var zh: [String: [String: Float]] = [:]
        var en: [String: [String: Float]] = [:]
        var labels = Set<String>()
        var synonyms: [String: [String]] = [:]
        // 字面上包含、但意思不同的复合标签（如 dog ≠ prairie_dog 土拨鼠）
        let misleadingComponents: Set<String> = ["dog|prairie_dog", "clothing|iron_clothing", "water|submarine_water",
                                                 "monitor|monitor_lizard", "sunflower|sunflower_seeds", "ice|ice_cream",
                                                 "wind|wind_turbine", "candy|candy_cane", "lantern|jack_o_lantern"]
        // 复合标签里没有检索意义的部分
        let ignoredComponents: Set<String> = ["other", "regular", "real", "single", "prepared", "processed",
                                              "natural", "drinking", "cooking", "veggie", "room", "sport",
                                              "music", "machine", "container", "hotair", "body", "item"]

        func add(_ index: inout [String: [String: Float]], _ key: String, _ label: String, _ weight: Float) {
            // 词典本身已是简体，这里只需小写化
            let k = key.lowercased().trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return }
            index[k, default: [:]][label] = max(index[k]?[label] ?? 0, weight)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let terms = line[line.index(after: colon)...]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            labels.insert(label)

            // 英文：标签本身 + 复合标签的组成部分
            add(&en, label, label, 1.0)
            let parts = label.split(separator: "_").map(String.init)
            if parts.count > 1 {
                add(&en, parts.joined(separator: " "), label, 1.0)
                for p in parts where p.count >= 3 && !ignoredComponents.contains(p)
                    && !misleadingComponents.contains("\(p)|\(label)") {
                    add(&en, p, label, Self.componentWeight)
                }
            }

            var syn: [String] = []
            if !label.contains("_") && label.count >= 3 { syn.append(label) }
            for term in terms {
                let related = term.hasPrefix("~")
                let word = related ? String(term.dropFirst()) : term
                let weight: Float = related ? Self.relatedWeight : 1.0
                if !related {
                    let cjk = TextNormalizer.containsCJK(word)
                    if (cjk && word.count >= 2) || (!cjk && word.count >= 3 && word.allSatisfy(\.isLetter)) {
                        syn.append(word.lowercased())
                    }
                }
                if TextNormalizer.containsCJK(word) {
                    if names[label] == nil && !related { names[label] = word }
                    add(&zh, word, label, weight)
                } else {
                    add(&en, word.replacingOccurrences(of: "_", with: " "), label, weight)
                    add(&en, word, label, weight)
                }
            }
            if names[label] == nil { names[label] = label }
            synonyms[label] = syn
        }

        displayNames = names
        allLabels = labels
        zhIndex = zh.mapValues { $0.map { WeightedLabel(label: $0.key, weight: $0.value) } }
        enIndex = en.mapValues { $0.map { WeightedLabel(label: $0.key, weight: $0.value) } }
        maxChineseKeyLength = zh.keys.map(\.count).max() ?? 1
        textSynonyms = synonyms
    }

    func textSynonyms(for label: String) -> [String] { textSynonyms[label] ?? [] }

    func displayName(for label: String) -> String { displayNames[label] ?? label }

    /// 标签的英文写法（给 MobileCLIP 的描述用）：birthday_cake → birthday cake
    func englishName(for label: String) -> String { label.replacingOccurrences(of: "_", with: " ") }

    func knowsChinese(_ term: String) -> Bool { zhIndex[term] != nil }
    func knowsEnglish(_ term: String) -> Bool { enIndex[term] != nil }

    func lookupChinese(_ term: String) -> [WeightedLabel] { zhIndex[term] ?? [] }

    /// 英文查找，带简单的复数还原（cats → cat, boxes → box, berries → berry）
    func lookupEnglish(_ term: String) -> [WeightedLabel] {
        if let hit = enIndex[term] { return hit }
        for candidate in Self.singularForms(of: term) {
            if let hit = enIndex[candidate] { return hit }
        }
        return []
    }

    static func singularForms(of word: String) -> [String] {
        var out: [String] = []
        if word.hasSuffix("ies"), word.count > 4 { out.append(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("es"), word.count > 3 { out.append(String(word.dropLast(2))) }
        if word.hasSuffix("s"), word.count > 3 { out.append(String(word.dropLast())) }
        return out
    }
}
