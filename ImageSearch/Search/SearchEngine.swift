import Foundation

/// 一个检索词被"理解"成了什么（用于界面展示，让用户知道为什么搜到这些图）
struct TermInterpretation: Sendable, Hashable, Identifiable {
    enum Via: Sendable, Hashable {
        case dictionary              // 内置词典
        case semantic                // 本机词向量近义词（iOS 自带，离线）
        case meta                    // 截图、收藏、人脸、二维码…
        case date                    // 日期
        case textOnly                // 只匹配图中文字
    }
    var id: String { term }
    let term: String
    let via: Via
    let labelNames: [String]        // 展示用的中文标签名（前几个）
}

struct SearchHit: Sendable, Identifiable, Hashable {
    let id: String
    let score: Float
    let matchedTerms: Int
    let reasons: [String]
}

/// 这次检索用到的某项识别，在一部分图片上没跑成（结果可能不全）
struct IncompleteAnalysis: Sendable, Hashable {
    let name: String    // 如 "人脸检测"
    let count: Int      // 没跑成的图片数
}

struct SearchOutcome: Sendable {
    let query: String
    let interpretations: [TermInterpretation]
    let hits: [SearchHit]
    let termCount: Int
    let fullMatchCount: Int
    /// 没有高置信度结果时，放宽阈值后得到的"可能相关"结果
    let isLowConfidence: Bool
    /// 检索依赖的识别没跑成的图片：让用户分清"没有"和"没检测成"
    let incomplete: [IncompleteAnalysis]

    static func empty(_ q: String = "") -> SearchOutcome {
        SearchOutcome(query: q, interpretations: [], hits: [], termCount: 0, fullMatchCount: 0,
                      isLowConfidence: false, incomplete: [])
    }
}

/// 检索引擎：纯本机计算（不联网），输入索引记录 + 元数据，输出按相关度排序的结果
struct SearchEngine: Sendable {
    let dictionary: LabelDictionary
    let expander: SemanticExpander

    /// 标签置信度低于该值不算命中（Vision 低置信度标签噪声较大）
    static let labelThreshold: Float = 0.25
    /// 一个结果都没有时放宽到这个阈值，给出"可能相关"的结果
    static let fallbackThreshold: Float = 0.08
    static let ocrScore: Float = 0.8
    /// 日期词（如 2024）也去匹配图中文字（截图、票据上的日期），分数低于拍摄日期命中的 1.0，排在它们后面
    static let ocrDateScore: Float = 0.7
    static let ocrSynonymScore: Float = 0.65
    static let fileNameScore: Float = 0.6
    static let maxSynonymNeedles = 12

    init(dictionary: LabelDictionary = .shared, expander: SemanticExpander = .shared) {
        self.dictionary = dictionary
        self.expander = expander
    }

    struct Needle: Sendable {
        let text: String
        let isCJK: Bool
    }

    struct TermPlan {
        let term: String
        var labels: [String: Float] = [:]
        /// 打分时的遍历顺序：权重高的在前；同分时优先显示名与检索词相同的标签（猫 而不是 猫科）
        var orderedLabels: [(label: String, weight: Float)] = []
        var metas: [(MetaPredicate, Float)] = []
        var date: DateFilter?
        var ocrNeedle: Needle?
        var synonymNeedles: [Needle] = []
        var via: TermInterpretation.Via = .textOnly
    }

    // MARK: - 理解检索词

    func plan(for query: String, now: Date = Date(), calendar: Calendar = .current) -> [TermPlan] {
        QueryParser.parse(query, dictionary: dictionary, now: now, calendar: calendar).map { term -> TermPlan in
            var p = makePlan(term)
            p.orderedLabels = p.labels.map { (label: $0.key, weight: $0.value) }.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                let an = dictionary.displayName(for: a.label), bn = dictionary.displayName(for: b.label)
                if (an == p.term) != (bn == p.term) { return an == p.term }
                return an.count != bn.count ? an.count < bn.count : a.label < b.label
            }
            return p
        }
    }

    private func makePlan(_ term: QueryTerm) -> TermPlan {
        switch term.kind {
        case .date(let f):
            var p = TermPlan(term: term.text)
            p.date = f
            p.via = .date
            let compact = term.text.filter { !$0.isWhitespace }
            p.ocrNeedle = Needle(text: compact, isCJK: TextNormalizer.containsCJK(compact))
            return p
        case .word:
            return planWord(term.text)
        }
    }

    private func planWord(_ t: String) -> TermPlan {
        var p = TermPlan(term: t)
        let isCJK = TextNormalizer.containsCJK(t)
        p.ocrNeedle = (isCJK || t.count >= 2) ? Needle(text: t, isCJK: isCJK) : nil

        func merge(_ hits: [WeightedLabel], scale: Float = 1) {
            for h in hits { p.labels[h.label] = max(p.labels[h.label] ?? 0, h.weight * scale) }
        }

        if let meta = QueryParser.metaKeywords[t] {
            p.metas.append(meta)
            p.via = .meta
        }

        var direct: [WeightedLabel] = []
        if isCJK {
            direct = dictionary.lookupChinese(t)
            if !direct.isEmpty {
                merge(direct)
                if p.metas.isEmpty { p.via = .dictionary }
            } else {
                // 1) 包含词典里的词，如「小猫咪」包含「猫咪」
                if let sub = longestKnownSubstring(of: t) {
                    merge(dictionary.lookupChinese(sub), scale: sub.count >= 2 ? 0.8 : 0.6)
                }
                // 2) 本机词向量近义词，如「喵星人」→「猫咪」
                if p.labels.isEmpty {
                    for (neighbor, d) in expander.chineseNeighbors(of: t, where: { dictionary.knowsChinese($0) }) {
                        merge(dictionary.lookupChinese(neighbor), scale: SemanticExpander.weight(forDistance: d))
                    }
                }
                // 3) 仍然没有：只在图中文字里查找这个词
                if !p.labels.isEmpty && p.metas.isEmpty { p.via = .semantic }
            }
        } else {
            direct = dictionary.lookupEnglish(t)
            for (label, w) in englishLabels(for: t) { p.labels[label] = max(p.labels[label] ?? 0, w) }
            if !p.labels.isEmpty && p.metas.isEmpty { p.via = direct.isEmpty ? .semantic : .dictionary }
        }

        // 同义词也去匹配图中文字（跨语言）：收据 → 小票/发票/receipt，invoice → 发票
        var seen: Set<String> = [t]
        for hit in direct.sorted(by: { $0.weight > $1.weight }) where hit.weight >= 1.0 {
            for s in dictionary.textSynonyms(for: hit.label) where !seen.contains(s) {
                seen.insert(s)
                p.synonymNeedles.append(Needle(text: s, isCJK: TextNormalizer.containsCJK(s)))
                if p.synonymNeedles.count >= Self.maxSynonymNeedles { break }
            }
            if p.synonymNeedles.count >= Self.maxSynonymNeedles { break }
        }
        return p
    }

    /// 英文词/短语 → 标签：先查词典（含复数还原），查不到再用英文词向量找近义词
    func englishLabels(for text: String) -> [String: Float] {
        let normalized = normalizeEnglish(text)
        var out: [String: Float] = [:]
        let whole = dictionary.lookupEnglish(normalized)
        if !whole.isEmpty { return merged(whole) }
        for w in normalized.split(separator: " ").map(String.init) where !QueryParser.stopWords.contains(w) {
            out.merge(singleEnglishWord(w), uniquingKeysWith: max)
        }
        return out
    }

    private func singleEnglishWord(_ w: String) -> [String: Float] {
        let hits = dictionary.lookupEnglish(w)
        if !hits.isEmpty { return merged(hits) }
        var out: [String: Float] = [:]
        for (neighbor, d) in expander.englishNeighbors(of: w, where: { dictionary.knowsEnglish($0) }) {
            out.merge(merged(dictionary.lookupEnglish(neighbor), scale: SemanticExpander.weight(forDistance: d)),
                      uniquingKeysWith: max)
        }
        return out
    }

    private func merged(_ hits: [WeightedLabel], scale: Float = 1) -> [String: Float] {
        var out: [String: Float] = [:]
        for h in hits { out[h.label] = max(out[h.label] ?? 0, h.weight * scale) }
        return out
    }

    private func normalizeEnglish(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func longestKnownSubstring(of s: String) -> String? {
        let chars = Array(s)
        guard chars.count > 1 else { return nil }
        for len in stride(from: min(chars.count - 1, dictionary.maxChineseKeyLength), through: 1, by: -1) {
            for start in 0...(chars.count - len) {
                let sub = String(chars[start..<(start + len)])
                if dictionary.knowsChinese(sub) { return sub }
            }
        }
        return nil
    }

    func interpretations(of plans: [TermPlan]) -> [TermInterpretation] {
        plans.map { p in
            let names = p.labels.sorted { $0.value > $1.value }.map { dictionary.displayName(for: $0.key) }
            var unique: [String] = []
            for n in names where !unique.contains(n) && n != p.term { unique.append(n) }
            var shown = Array(unique.prefix(4))
            for (m, _) in p.metas where !shown.contains(m.title) && m.title != p.term { shown.insert(m.title, at: 0) }
            return TermInterpretation(term: p.term, via: p.via, labelNames: shown)
        }
    }

    // MARK: - 打分排序

    func search(query: String, ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta],
                now: Date = Date(), calendar: Calendar = .current) -> SearchOutcome {
        let plans = plan(for: query, now: now, calendar: calendar)
        guard !plans.isEmpty else { return .empty(query) }

        var hits = rank(plans, ids: ids, records: records, metas: metas, threshold: Self.labelThreshold, calendar: calendar)
        var lowConfidence = false
        if hits.isEmpty {
            hits = rank(plans, ids: ids, records: records, metas: metas, threshold: Self.fallbackThreshold, calendar: calendar)
            lowConfidence = !hits.isEmpty
        }
        let full = hits.filter { $0.matchedTerms == plans.count }.count
        return SearchOutcome(query: query, interpretations: interpretations(of: plans), hits: hits,
                             termCount: plans.count, fullMatchCount: full, isLowConfidence: lowConfidence,
                             incomplete: incompleteAnalyses(for: plans, ids: ids, records: records))
    }

    /// 检索词依赖哪些识别：标签 → 画面识别，图中文字 → 文字识别，人脸 / 二维码 / 条码 → 对应检测
    static func requiredAnalyses(for plans: [TermPlan]) -> RecordFlags {
        var need: RecordFlags = []
        for p in plans {
            if !p.labels.isEmpty { need.insert(.classifierUnavailable) }
            if p.ocrNeedle != nil || !p.synonymNeedles.isEmpty { need.insert(.textRecognitionFailed) }
            for (m, _) in p.metas {
                switch m {
                case .faces: need.insert(.faceDetectionFailed)
                case .qrCode, .barcode: need.insert(.barcodeDetectionFailed)
                case .hasText: need.insert(.textRecognitionFailed)
                default: break
                }
            }
        }
        return need
    }

    private func incompleteAnalyses(for plans: [TermPlan], ids: [String],
                                    records: [String: ImageRecord]) -> [IncompleteAnalysis] {
        let need = Self.requiredAnalyses(for: plans)
        guard !need.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        for id in ids {
            guard let missing = records[id]?.flags.intersection(need), !missing.isEmpty else { continue }
            for item in RecordFlags.analysisItems where missing.contains(item.flag) {
                counts[item.flag.rawValue, default: 0] += 1
            }
        }
        return RecordFlags.analysisItems.compactMap { item in
            counts[item.flag.rawValue].map { IncompleteAnalysis(name: item.name, count: $0) }
        }
    }

    private func rank(_ plans: [TermPlan], ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta],
                      threshold: Float, calendar: Calendar) -> [SearchHit] {
        var hits: [SearchHit] = []
        for id in ids {
            let record = records[id]
            let meta = metas[id]
            var matched = 0
            var total: Float = 0
            var reasons: [String] = []
            for p in plans {
                let (s, reason) = score(p, id: id, record: record, meta: meta, threshold: threshold, calendar: calendar)
                if s > 0 {
                    matched += 1
                    total += s
                    if let reason { reasons.append(reason) }
                }
            }
            if matched > 0 {
                hits.append(SearchHit(id: id, score: total / Float(plans.count), matchedTerms: matched, reasons: reasons))
            }
        }
        // 排序：命中的检索词数量 → 平均得分 → 时间新的在前（ids 已按时间倒序）
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        hits.sort {
            if $0.matchedTerms != $1.matchedTerms { return $0.matchedTerms > $1.matchedTerms }
            if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
        return hits
    }

    private func score(_ p: TermPlan, id: String, record: ImageRecord?, meta: ImageMeta?,
                       threshold: Float, calendar: Calendar) -> (Float, String?) {
        var best: Float = 0
        var reason: String?
        func consider(_ s: Float, _ r: @autoclosure () -> String) {
            if s > best { best = s; reason = r() }
        }

        if let record {
            for (label, w) in p.orderedLabels {
                let c = record.confidence(of: label)
                if c >= threshold {
                    consider(c * w, "\(dictionary.displayName(for: label)) \(Int((c * 100).rounded()))%")
                }
            }
            if let needle = p.ocrNeedle, ocrContains(record, needle, digitBoundary: p.date != nil) {
                consider(p.date == nil ? Self.ocrScore : Self.ocrDateScore, "图中文字含「\(needle.text)」")
            }
            if best < Self.ocrSynonymScore {
                for needle in p.synonymNeedles where ocrContains(record, needle) {
                    consider(Self.ocrSynonymScore, "图中文字含「\(needle.text)」")
                    break
                }
            }
        }
        for (m, w) in p.metas where m.matches(id: id, record: record, meta: meta) {
            consider(w, m.title)
        }
        if let d = p.date, let created = meta?.creationDate, d.contains(created, calendar: calendar) {
            consider(1.0, "拍摄于\(p.term)")
        }
        if let needle = p.ocrNeedle, let name = meta?.fileName?.lowercased(), name.contains(needle.text) {
            consider(Self.fileNameScore, "文件名含「\(needle.text)」")
        }
        return (best, reason)
    }

    /// 中文按子串匹配；英文按单词边界匹配。digitBoundary：前后也不能紧挨数字（年份 2024 不匹配单号 20241231）
    private func ocrContains(_ record: ImageRecord, _ needle: Needle, digitBoundary: Bool = false) -> Bool {
        if needle.isCJK { return record.ocrCompact.contains(needle.text) }
        let hay = record.ocrLower
        guard !hay.isEmpty else { return false }
        func isBoundary(_ c: Character) -> Bool { !c.isLetter && !(digitBoundary && c.isNumber) }
        var range = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle.text, range: range) {
            let beforeOK = r.lowerBound == hay.startIndex || isBoundary(hay[hay.index(before: r.lowerBound)])
            let afterOK = r.upperBound == hay.endIndex || isBoundary(hay[r.upperBound])
            if beforeOK && afterOK { return true }
            range = hay.index(after: r.lowerBound)..<hay.endIndex
        }
        return false
    }
}
