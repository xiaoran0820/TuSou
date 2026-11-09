import Foundation
import NaturalLanguage

/// 用系统自带的词向量（NLEmbedding，完全离线）为词典外的词找近义词。
/// 例：「喵星人」→ 猫咪；「小狗」→ 狗狗；英文 puppy → dog。
final class SemanticExpander: @unchecked Sendable {
    static let shared = SemanticExpander()

    private let lock = NSLock()
    private var zhLoaded = false, enLoaded = false
    private var zhEmbedding: NLEmbedding?
    private var enEmbedding: NLEmbedding?

    /// 距离越近权重越高；超过 maxDistance 的邻居忽略
    static let maxDistance = 0.95
    static func weight(forDistance d: Double) -> Float {
        Float(min(0.6, max(0, 1.15 - 0.75 * d)))
    }

    /// 预加载词向量（首次加载约几十毫秒，放到后台做）
    func warmUp() {
        lock.lock(); defer { lock.unlock() }
        loadZH(); loadEN()
    }

    func chineseNeighbors(of word: String, where accept: (String) -> Bool, limit: Int = 30) -> [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        loadZH()
        guard let e = zhEmbedding, e.contains(word) else { return [] }
        return e.neighbors(for: word, maximumCount: limit)
            .filter { $0.1 <= Self.maxDistance && accept($0.0) }
    }

    func englishNeighbors(of word: String, where accept: (String) -> Bool, limit: Int = 40) -> [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        loadEN()
        guard let e = enEmbedding, e.contains(word) else { return [] }
        return e.neighbors(for: word, maximumCount: limit)
            .filter { $0.1 <= Self.maxDistance && accept($0.0) }
    }

    var isChineseAvailable: Bool { lock.lock(); defer { lock.unlock() }; loadZH(); return zhEmbedding != nil }

    private func loadZH() {
        guard !zhLoaded else { return }
        zhLoaded = true
        zhEmbedding = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
    }

    private func loadEN() {
        guard !enLoaded else { return }
        enLoaded = true
        enEmbedding = NLEmbedding.wordEmbedding(for: .english)
    }
}
