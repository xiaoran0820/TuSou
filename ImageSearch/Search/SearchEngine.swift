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
    /// 这个词也由 MobileCLIP 的画面语义比对
    var bySemantic = false
}

struct SearchHit: Sendable, Identifiable, Hashable {
    let id: String
    let score: Float
    let matchedTerms: Int
    let reasons: [String]
    /// 与 MobileCLIP 描述的相似度（没有算过线时为 0）：得分相同时按它排
    var similarity: Float = 0
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
    /// 还没建好索引（或索引没能保存）的图片数：它们没有参与这次检索
    let pendingCount: Int
    /// 图片本身读取失败、一项识别都没做成的图片数
    let unreadableCount: Int
    /// 交给 MobileCLIP 比对画面的英文描述（没用到时为 nil）
    var semanticPrompt: String? = nil

    /// 同时符合全部检索词的结果（只有一个词时就是全部结果）
    var fullHits: [SearchHit] { hits.filter { $0.matchedTerms == termCount } }
    /// 主列表：有完全匹配时只放完全匹配；一张都没有时，放全部（都只符合部分条件）
    var primaryHits: [SearchHit] { fullMatchCount > 0 ? fullHits : hits }
    /// 有完全匹配时，只符合部分条件的结果默认收起（「骑自行车的人」不该列出所有有人的照片）
    var collapsedHits: [SearchHit] { fullMatchCount > 0 ? hits.filter { $0.matchedTerms < termCount } : [] }

    static func empty(_ q: String = "") -> SearchOutcome {
        SearchOutcome(query: q, interpretations: [], hits: [], termCount: 0, fullMatchCount: 0,
                      isLowConfidence: false, incomplete: [], pendingCount: 0, unreadableCount: 0)
    }
}

/// 检索时启用哪些信号。App 里全部启用；评测时关掉一部分做对比实验
struct SearchOptions: Sendable, Hashable {
    /// Vision 画面标签（中文词经词典映射到标签）
    var labels = true
    /// 图中文字：检索词本身出现在图里（以及文件名）
    var text = true
    /// 扩展：同义词跨语言匹配图中文字（发票 → RECEIPT），词典外的词用系统词向量找近义词
    var expansion = true
    /// MobileCLIP：描述与画面的语义相似度
    var semantic = true
    /// 画面语义过线：图片 ≥ 30 张时，相似度要比这次检索的平均高出多少个标准差
    var semanticMinZ: Float = SearchEngine.semanticMinZ
    /// 画面语义过线：最多比这次最像的那张低多少（nil 表示不限）
    var semanticMaxGap: Float? = SearchEngine.semanticMaxGap
    /// 多个词时，有独立识别依据（画面标签、人脸等）的词要单独再和画面比一次，过线的 z 门槛（nil 表示不逐词核对）
    var termCheckMinZ: Float? = SearchEngine.termCheckMinZ
    /// 逐词核对时的绝对相似度下限（比整句低：图里较小的东西单独比对，相似度本来就低）
    var termCheckMinSimilarity: Float = SearchEngine.termCheckMinSimilarity
    /// 整句描述匹配得很强（相似度 ≥ 这个值）时不再逐词核对（nil 表示总是核对）
    var termCheckBypassSimilarity: Float? = SearchEngine.termCheckBypassSimilarity
    /// 过线的 z 门槛随图库大小提高，让「纯属偶然」能过线的图大约保持在几张（semanticMinZ 是下限）
    var semanticAdaptiveZ = true

    static let all = SearchOptions()
}

/// 检索引擎：纯本机计算（不联网），输入索引记录 + 元数据，输出按相关度排序的结果
struct SearchEngine: Sendable {
    let dictionary: LabelDictionary
    let expander: SemanticExpander
    /// MobileCLIP 的文字编码；没有模型时为 nil，检索退回画面标签 + 图中文字
    let textEmbedder: (any TextEmbedder)?
    var options: SearchOptions
    /// 中英对照表：内置词表和标签词典都翻不了的中文词（富士山、东京塔…），靠它转成英文交给 MobileCLIP
    let glossary: Glossary

    /// MobileCLIP 相似度至少要到这个值才算匹配。依据：5 张测试图里对得上的图文最低 0.203、对不上的最高 0.134
    static let semanticMinSimilarity: Float = 0.18
    /// 图片较多时，相似度还要比这次检索的平均水平高出这么多个标准差。
    /// 原来是 1.5，等于每次都放进图库里相似度最高的 7% 左右，图库越大混进的不相关图越多。
    /// 2026-11-10 按 118 张评测集的诊断改成 2.5；图库更大时由 requiredZ 自动提高（COCO 的 5,000 张约为 3.1）
    static let semanticMinZ: Float = 2.5
    /// 门槛随图库大小提高时，让偶然过线的图期望约有这么多张；z 最高提到 semanticMaxZ
    static let semanticChanceMatches = 5.0
    static let semanticMaxZ: Float = 3.5
    /// 整句描述相似度达到这个值，就不再逐词核对
    static let termCheckBypassSimilarity: Float? = 0.25
    /// 与这次最像的那张图相比，相似度最多低多少才算匹配（nil 表示不限）。
    /// 在 COCO 上，z 3.0 加上这一条让单个物体查询显示的不相关图从 35% 降到 25%，找到的相关图从 76% 降到 72%
    static let semanticMaxGap: Float? = 0.10
    /// 多个词时逐词核对画面的 z 门槛和绝对相似度下限（低于整句的 0.18：图里较小的东西单独比对，相似度本来就低）
    static let termCheckMinZ: Float? = 1.5
    static let termCheckMinSimilarity: Float = 0.15
    /// 图片少于这个数时标准差不可靠，只看绝对相似度
    static let semanticMinSampleForZ = 30

    /// 标签置信度低于该值不算命中（Vision 低置信度标签噪声较大）
    static let labelThreshold: Float = 0.25
    /// 一个结果都没有时放宽到这个阈值，给出"可能相关"的结果
    static let fallbackThreshold: Float = 0.08
    static let ocrScore: Float = 0.8
    /// 只有一个汉字出现在图中文字里（搜「花」时菜单上的「花生」）是很弱的证据：排在画面语义匹配（最低 0.5）后面
    static let ocrSingleCharScore: Float = 0.45
    /// 日期词（如 2024）也去匹配图中文字（截图、票据上的日期），分数低于拍摄日期命中的 1.0，排在它们后面
    static let ocrDateScore: Float = 0.7
    static let ocrSynonymScore: Float = 0.65
    static let fileNameScore: Float = 0.6
    static let maxSynonymNeedles = 12

    init(dictionary: LabelDictionary = .shared, expander: SemanticExpander = .shared,
         textEmbedder: (any TextEmbedder)? = nil, options: SearchOptions = .all, glossary: Glossary = .shared) {
        self.dictionary = dictionary
        self.expander = expander
        self.textEmbedder = textEmbedder
        self.options = options
        self.glossary = glossary
    }

    /// 一张图与描述的语义匹配：分数（0.5～1）和原始相似度
    struct SemanticMatch: Sendable {
        let score: Float
        let similarity: Float
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
        /// 词典里直接查到的标签（与是否启用画面标签无关，用来给 MobileCLIP 翻译）
        var dictionaryLabels: [WeightedLabel] = []
        /// 放进 MobileCLIP 描述时的英文；转不成英文的中文词为 nil
        var promptWord: String?
        /// 含相册属性（截图、收藏…）或来源条件：只按记录判断，不进 MobileCLIP 描述
        var hasLibraryAttribute: Bool { metas.contains { $0.0.isLibraryAttribute } }
        /// 有独立的识别依据（词典直接对应的画面标签、人脸 / 二维码等检测）：多个词时，这个词要有自己的证据才算命中。
        /// 只看词典里的正式同义词（权重 1）：扩展猜的、复合标签拆出来的部件（red_wine 里的 red）、「相关词」都不算
        var hasIndependentDetector: Bool { dictionaryLabels.contains { $0.weight >= 1.0 } || !metas.isEmpty }
    }

    // MARK: - 理解检索词

    func plan(for query: String, now: Date = Date(), calendar: Calendar = .current) -> [TermPlan] {
        QueryParser.parse(query, dictionary: dictionary, glossary: glossary, now: now, calendar: calendar).map { term -> TermPlan in
            var p = makePlan(term)
            p.orderedLabels = p.labels.map { (label: $0.key, weight: $0.value) }.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                return preferredLabel(a.label, over: b.label, term: p.term)
            }
            p.promptWord = promptWord(for: p)
            return p
        }
    }

    /// 同分时优先显示名与检索词相同的标签（猫 而不是 猫科），再优先名字短的
    private func preferredLabel(_ a: String, over b: String, term: String) -> Bool {
        let an = dictionary.displayName(for: a), bn = dictionary.displayName(for: b)
        if (an == term) != (bn == term) { return an == term }
        return an.count != bn.count ? an.count < bn.count : a < b
    }

    /// 有 MobileCLIP 时，常用词表或中英对照表里有英文的词（菜单、下雨、富士山）交给画面语义比对，
    /// 不再拆字或找近义词去猜标签：「菜单」拆出「菜」会匹配食物，「富士山」拆出「山」会匹配所有的山
    private func lexiconLeadsToSemantic(_ t: String) -> Bool {
        options.semantic && textEmbedder != nil && (PromptLexicon.english[t] != nil || glossary.english(for: t) != nil)
    }

    /// 这个词放进 MobileCLIP 描述时的英文：英文词原样；中文词先查常用词表，再取词典里的标签名。
    /// 日期和相册属性（截图、收藏、自拍等）只按各自的条件判断，不进描述；人脸、二维码这类画面内容照常进描述
    private func promptWord(for p: TermPlan) -> String? {
        guard p.date == nil, !p.hasLibraryAttribute else { return nil }
        if !TextNormalizer.containsCJK(p.term) { return p.term }
        if let en = PromptLexicon.english[p.term] { return en }
        let best = p.dictionaryLabels.filter { $0.weight >= 1.0 }
            .min { preferredLabel($0.label, over: $1.label, term: p.term) }
        // 最后查中英对照表（富士山 → Mt. Fuji）
        return best.map { dictionary.englishName(for: $0.label) } ?? glossary.english(for: p.term)
    }

    /// 给 MobileCLIP 的英文描述。全英文且不含日期的查询直接用原文（去掉 screenshot、favorite 这类照片属性词）；
    /// 否则把能转成英文的词按原顺序拼起来
    func semanticPrompt(for plans: [TermPlan], query: String) -> String? {
        if isWholeEnglish(plans, query: query) {
            let attributes = Set(plans.filter(\.hasLibraryAttribute).map { $0.term.lowercased() })
            let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                .filter { !attributes.contains($0.trimmingCharacters(in: .punctuationCharacters)) }
            return words.isEmpty ? nil : "a photo of " + words.joined(separator: " ")
        }
        let words = plans.compactMap(\.promptWord)
        // 介词短语放到后面，更像英文：「夜晚的城市」→ city at night，「下雨的街道」→ street in the rain
        let isPhrase: (String) -> Bool = { w in ["at ", "in ", "on ", "under ", "with ", "by ", "during "].contains { w.hasPrefix($0) } }
        let ordered = words.filter { !isPhrase($0) } + words.filter(isPhrase)
        return ordered.isEmpty ? nil : "a photo of " + ordered.joined(separator: " ")
    }

    private func isWholeEnglish(_ plans: [TermPlan], query: String) -> Bool {
        !TextNormalizer.containsCJK(query) && !plans.contains { $0.date != nil }
    }

    /// 哪些检索词被描述覆盖（这些词可以由画面语义匹配来满足；日期、属性等仍要各自满足）
    private func coveredTerms(_ plans: [TermPlan], query: String) -> [Bool] {
        let whole = isWholeEnglish(plans, query: query)
        return plans.map { whole ? ($0.date == nil && !$0.hasLibraryAttribute) : $0.promptWord != nil }
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
        if options.text { p.ocrNeedle = (isCJK || t.count >= 2) ? Needle(text: t, isCJK: isCJK) : nil }

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
            if options.labels {
                if !direct.isEmpty {
                    merge(direct)
                    if p.metas.isEmpty { p.via = .dictionary }
                } else if options.expansion && !lexiconLeadsToSemantic(t) {
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
            }
        } else {
            direct = dictionary.lookupEnglish(t)
            if options.labels {
                for (label, w) in englishLabels(for: t, useNeighbors: options.expansion) {
                    p.labels[label] = max(p.labels[label] ?? 0, w)
                }
                if !p.labels.isEmpty && p.metas.isEmpty { p.via = direct.isEmpty ? .semantic : .dictionary }
            }
        }
        p.dictionaryLabels = direct

        // 同义词也去匹配图中文字（跨语言）：收据 → 小票/发票/receipt，invoice → 发票
        if options.text && options.expansion {
            var seen: Set<String> = [t]
            for hit in direct.sorted(by: { $0.weight > $1.weight }) where hit.weight >= 1.0 {
                for s in dictionary.textSynonyms(for: hit.label) where !seen.contains(s) {
                    seen.insert(s)
                    p.synonymNeedles.append(Needle(text: s, isCJK: TextNormalizer.containsCJK(s)))
                    if p.synonymNeedles.count >= Self.maxSynonymNeedles { break }
                }
                if p.synonymNeedles.count >= Self.maxSynonymNeedles { break }
            }
        }
        return p
    }

    /// 英文词/短语 → 标签：先查词典（含复数还原），查不到再用英文词向量找近义词
    func englishLabels(for text: String, useNeighbors: Bool = true) -> [String: Float] {
        let normalized = normalizeEnglish(text)
        var out: [String: Float] = [:]
        let whole = dictionary.lookupEnglish(normalized)
        if !whole.isEmpty { return merged(whole) }
        for w in normalized.split(separator: " ").map(String.init) where !QueryParser.stopWords.contains(w) {
            out.merge(singleEnglishWord(w, useNeighbors: useNeighbors), uniquingKeysWith: max)
        }
        return out
    }

    private func singleEnglishWord(_ w: String, useNeighbors: Bool) -> [String: Float] {
        let hits = dictionary.lookupEnglish(w)
        if !hits.isEmpty { return merged(hits) }
        guard useNeighbors else { return [:] }
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

    func interpretations(of plans: [TermPlan], covered: [Bool]? = nil) -> [TermInterpretation] {
        plans.enumerated().map { k, p in
            let names = p.labels.sorted { $0.value > $1.value }.map { dictionary.displayName(for: $0.key) }
            var unique: [String] = []
            for n in names where !unique.contains(n) && n != p.term { unique.append(n) }
            var shown = Array(unique.prefix(4))
            for (m, _) in p.metas where !shown.contains(m.title) && m.title != p.term { shown.insert(m.title, at: 0) }
            return TermInterpretation(term: p.term, via: p.via, labelNames: shown, bySemantic: covered?[k] ?? false)
        }
    }

    // MARK: - 打分排序

    func search(query: String, ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta],
                now: Date = Date(), calendar: Calendar = .current) -> SearchOutcome {
        let plans = plan(for: query, now: now, calendar: calendar)
        guard !plans.isEmpty else { return .empty(query) }

        // MobileCLIP：描述与画面的语义相似度
        var prompt: String?
        var semantic: [String: SemanticMatch] = [:]
        if options.semantic, textEmbedder != nil, let p = semanticPrompt(for: plans, query: query) {
            prompt = p
            semantic = semanticMatches(prompt: p, ids: ids, records: records)
        }
        let covered = prompt == nil ? plans.map { _ in false } : coveredTerms(plans, query: query)
        let checks = termChecks(plans, covered: covered, ids: ids, records: records)

        var hits = rank(plans, covered: covered, semantic: semantic, termChecks: checks, ids: ids, records: records,
                        metas: metas, threshold: Self.labelThreshold, calendar: calendar)
        var lowConfidence = false
        if hits.isEmpty {
            hits = rank(plans, covered: covered, semantic: semantic, termChecks: checks, ids: ids, records: records,
                        metas: metas, threshold: Self.fallbackThreshold, calendar: calendar)
            lowConfidence = !hits.isEmpty
        }
        let full = hits.filter { $0.matchedTerms == plans.count }.count
        let cov = coverage(for: plans, ids: ids, records: records,
                           semanticModel: prompt == nil ? nil : textEmbedder?.modelID)
        return SearchOutcome(query: query, interpretations: interpretations(of: plans, covered: covered), hits: hits,
                             termCount: plans.count, fullMatchCount: full, isLowConfidence: lowConfidence,
                             incomplete: cov.incomplete, pendingCount: cov.pending, unreadableCount: cov.unreadable,
                             semanticPrompt: prompt)
    }

    /// 评测用（第 0 轮「只用 MobileCLIP」）：把每张有向量的图按与描述的相似度从高到低全部列出，不设门槛，
    /// 和评测程序的方案 E 一样。查询翻不成英文描述时没有结果
    func rankBySimilarity(query: String, ids: [String], records: [String: ImageRecord],
                          now: Date = Date(), calendar: Calendar = .current) -> SearchOutcome {
        let pending = ids.filter { records[$0] == nil }.count
        guard let embedder = textEmbedder,
              let prompt = semanticPrompt(for: plan(for: query, now: now, calendar: calendar), query: query),
              let v = embedder.embed(text: prompt) else {
            return SearchOutcome(query: query, interpretations: [], hits: [], termCount: 1, fullMatchCount: 0,
                                 isLowConfidence: false, incomplete: [], pendingCount: pending, unreadableCount: 0)
        }
        var hits: [SearchHit] = []
        var missing = 0
        for id in ids {
            guard let r = records[id] else { continue }
            guard r.clipModel == embedder.modelID, let e = r.clipEmbedding else { missing += 1; continue }
            let s = MobileCLIP.similarity(e, v)
            hits.append(SearchHit(id: id, score: s, matchedTerms: 1,
                                  reasons: ["相似度 \(String(format: "%.3f", s))"], similarity: s))   // 缩略图上放得下
        }
        hits.sort { $0.similarity > $1.similarity }
        return SearchOutcome(query: query, interpretations: [], hits: hits, termCount: 1, fullMatchCount: hits.count,
                             isLowConfidence: false,
                             incomplete: missing > 0 ? [IncompleteAnalysis(name: "画面语义比对", count: missing)] : [],
                             pendingCount: pending, unreadableCount: 0, semanticPrompt: prompt)
    }

    /// 每张有向量的图与描述的相似度，换算成分数；不够格的不出现在结果里
    func semanticMatches(prompt: String, ids: [String], records: [String: ImageRecord]) -> [String: SemanticMatch] {
        let n = ids.count
        let z = options.semanticAdaptiveZ ? Self.requiredZ(count: n, floor: options.semanticMinZ) : options.semanticMinZ
        return semanticMatches(prompt: prompt, ids: ids, records: records, minZ: z, maxGap: options.semanticMaxGap)
    }

    /// 图库越大，同样的 z 门槛能「纯属偶然」过线的图越多：按正态分布让偶然过线的图期望约 semanticChanceMatches 张，
    /// 不低于 floor、不高于 semanticMaxZ。118 张时取下限 2.5，1,000 张约 2.6，5,000 张约 3.1，2 万张约 3.5
    static func requiredZ(count: Int, floor: Float) -> Float {
        guard count > 0 else { return floor }
        let tail = min(0.5, semanticChanceMatches / Double(count))   // 要求 P(Z ≥ z) = tail
        var lo = 0.0, hi = 8.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if 0.5 * erfc(mid / 2.0.squareRoot()) > tail { lo = mid } else { hi = mid }
        }
        return min(max(floor, Float(lo)), semanticMaxZ)
    }

    func semanticMatches(prompt: String, ids: [String], records: [String: ImageRecord],
                         minZ: Float, maxGap: Float?, minSimilarity: Float = semanticMinSimilarity) -> [String: SemanticMatch] {
        guard let embedder = textEmbedder, let query = embedder.embed(text: prompt) else { return [:] }
        var sims: [(id: String, similarity: Float)] = []
        sims.reserveCapacity(ids.count)
        for id in ids {
            guard let r = records[id], r.clipModel == embedder.modelID, let e = r.clipEmbedding else { continue }
            sims.append((id, MobileCLIP.similarity(e, query)))
        }
        guard !sims.isEmpty else { return [:] }
        let n = Float(sims.count)
        let mean = sims.reduce(0) { $0 + $1.similarity } / n
        let std = (sims.reduce(0) { $0 + ($1.similarity - mean) * ($1.similarity - mean) } / n).squareRoot()
        let best = sims.map(\.similarity).max() ?? 0
        var out: [String: SemanticMatch] = [:]
        for s in sims {
            if let maxGap, s.similarity < best - maxGap { continue }
            let score = Self.semanticScore(similarity: s.similarity, mean: mean, std: std, count: sims.count, minZ: minZ,
                                           minSimilarity: minSimilarity)
            if score > 0 { out[s.id] = SemanticMatch(score: score, similarity: s.similarity) }
        }
        return out
    }

    /// 相似度换算成分数（0 表示不算匹配）。绝对值要够；图片较多时还要明显高于这次检索的平均水平，
    /// 避免"泛泛有点像"的图都进来。刚过线是 0.5，相似度每高 0.12 封顶到 1。
    static func semanticScore(similarity s: Float, mean: Float, std: Float, count: Int,
                              minZ: Float = semanticMinZ, minSimilarity: Float = semanticMinSimilarity) -> Float {
        guard s >= minSimilarity else { return 0 }
        if count >= semanticMinSampleForZ {
            guard std > 0.0001, (s - mean) / std >= minZ else { return 0 }
        }
        return 0.5 + 0.5 * min(1, (s - semanticMinSimilarity) / 0.12)
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

    /// 这次检索覆盖得怎么样，三种情况分开数：
    /// 还没建好索引的（pending）、图片读取失败的（unreadable）、某项需要的识别没跑成的（incomplete）
    private func coverage(for plans: [TermPlan], ids: [String], records: [String: ImageRecord], semanticModel: String?)
        -> (pending: Int, unreadable: Int, incomplete: [IncompleteAnalysis]) {
        let need = Self.requiredAnalyses(for: plans)
        var pending = 0, unreadable = 0, missingEmbedding = 0
        var counts: [Int: Int] = [:]
        for id in ids {
            guard let r = records[id] else { pending += 1; continue }
            if r.flags.contains(.analysisFailed) { unreadable += 1; continue }
            if let m = semanticModel, !r.hasEmbedding(from: m) { missingEmbedding += 1 }
            let missing = r.flags.intersection(need)
            guard !missing.isEmpty else { continue }
            for item in RecordFlags.analysisItems where missing.contains(item.flag) {
                counts[item.flag.rawValue, default: 0] += 1
            }
        }
        var incomplete = RecordFlags.analysisItems.compactMap { item in
            counts[item.flag.rawValue].map { IncompleteAnalysis(name: item.name, count: $0) }
        }
        // 刚装上模型、还在补算向量时：这些图暂时只能按标签和文字匹配
        if missingEmbedding > 0 { incomplete.append(IncompleteAnalysis(name: "画面语义比对", count: missingEmbedding)) }
        return (pending, unreadable, incomplete)
    }

    /// 多个词时，有独立识别依据（画面标签、人脸等）的词要单独再和画面比一次：
    /// 不然「椅子 餐桌」这种组合，只像其中一样东西的图也会因为整句描述有点像而两个词都算命中。
    /// 颜色、「夜晚」这类没有独立识别依据的词，照旧由整句描述的匹配来满足
    private func termChecks(_ plans: [TermPlan], covered: [Bool], ids: [String],
                            records: [String: ImageRecord]) -> [Int: [String: SemanticMatch]] {
        guard let minZ = options.termCheckMinZ, covered.filter({ $0 }).count >= 2 else { return [:] }
        var out: [Int: [String: SemanticMatch]] = [:]
        for (k, p) in plans.enumerated() where covered[k] && p.hasIndependentDetector {
            guard let word = p.promptWord else { continue }
            out[k] = semanticMatches(prompt: "a photo of " + word, ids: ids, records: records, minZ: minZ, maxGap: nil,
                                     minSimilarity: options.termCheckMinSimilarity)
        }
        return out
    }

    /// covered[k]：第 k 个检索词是否被 MobileCLIP 的描述覆盖；被覆盖的词，画面语义匹配也算命中（取两者较高的分数）。
    /// termChecks[k]：这个词单独比对过线的图；有这一项时，画面语义匹配只对这些图算数
    private func rank(_ plans: [TermPlan], covered: [Bool], semantic: [String: SemanticMatch],
                      termChecks: [Int: [String: SemanticMatch]],
                      ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta],
                      threshold: Float, calendar: Calendar) -> [SearchHit] {
        var hits: [SearchHit] = []
        for id in ids {
            let record = records[id]
            let meta = metas[id]
            let match = semantic[id]
            var matched = 0
            var total: Float = 0
            var reasons: [String] = []
            for (k, p) in plans.enumerated() {
                var (s, reason) = score(p, id: id, record: record, meta: meta, threshold: threshold, calendar: calendar)
                if covered[k], let match, match.score > s,
                   termChecks[k].map({ $0[id] != nil }) ?? true
                    || options.termCheckBypassSimilarity.map({ match.similarity >= $0 }) ?? false {
                    s = match.score
                    reason = "画面语义相符 · 相似度 \(String(format: "%.2f", match.similarity))"
                }
                if s > 0 {
                    matched += 1
                    total += s
                    if let reason, !reasons.contains(reason) { reasons.append(reason) }
                }
            }
            if matched > 0 {
                hits.append(SearchHit(id: id, score: total / Float(plans.count), matchedTerms: matched, reasons: reasons,
                                      similarity: match?.similarity ?? 0))
            }
        }
        // 排序：命中的检索词数量 → 平均得分 → 画面语义相似度（语义分数封顶后靠它分高低）→ 时间新的在前（ids 已按时间倒序）
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        hits.sort {
            if $0.matchedTerms != $1.matchedTerms { return $0.matchedTerms > $1.matchedTerms }
            if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
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
                    // 写明是"置信度"：这是 Vision 对画面内容的把握，不是搜索相关度
                    consider(c * w, "\(dictionary.displayName(for: label)) · 置信度 \(Int((c * 100).rounded()))%")
                }
            }
            if let needle = p.ocrNeedle, ocrContains(record, needle, digitBoundary: p.date != nil) {
                let s = p.date != nil ? Self.ocrDateScore
                    : (needle.isCJK && needle.text.count == 1 ? Self.ocrSingleCharScore : Self.ocrScore)
                consider(s, "图中文字含「\(needle.text)」")
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
