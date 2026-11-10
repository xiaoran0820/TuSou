import Foundation
import Observation

/// 搜索页状态：在后台线程执行检索（纯本机，不联网）
@Observable @MainActor
final class SearchModel {
    /// 检索方式。平常只用融合；评测模式（第 0 轮）里可以切换成只用其中一种，方便对比
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case fusion, visionOnly, clipOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fusion: return "融合"
            case .visionOnly: return "只用 Vision"
            case .clipOnly: return "只用 MobileCLIP"
            }
        }
        /// 分段控件上的短名字（窄屏上「只用 MobileCLIP」放不下）
        var shortTitle: String { self == .clipOnly ? "只用 CLIP" : title }
        var explanation: String {
            switch self {
            case .fusion: return "App 平常的方式：画面标签、图中文字、词典和 MobileCLIP 一起判断。"
            case .visionOnly: return "只用 Apple Vision 的画面标签、图中文字识别和词典，不用 MobileCLIP。"
            case .clipOnly: return "只按 MobileCLIP 相似度给范围内全部图片排序，不设门槛。"
            }
        }
    }

    var query = ""
    private(set) var outcome: SearchOutcome = .empty()
    private(set) var isSearching = false

    /// 评测模式：搜索页出现「检索方式」和「范围」切换，结果按得分全部列出，缩略图显示导入时的文件名。
    /// 关掉时恢复成融合、全部图片，平常使用不受影响
    var evalMode = UserDefaults.standard.bool(forKey: Keys.evalMode) {
        didSet {
            UserDefaults.standard.set(evalMode, forKey: Keys.evalMode)
            if !evalMode { mode = .fusion; importedOnly = false }
            rerun()
        }
    }
    var mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .fusion {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode); if mode != oldValue { rerun() } }
    }
    /// 只在 App 内导入的图片里搜（第 0 轮的 40 张测试图）
    var importedOnly = UserDefaults.standard.bool(forKey: Keys.importedOnly) {
        didSet { UserDefaults.standard.set(importedOnly, forKey: Keys.importedOnly); if importedOnly != oldValue { rerun() } }
    }

    /// 评测模式下不收起「只符合部分条件」的结果，按得分顺序全部列出，「前 5 个」不会有歧义
    var showsAllHits: Bool { evalMode }
    /// 这次结果实际用的检索方式
    var effectiveMode: Mode { evalMode ? mode : .fusion }

    private enum Keys {
        static let evalMode = "evalMode", mode = "evalSearchMode", importedOnly = "evalImportedOnly"
    }

    @ObservationIgnored private let engine: IndexingEngine
    @ObservationIgnored private var textEmbedder: (any TextEmbedder)?
    @ObservationIgnored private var searchEngine = SearchEngine()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRevisionRun = -1

    init(engine: IndexingEngine) {
        self.engine = engine
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func hit(for id: String) -> SearchHit? { outcome.hits.first { $0.id == id } }

    /// MobileCLIP 加载完成后调用：之后的检索会加上画面语义比对
    func setTextEmbedder(_ embedder: (any TextEmbedder)?) {
        textEmbedder = embedder
        searchEngine = SearchEngine(textEmbedder: embedder)
        lastRevisionRun = -1
        if !trimmedQuery.isEmpty { Task { await run() } }
    }

    /// 执行检索（输入变化、索引更新时调用）
    func run() async {
        let q = trimmedQuery
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            outcome = .empty()
            return
        }
        isSearching = true
        var ids = engine.orderedIDs
        if evalMode && importedOnly { ids = ids.filter { ImageID.source(of: $0) == .imported } }
        let records = engine.records
        let metas = engine.metas
        let mode = effectiveMode
        // 只用 Vision = 评测程序的方案 C：画面标签 + 图中文字 + 词典扩展，不做画面语义比对
        let se = mode == .visionOnly
            ? SearchEngine(textEmbedder: textEmbedder, options: SearchOptions(labels: true, text: true, expansion: true, semantic: false))
            : searchEngine
        lastRevisionRun = engine.revision
        let result = await Task.detached(priority: .userInitiated) {
            mode == .clipOnly ? se.rankBySimilarity(query: q, ids: ids, records: records)
                              : se.search(query: q, ids: ids, records: records, metas: metas)
        }.value
        guard gen == generation else { return }   // 用户已经输入了新内容
        outcome = result
        isSearching = false
    }

    private func rerun() {
        lastRevisionRun = -1
        if !trimmedQuery.isEmpty { Task { await run() } }
    }

    /// 索引有新内容时刷新当前结果（节流：建索引期间最多每 1.5 秒一次）
    func refreshForIndexChange() async {
        guard !trimmedQuery.isEmpty, engine.revision != lastRevisionRun else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        guard engine.revision != lastRevisionRun else { return }
        await run()
    }
}
