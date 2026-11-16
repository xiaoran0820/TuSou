import Foundation
import Vision

/// 建索引时每张图要做的几步
enum IndexStep: Int, CaseIterable, Sendable {
    case load, classify, faces, codes, embeddingWait, embedding, text

    var name: String {
        switch self {
        case .load: "读图"
        case .classify: "画面分类"
        case .faces: "人脸"
        case .codes: "二维码条码"
        case .embeddingWait: "MobileCLIP 等锁"
        case .embedding: "MobileCLIP"
        case .text: "文字识别"
        }
    }

    /// Vision 请求对应哪一步
    init(request: VNRequest) {
        switch request {
        case is VNClassifyImageRequest: self = .classify
        case is VNRecognizeTextRequest: self = .text
        case is VNDetectFaceRectanglesRequest: self = .faces
        default: self = .codes
        }
    }
}

/// 建索引分几轮做
enum IndexPass: Sendable, Equatable {
    /// 第一步：画面分类、人脸、二维码条码、MobileCLIP，不做文字识别。做完整个相册就能按画面搜
    case content
    /// 第二步：只做文字识别
    case text
    /// 原来的方式：一张图的全部识别一次做完
    case single

    var title: String {
        switch self {
        case .content: "第 1 步：识别画面"
        case .text: "第 2 步：识别图中文字"
        case .single: "一步做完（原来的方式）"
        }
    }
}

/// 某一步平均每张图的耗时
struct StepTime: Sendable, Equatable {
    let step: IndexStep
    let milliseconds: Double
}

/// 一轮建索引的耗时统计。只留在内存里，给设置页看：用来在手机上量出各步骤实际花了多少时间
struct IndexPassStats: Sendable, Equatable {
    let pass: IndexPass
    let images: Int
    let seconds: Double
    /// false：这一轮中途停下了（相册有变化、开始重建、或者 App 被关掉）
    let finished: Bool
    /// 同时处理的图片数
    let concurrency: Int
    /// 这一轮做过的各步骤，单张图平均耗时
    let steps: [StepTime]
    /// 实际拿到的图（交给 Vision 之前）最长边的中位数和最大值，单位像素
    let medianLongSide: Int?
    let maxLongSide: Int?

    /// 「4,861 张 · 3 分 05 秒」
    var summary: String {
        let total = Int(seconds.rounded())
        let time = total >= 60 ? "\(total / 60) 分 \(String(format: "%02d", total % 60)) 秒" : "\(total) 秒"
        return "\(images.formatted()) 张 · \(time)" + (finished ? "" : "（中途停下）")
    }

    /// 平均每张、各步骤和图的尺寸
    var details: String {
        var lines: [String] = []
        if images > 0 {
            lines.append("平均每张 \(Int((seconds / Double(images) * 1000).rounded())) 毫秒（同时处理 \(concurrency) 张）")
        }
        if !steps.isEmpty {
            lines.append("单张各步骤：" + steps.map { "\($0.step.name) \(Int($0.milliseconds.rounded()))" }.joined(separator: " · ") + " 毫秒")
        }
        if let median = medianLongSide, let largest = maxLongSide {
            lines.append("拿到的图最长边：中位数 \(median) 像素，最大 \(largest) 像素")
        }
        return lines.joined(separator: "\n")
    }
}

/// 收集建索引各步骤的耗时。分析在后台几个线程上同时进行，所以加锁
final class IndexTimer: @unchecked Sendable {
    static let shared = IndexTimer()

    private let lock = NSLock()
    private var totals: [IndexStep: Double] = [:]
    private var counts: [IndexStep: Int] = [:]
    private var longSides: [Int] = []

    func reset() {
        lock.lock()
        totals = [:]
        counts = [:]
        longSides = []
        lock.unlock()
    }

    func add(_ step: IndexStep, seconds: Double) {
        lock.lock()
        totals[step, default: 0] += seconds
        counts[step, default: 0] += 1
        lock.unlock()
    }

    /// 记下拿到的图的尺寸
    func addImage(width: Int, height: Int) {
        lock.lock()
        longSides.append(max(width, height))
        lock.unlock()
    }

    /// 计时一个同步的步骤
    func measure<T>(_ step: IndexStep, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(step, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
        return try body()
    }

    func stats(pass: IndexPass, images: Int, seconds: Double, finished: Bool, concurrency: Int) -> IndexPassStats {
        lock.lock()
        defer { lock.unlock() }
        let steps = IndexStep.allCases.compactMap { step -> StepTime? in
            guard let n = counts[step], n > 0 else { return nil }
            return StepTime(step: step, milliseconds: (totals[step] ?? 0) / Double(n) * 1000)
        }
        let sides = longSides.sorted()
        return IndexPassStats(pass: pass, images: images, seconds: seconds, finished: finished, concurrency: concurrency,
                              steps: steps, medianLongSide: sides.isEmpty ? nil : sides[sides.count / 2],
                              maxLongSide: sides.last)
    }
}
