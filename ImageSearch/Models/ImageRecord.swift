import Foundation

/// 图片来源：系统相册 / App 内导入
enum ImageSourceKind: Int, Sendable, Codable {
    case photoLibrary = 0
    case imported = 1
}

/// Vision 识别出的一个标签及置信度
struct LabelScore: Sendable, Hashable, Codable {
    let id: String          // Vision 标签，如 "beach"
    let confidence: Float   // 0...1
}

/// 额外的识别标记（位掩码，存进数据库）
struct RecordFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let hasQRCode      = RecordFlags(rawValue: 1 << 0)
    static let hasBarcode     = RecordFlags(rawValue: 1 << 1)
    static let analysisFailed = RecordFlags(rawValue: 1 << 2)
    /// 当前设备跑不了场景分类模型（iOS 模拟器的限制），只有文字等其它识别结果
    static let classifierUnavailable = RecordFlags(rawValue: 1 << 3)
    /// 以下三项表示这项识别"没跑成"，而不是"没检测到"：此时人脸数 0、没有二维码、没有文字都不可信
    static let faceDetectionFailed    = RecordFlags(rawValue: 1 << 4)
    static let barcodeDetectionFailed = RecordFlags(rawValue: 1 << 5)
    static let textRecognitionFailed  = RecordFlags(rawValue: 1 << 6)

    /// 有任何一项识别没跑成：这张图的索引不完整，「重新扫描」时会重试
    static let incompleteAnalysis: RecordFlags = [.classifierUnavailable, .textRecognitionFailed,
                                                  .faceDetectionFailed, .barcodeDetectionFailed]

    /// 可能没跑成的识别项及其中文名（按界面展示顺序）
    static let analysisItems: [(flag: RecordFlags, name: String)] = [
        (.classifierUnavailable, "画面识别"),
        (.textRecognitionFailed, "文字识别"),
        (.faceDetectionFailed, "人脸检测"),
        (.barcodeDetectionFailed, "二维码/条形码识别"),
    ]

    /// 其中没跑成的识别项的中文名
    var unavailableAnalysisNames: [String] {
        Self.analysisItems.filter { contains($0.flag) }.map(\.name)
    }
}

/// 一张图片的索引数据（全部在本机由 Vision 分析得到，持久化在 SQLite 中）
struct ImageRecord: Sendable, Identifiable, Hashable {
    let id: String                     // ImageID：p:<相册 localIdentifier> / i:<导入文件名>
    var source: ImageSourceKind
    var sourceModificationDate: Date?  // 用于判断照片是否被编辑过、需要重建索引
    var labels: [LabelScore]           // 按置信度降序
    var ocrText: String                // 图中文字（中英文）
    var faceCount: Int
    var flags: RecordFlags
    var pixelWidth: Int
    var pixelHeight: Int
    var analyzerVersion: Int
    var indexedAt: Date
    /// MobileCLIP 的图片向量（512 维单位向量）；没有模型或还没算时为 nil
    var clipEmbedding: [Float]?
    /// 生成上面向量的模型；换了模型就要重算
    var clipModel: String?

    // —— 以下为检索用的派生数据，加载时计算，不存库 ——
    private(set) var labelMap: [String: Float] = [:]
    private(set) var ocrCompact: String = ""   // 去空白、繁转简、小写（匹配中文）
    private(set) var ocrLower: String = ""     // 小写、繁转简（匹配英文单词）

    init(id: String, source: ImageSourceKind, sourceModificationDate: Date?, labels: [LabelScore],
         ocrText: String, faceCount: Int, flags: RecordFlags, pixelWidth: Int, pixelHeight: Int,
         analyzerVersion: Int, indexedAt: Date, clipEmbedding: [Float]? = nil, clipModel: String? = nil) {
        self.id = id
        self.source = source
        self.sourceModificationDate = sourceModificationDate
        self.labels = labels
        self.ocrText = ocrText
        self.faceCount = faceCount
        self.flags = flags
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.analyzerVersion = analyzerVersion
        self.indexedAt = indexedAt
        self.clipEmbedding = clipEmbedding
        self.clipModel = clipModel
        rebuildDerived()
    }

    /// 是否已经有指定模型算出的向量
    func hasEmbedding(from model: String) -> Bool { clipModel == model && clipEmbedding != nil }

    mutating func rebuildDerived() {
        var map: [String: Float] = [:]
        for l in labels { map[l.id] = max(map[l.id] ?? 0, l.confidence) }
        labelMap = map
        let normalized = TextNormalizer.normalize(ocrText)
        ocrLower = normalized
        ocrCompact = normalized.filter { !$0.isWhitespace }
    }

    func confidence(of label: String) -> Float { labelMap[label] ?? 0 }

    static func == (lhs: ImageRecord, rhs: ImageRecord) -> Bool {
        lhs.id == rhs.id && lhs.indexedAt == rhs.indexedAt
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(indexedAt) }
}

/// 不进索引、每次从 PhotoKit / 导入清单读取的元数据
struct ImageMeta: Sendable, Hashable {
    var creationDate: Date?
    var isFavorite = false
    var isScreenshot = false
    var isSelfie = false
    var isPanorama = false
    var isLivePhoto = false
    var isPortrait = false
    var fileName: String?      // 导入图片的原始文件名
}

/// 统一的图片 ID：相册照片用 "p:" 前缀，导入图片用 "i:" 前缀
enum ImageID {
    static func photo(_ localIdentifier: String) -> String { "p:" + localIdentifier }
    static func imported(_ fileName: String) -> String { "i:" + fileName }

    static func source(of id: String) -> ImageSourceKind {
        id.hasPrefix("i:") ? .imported : .photoLibrary
    }
    /// 去掉前缀后的原始标识（localIdentifier 或文件名）
    static func rawValue(of id: String) -> String { String(id.dropFirst(2)) }
}

/// 文本归一化：全角转半角、繁体转简体、小写
enum TextNormalizer {
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        t = t.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? t
        return t.lowercased()
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { isCJK($0) }
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
