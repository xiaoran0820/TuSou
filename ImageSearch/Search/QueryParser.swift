import Foundation
import NaturalLanguage

/// 元数据类条件：来自 PhotoKit 属性（截图、收藏…）或 Vision 附加检测（人脸、二维码…）
enum MetaPredicate: Sendable, Hashable {
    case screenshot, favorite, selfie, panorama, livePhoto, portrait
    case faces(atLeast: Int)
    case qrCode, barcode, hasText, imported

    /// 相册元数据或图片来源：只能按记录判断，MobileCLIP 的画面语义比对不能代替。
    /// 人脸、二维码、文字这类画面内容不算
    var isLibraryAttribute: Bool {
        switch self {
        case .screenshot, .favorite, .selfie, .panorama, .livePhoto, .portrait, .imported: return true
        case .faces, .qrCode, .barcode, .hasText: return false
        }
    }

    var title: String {
        switch self {
        case .screenshot: return "截图"
        case .favorite: return "个人收藏"
        case .selfie: return "自拍"
        case .panorama: return "全景"
        case .livePhoto: return "实况照片"
        case .portrait: return "人像模式"
        case .faces(let n): return n >= 3 ? "多人合影" : "有人脸"
        case .qrCode: return "二维码"
        case .barcode: return "条形码"
        case .hasText: return "含文字"
        case .imported: return "导入的图片"
        }
    }

    func matches(id: String, record: ImageRecord?, meta: ImageMeta?) -> Bool {
        switch self {
        case .screenshot: return meta?.isScreenshot == true
        case .favorite: return meta?.isFavorite == true
        case .selfie: return meta?.isSelfie == true
        case .panorama: return meta?.isPanorama == true
        case .livePhoto: return meta?.isLivePhoto == true
        case .portrait: return meta?.isPortrait == true
        case .faces(let n): return (record?.faceCount ?? 0) >= n
        case .qrCode: return record?.flags.contains(.hasQRCode) == true
        case .barcode: return record?.flags.contains(.hasBarcode) == true
        case .hasText: return (record?.ocrCompact.count ?? 0) >= 4
        case .imported: return ImageID.source(of: id) == .imported
        }
    }
}

/// 日期条件
enum DateFilter: Sendable, Hashable {
    case range(start: Date, end: Date)   // [start, end)
    case month(Int)                      // 任意年份的某个月

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        switch self {
        case .range(let s, let e): return date >= s && date < e
        case .month(let m): return calendar.component(.month, from: date) == m
        }
    }
}

struct QueryTerm: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case word
        case date(DateFilter)
    }
    let text: String
    let kind: Kind
}

/// 把用户输入拆成检索词：日期表达式、中文分词、英文短语
enum QueryParser {
    private static let countingPhrase = try! NSRegularExpression(
        pattern: "^[一二两三四五六七八九十几半多]+[只头匹个辆条张位对棵朵片块本支根把件双名座间台架艘颗粒杯碗盘份层群]?$")

    /// 「两头」「三个」「一群」这类「数字 + 量词」，以及单独的「两」「三」
    static func isCountingPhrase(_ s: String) -> Bool {
        countingPhrase.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static let stopWords: Set<String> = [
        "的", "了", "在", "和", "与", "跟", "及", "或", "是", "有", "着", "把", "被", "给", "很", "都", "也", "还",
        "一", "张", "个", "只", "条", "头", "匹", "位", "些", "点", "种", "一张", "一个", "一些", "那", "这", "那些", "这些",
        "我", "我的", "你", "他", "她", "它", "我们", "里", "里面", "中", "上", "下", "旁", "旁边",
        "照片", "图片", "图", "相片", "图像", "相册", "关于", "有关", "带", "带有", "包含", "含有", "所有", "全部",
        "找", "搜", "搜索", "查找", "看看", "显示", "拍", "拍的", "时候", "时",
        "小", "大", "老", "新", "旧", "好", "美", "美丽", "漂亮", "可爱", "好看", "超", "特别", "非常", "很多",
        "the", "a", "an", "of", "with", "in", "on", "at", "and", "or", "to", "for", "my", "me", "is", "are",
        "photo", "photos", "picture", "pictures", "image", "images", "pic", "pics", "show", "find",
    ]

    /// 元数据关键词 → 条件与权重
    static let metaKeywords: [String: (MetaPredicate, Float)] = {
        var m: [String: (MetaPredicate, Float)] = [:]
        func put(_ words: [String], _ p: MetaPredicate, _ w: Float = 1.0) { for x in words { m[x] = (p, w) } }
        put(["截图", "截屏", "屏幕截图", "屏幕快照", "screenshot", "screenshots"], .screenshot)
        put(["收藏", "喜欢", "最爱", "个人收藏", "favorite", "favorites", "favourite"], .favorite)
        put(["自拍", "selfie", "selfies"], .selfie)
        put(["全景", "全景图", "panorama"], .panorama)
        put(["实况", "实况照片", "动态照片", "livephoto"], .livePhoto)
        put(["人像模式", "景深"], .portrait)
        put(["人", "人脸", "脸", "面孔", "人像", "人物", "face", "faces"], .faces(atLeast: 1), 0.85)
        put(["合影", "合照", "集体照", "大合照", "group"], .faces(atLeast: 3), 0.95)
        put(["二维码", "qr", "qrcode", "二维"], .qrCode)
        put(["条形码", "条码", "barcode"], .barcode)
        put(["文字", "有文字", "文本", "text"], .hasText, 0.9)
        put(["导入", "已导入", "imported"], .imported)
        return m
    }()

    /// 认识的词会被单独切出来：词典词、照片属性词、以及能翻成英文给 MobileCLIP 的常用词（红色、夜晚、骑…）
    static func isKnown(_ term: String, _ dict: LabelDictionary) -> Bool {
        dict.knowsChinese(term) || metaKeywords[term] != nil || PromptLexicon.english[term] != nil
    }

    /// 分词时也认中英对照表里的词，但只认拆不成已知词的：「富士山」里的「富士」不认识，所以整体保留；
    /// 「骑自行车」能拆成「骑」+「自行车」，就照旧拆开，原有查询的理解不变
    static func isKnown(_ term: String, _ dict: LabelDictionary, glossary: Glossary) -> Bool {
        if isKnown(term, dict) { return true }
        guard term.count >= 2, glossary.english(for: term) != nil else { return false }
        return !splitsIntoKnownWords(term, dict)
    }

    /// term 能否整个切成已知词（词典词、照片属性词、常用词表里的词）
    private static func splitsIntoKnownWords(_ term: String, _ dict: LabelDictionary) -> Bool {
        let chars = Array(term)
        var reachable = [true] + Array(repeating: false, count: chars.count)
        for end in 1...chars.count {
            for start in 0..<end where reachable[start] && isKnown(String(chars[start..<end]), dict) {
                reachable[end] = true
                break
            }
        }
        return reachable[chars.count]
    }

    static func parse(_ raw: String, dictionary: LabelDictionary, glossary: Glossary = .shared, now: Date = Date(),
                      calendar: Calendar = .current) -> [QueryTerm] {
        var text = TextNormalizer.normalize(raw)
        var terms: [QueryTerm] = []
        terms += extractDates(from: &text, now: now, calendar: calendar)

        // 按标点/符号切成片段，片段内再按中文/非中文切分
        for run in scriptRuns(text) {
            if run.isCJK {
                for w in segmentChinese(run.text, dictionary, glossary: glossary) { terms.append(QueryTerm(text: w, kind: .word)) }
            } else {
                for w in segmentLatin(run.text, dictionary) { terms.append(QueryTerm(text: w, kind: .word)) }
            }
        }

        var seen = Set<QueryTerm>()
        return terms.filter { seen.insert($0).inserted }
    }

    // MARK: - 日期

    private static func extractDates(from text: inout String, now: Date, calendar: Calendar) -> [QueryTerm] {
        var out: [QueryTerm] = []
        func yearRange(_ y: Int) -> DateFilter? {
            guard let s = calendar.date(from: DateComponents(year: y, month: 1, day: 1)),
                  let e = calendar.date(byAdding: .year, value: 1, to: s) else { return nil }
            return .range(start: s, end: e)
        }
        func monthRange(_ y: Int, _ m: Int) -> DateFilter? {
            guard (1...12).contains(m), let s = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
                  let e = calendar.date(byAdding: .month, value: 1, to: s) else { return nil }
            return .range(start: s, end: e)
        }
        func interval(_ c: Calendar.Component, offset: Int) -> DateFilter? {
            guard let ref = calendar.date(byAdding: c, value: offset, to: now),
                  let i = calendar.dateInterval(of: c, for: ref) else { return nil }
            return .range(start: i.start, end: i.end)
        }

        // 顺序很重要：先匹配更长的表达式
        let patterns: [(String, ([String]) -> DateFilter?)] = [
            (#"(\d{4})\s*年\s*(\d{1,2})\s*月份?"#, { monthRange(Int($0[1])!, Int($0[2])!) }),
            (#"(\d{4})[-./](\d{1,2})(?!\d)"#, { monthRange(Int($0[1])!, Int($0[2])!) }),
            (#"(\d{4})\s*年"#, { yearRange(Int($0[1])!) }),
            (#"(?<!\d)(\d{1,2})\s*月份?"#, { m in Int(m[1]).flatMap { (1...12).contains($0) ? .month($0) : nil } }),
            (#"(?<![\d.])((?:19|20)\d{2})(?![\d.])"#, { yearRange(Int($0[1])!) }),
        ]
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            while let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                let groups = (0..<m.numberOfRanges).map { i -> String in
                    guard let r = Range(m.range(at: i), in: text) else { return "" }
                    return String(text[r])
                }
                if let f = make(groups) { out.append(QueryTerm(text: groups[0].trimmingCharacters(in: .whitespaces), kind: .date(f))) }
                text.replaceSubrange(Range(m.range, in: text)!, with: " ")
            }
        }

        let relative: [([String], DateFilter?)] = [
            (["今天", "今日", "today"], interval(.day, offset: 0)),
            (["昨天", "昨日", "yesterday"], interval(.day, offset: -1)),
            (["前天"], interval(.day, offset: -2)),
            (["本周", "这周", "这星期", "这个星期", "本星期", "this week"], interval(.weekOfYear, offset: 0)),
            (["上周", "上星期", "上个星期", "last week"], interval(.weekOfYear, offset: -1)),
            (["本月", "这个月", "this month"], interval(.month, offset: 0)),
            (["上个月", "上月", "last month"], interval(.month, offset: -1)),
            (["今年", "this year"], interval(.year, offset: 0)),
            (["去年", "last year"], interval(.year, offset: -1)),
            (["前年"], interval(.year, offset: -2)),
        ]
        for (words, filter) in relative {
            guard let filter else { continue }
            for w in words.sorted(by: { $0.count > $1.count }) where text.contains(w) {
                text = text.replacingOccurrences(of: w, with: " ")
                out.append(QueryTerm(text: w, kind: .date(filter)))
            }
        }
        return out
    }

    // MARK: - 切分

    struct Run { var isCJK: Bool; var text: String }

    /// 按文字体系切分：连续中文为一段，连续字母/数字/空格为一段，其它符号作分隔
    static func scriptRuns(_ s: String) -> [Run] {
        var runs: [Run] = []
        var current: Run?
        func flush() {
            if let c = current, !c.text.trimmingCharacters(in: .whitespaces).isEmpty { runs.append(c) }
            current = nil
        }
        for ch in s {
            let cjk = ch.unicodeScalars.allSatisfy { TextNormalizer.isCJK($0) }
            if cjk {
                if current?.isCJK != true { flush(); current = Run(isCJK: true, text: "") }
                current!.text.append(ch)
            } else if ch.isLetter || ch.isNumber || ch == " " || ch == "'" || ch == "-" {
                if current?.isCJK != false { flush(); current = Run(isCJK: false, text: "") }
                current!.text.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    /// 中文分词：整词命中词典 → 直接用；否则用 NLTokenizer 分词，再把相邻可组成词典词的片段合并
    static func segmentChinese(_ s: String, _ dict: LabelDictionary, glossary: Glossary = .shared) -> [String] {
        let isKnown: (String) -> Bool = { Self.isKnown($0, dict, glossary: glossary) }
        if isKnown(s) { return [s] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        tokenizer.setLanguage(.simplifiedChinese)
        let tokens = tokenizer.tokens(for: s.startIndex..<s.endIndex).map { String(s[$0]) }

        // 贪心合并：如 "生日"+"蛋糕" → "生日蛋糕"
        var merged: [String] = []
        var i = 0
        while i < tokens.count {
            var best = 1
            var j = min(tokens.count, i + 4)
            while j > i + 1 {
                if isKnown(tokens[i..<j].joined()) { best = j - i; break }
                j -= 1
            }
            merged.append(tokens[i..<(i + best)].joined())
            i += best
        }

        // 认识的词单独成词；停用词作分隔；相邻的未知片段拼回一个词（如 萨摩+耶 → 萨摩耶）
        var out: [String] = []
        var unknown = ""
        func flushUnknown() {
            guard !unknown.isEmpty else { return }
            out += unknown.count >= 3 ? forwardMaxMatch(unknown, dict, glossary: glossary) : [unknown]
            unknown = ""
        }
        for t in merged {
            if isKnown(t) {
                flushUnknown()
                out.append(t)
            } else if stopWords.contains(t) {
                flushUnknown()
            } else {
                unknown += t
            }
        }
        flushUnknown()
        // 「两头」「三个」「一群」这类数量短语不当检索条件：它们没有英文、只能去图中文字里找，整句就没有图能完全匹配
        return out.filter { !$0.isEmpty && !stopWords.contains($0) && (isKnown($0) || !isCountingPhrase($0)) }
    }

    /// 正向最大匹配，用于把较长的未知词拆出词典里认识的部分（剩余部分保留为未知词）
    private static func forwardMaxMatch(_ s: String, _ dict: LabelDictionary, glossary: Glossary) -> [String] {
        let chars = Array(s)
        var out: [String] = []
        var unknown = ""
        var i = 0
        var knownChars = 0
        while i < chars.count {
            var matched: String?
            var len = min(max(dict.maxChineseKeyLength, min(glossary.maxKeyLength, 8)), chars.count - i)
            while len >= 2 {
                let cand = String(chars[i..<(i + len)])
                if isKnown(cand, dict, glossary: glossary) { matched = cand; break }
                len -= 1
            }
            if let m = matched {
                if !unknown.isEmpty { out.append(unknown); unknown = "" }
                out.append(m); knownChars += m.count; i += m.count
            } else {
                unknown.append(chars[i]); i += 1
            }
        }
        if !unknown.isEmpty { out.append(unknown) }
        // 认识的部分太少就保持原词，交给语义扩展 / 联网翻译
        return knownChars * 2 >= chars.count ? out : [s]
    }

    /// 英文：按空格切词，合并成词典里的多词短语（如 birthday cake → birthday_cake）
    static func segmentLatin(_ s: String, _ dict: LabelDictionary) -> [String] {
        let words = s.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var taken = 1
            var j = min(words.count, i + 3)
            while j > i + 1 {
                let phrase = words[i..<j].joined(separator: " ")
                if dict.knowsEnglish(phrase) { taken = j - i; break }
                j -= 1
            }
            let w = words[i..<(i + taken)].joined(separator: " ")
            if !stopWords.contains(w) {
                // 纯数字只在 ≥2 位时保留（可匹配图中文字，如金额、单号）
                if w.allSatisfy(\.isNumber) { if w.count >= 2 { out.append(w) } } else { out.append(w) }
            }
            i += taken
        }
        return out
    }
}
