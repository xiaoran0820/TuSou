import Foundation
import Observation

/// 搜索页状态：在后台线程执行检索（纯本机，不联网）
@Observable @MainActor
final class SearchModel {
    var query = ""
    private(set) var outcome: SearchOutcome = .empty()
    private(set) var isSearching = false

    @ObservationIgnored private let engine: IndexingEngine
    @ObservationIgnored private let searchEngine = SearchEngine()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRevisionRun = -1

    init(engine: IndexingEngine) {
        self.engine = engine
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func hit(for id: String) -> SearchHit? { outcome.hits.first { $0.id == id } }

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
        let ids = engine.orderedIDs
        let records = engine.records
        let metas = engine.metas
        let se = searchEngine
        lastRevisionRun = engine.revision
        let result = await Task.detached(priority: .userInitiated) {
            se.search(query: q, ids: ids, records: records, metas: metas)
        }.value
        guard gen == generation else { return }   // 用户已经输入了新内容
        outcome = result
        isSearching = false
    }

    /// 索引有新内容时刷新当前结果（节流：建索引期间最多每 1.5 秒一次）
    func refreshForIndexChange() async {
        guard !trimmedQuery.isEmpty, engine.revision != lastRevisionRun else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        guard engine.revision != lastRevisionRun else { return }
        await run()
    }
}
