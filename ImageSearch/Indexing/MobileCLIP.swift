import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

/// 图片 → 向量（建索引时用）
protocol ImageEmbedder: Sendable {
    /// 生成向量的模型；换了模型，旧向量就要重算
    var modelID: String { get }
    func embed(image: CGImage) -> [Float]?
}

/// 英文描述 → 向量（检索时用）
protocol TextEmbedder: Sendable {
    var modelID: String { get }
    func embed(text: String) -> [Float]?
}

/// Apple 的 MobileCLIP-S2（Core ML 格式）：把图片和英文描述编码到同一个 512 维空间，
/// 用余弦相似度衡量"画面像不像这段描述"。完全在本机运行，不联网。
///
/// 模型文件不在 App 里时（例如从 GitHub 克隆、没有放模型），`load()` 返回 nil，App 退回原来的检索方式。
/// 模型许可：Apple Machine Learning Research Model License，仅限非商业研究用途（见 ThirdPartyNotices.md）。
final class MobileCLIP: ImageEmbedder, TextEmbedder, @unchecked Sendable {
    static let modelName = "mobileclip_s2"
    let modelID = MobileCLIP.modelName

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let imageInput: String
    private let imageConstraint: MLImageConstraint
    private let imageOutput: String
    private let textInput: String
    private let textShape: [NSNumber]
    private let textOutput: String
    /// 图片预测并发数（默认 1，和原来一次只跑一张相同）。Core ML 的同一个 MLModel 支持多线程预测，
    /// 但并发到几张更快、会不会抢神经引擎，要在真机上量；设置里可以改，重开 App 生效
    private let imageGate: DispatchSemaphore
    /// 文本编码一次只跑一张（查询很少，且要保护 textCache）
    private let textGate = DispatchSemaphore(value: 1)
    private var textCache: [String: [Float]] = [:]
    /// 每次图片编码的（等门时间, 预测时间），单位秒。由 App 侧设置，用来区分「在排队」和「在算」
    static var timingObserver: (@Sendable (TimeInterval, TimeInterval) -> Void)?

    static let imageConcurrencyKey = "clipImageConcurrency"

    /// 设置里的并发数（1～4）；没设置过是 1
    static var defaultImageConcurrency: Int {
        let v = UserDefaults.standard.integer(forKey: imageConcurrencyKey)
        return v <= 0 ? 1 : max(1, min(4, v))
    }

    /// 从 App 包加载（Xcode 会把 .mlpackage 编译成 .mlmodelc 放进包里）
    static func load(bundle: Bundle = .main) -> MobileCLIP? {
        guard let image = bundle.url(forResource: "\(modelName)_image", withExtension: "mlmodelc"),
              let text = bundle.url(forResource: "\(modelName)_text", withExtension: "mlmodelc"),
              let tokenizer = CLIPTokenizer(bundle: bundle) else { return nil }
        return MobileCLIP(imageModelURL: image, textModelURL: text, tokenizer: tokenizer)
    }

    init?(imageModelURL: URL, textModelURL: URL, tokenizer: CLIPTokenizer,
          computeUnits: MLComputeUnits = MobileCLIP.defaultComputeUnits,
          imageConcurrency: Int = MobileCLIP.defaultImageConcurrency) {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        guard let image = try? MLModel(contentsOf: imageModelURL, configuration: config),
              let text = try? MLModel(contentsOf: textModelURL, configuration: config),
              let imageIn = image.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = imageIn.value.imageConstraint,
              let textIn = text.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let imageOut = image.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let textOut = text.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })
        else { return nil }
        imageModel = image
        textModel = text
        self.tokenizer = tokenizer
        imageInput = imageIn.key
        imageConstraint = constraint
        imageOutput = imageOut.key
        textInput = textIn.key
        textShape = textIn.value.multiArrayConstraint?.shape ?? [1, NSNumber(value: CLIPTokenizer.contextLength)]
        textOutput = textOut.key
        imageGate = DispatchSemaphore(value: max(1, imageConcurrency))
    }

    /// iOS 模拟器跑不了神经网络引擎，只用 CPU；真机和 Mac 交给系统挑（优先神经网络引擎）
    static var defaultComputeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .all
        #endif
    }

    func embed(image: CGImage) -> [Float]? {
        // 和官方示例一样：中心裁成正方形，再缩放到模型的输入尺寸（S2 是 256×256）
        let options: [MLFeatureValue.ImageOption: Any] = [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        guard let value = try? MLFeatureValue(cgImage: image, constraint: imageConstraint, options: options),
              let input = try? MLDictionaryFeatureProvider(dictionary: [imageInput: value]) else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        imageGate.wait()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        defer { imageGate.signal() }
        let predictStart = DispatchTime.now().uptimeNanoseconds
        let out = try? imageModel.prediction(from: input).featureValue(for: imageOutput)?.multiArrayValue
        let predicted = Double(DispatchTime.now().uptimeNanoseconds - predictStart) / 1e9
        Self.timingObserver?(waited, predicted)
        guard let out else { return nil }
        return Self.normalized(Self.floats(out))
    }

    func embed(text: String) -> [Float]? {
        textGate.wait()
        defer { textGate.signal() }
        if let hit = textCache[text] { return hit }
        guard let array = try? MLMultiArray(shape: textShape, dataType: .int32) else { return nil }
        let ids = tokenizer.inputIDs(for: text)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for i in 0..<min(buffer.count, ids.count) { buffer[i] = ids[i] }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [textInput: MLFeatureValue(multiArray: array)]),
              let out = try? textModel.prediction(from: input).featureValue(for: textOutput)?.multiArrayValue else {
            return nil
        }
        let vector = Self.normalized(Self.floats(out))
        if textCache.count >= 256 { textCache.removeAll() }
        textCache[text] = vector
        return vector
    }

    // MARK: - 向量工具

    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        switch a.dataType {
        case .float32:
            return a.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(n)) }
        case .double:
            return a.withUnsafeBufferPointer(ofType: Double.self) { $0.prefix(n).map { Float($0) } }
        default:
            return (0..<n).map { a[$0].floatValue }
        }
    }

    /// 缩放成单位向量（之后两个向量的点积就是余弦相似度）
    static func normalized(_ v: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(v, 1, &sumOfSquares, vDSP_Length(v.count))
        let norm = sumOfSquares.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// 两个单位向量的余弦相似度
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(min(a.count, b.count)))
        return result
    }
}
