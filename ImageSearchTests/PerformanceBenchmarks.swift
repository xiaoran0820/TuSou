import Foundation
import Testing
@testable import ImageSearch

/// 可复现的伪随机数（SplitMix64）：每次生成同样的合成数据
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 性能基准。默认不运行；运行时在 xcodebuild 前加环境变量 TEST_RUNNER_RUN_BENCHMARKS=1。
/// 结果以 "BENCH" 开头打印到测试日志。
@Suite("性能基准", .serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil))
struct PerformanceBenchmarks {
    /// 合成的图库：每张 10 个 Vision 标签；约三分之一带图中文字；拍摄时间分布在 2020–2026 年
    static func syntheticLibrary(_ n: Int) -> (ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta]) {
        var rng = SeededGenerator(seed: 42)
        let labels = LabelDictionary.shared.allLabels.sorted()
        let common = ["cat", "dog", "beach", "sunset_sunrise", "food", "receipt", "people", "sky", "outdoor", "plant"]
        let words = ["发票", "收据", "合计", "RECEIPT", "TOTAL", "停车场", "会议纪要", "订单号", "微信支付",
                     "生日快乐", "欢迎光临", "2024-10-03", "Restaurant", "营业时间", "Thank you", "¥119.20"]
        var ids: [String] = []
        var records: [String: ImageRecord] = [:]
        var metas: [String: ImageMeta] = [:]
        ids.reserveCapacity(n)
        for i in 0..<n {
            let id = "p:bench-\(i)"
            var scores: [String: Float] = [:]
            for _ in 0..<7 { scores[labels.randomElement(using: &rng)!] = Float.random(in: 0.08...0.6, using: &rng) }
            for _ in 0..<3 { scores[common.randomElement(using: &rng)!] = Float.random(in: 0.2...0.97, using: &rng) }
            var ocr = ""
            if Int.random(in: 0..<3, using: &rng) == 0 {
                ocr = (0..<Int.random(in: 3...8, using: &rng)).map { _ in words.randomElement(using: &rng)! }
                    .joined(separator: " ")
            }
            ids.append(id)
            records[id] = Fixture.record(id, labels: scores, ocr: ocr)
            metas[id] = ImageMeta(creationDate: Date(timeIntervalSince1970: Double.random(in: 1_577_836_800...1_793_000_000, using: &rng)))
        }
        return (ids, records, metas)
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    @Test("搜索延迟：1,000 / 10,000 / 50,000 张")
    func searchLatency() {
        let engine = SearchEngine()
        for n in [1_000, 10_000, 50_000] {
            let lib = Self.syntheticLibrary(n)
            for q in ["猫", "发票", "海边 日落", "2024", "合影", "完全不存在的词"] {
                var times: [Double] = []
                for run in 0..<7 {
                    let ms = Self.milliseconds {
                        _ = engine.search(query: q, ids: lib.ids, records: lib.records, metas: lib.metas)
                    }
                    if run > 0 { times.append(ms) }   // 第一次是预热
                }
                times.sort()
                print(String(format: "BENCH search n=%d q=%@ p50=%.1fms max=%.1fms",
                             n, q, times[times.count / 2], times.last!))
            }
        }
    }

    @Test("每写入一批后的索引统计：50,000 张")
    func statsLatency() {
        let lib = Self.syntheticLibrary(50_000)
        var times: [Double] = []
        for run in 0..<7 {
            let ms = Self.milliseconds { _ = IndexStats.compute(ids: lib.ids, records: lib.records) }
            if run > 0 { times.append(ms) }
        }
        times.sort()
        print(String(format: "BENCH stats n=50000 p50=%.1fms max=%.1fms", times[times.count / 2], times.last!))
    }
}
