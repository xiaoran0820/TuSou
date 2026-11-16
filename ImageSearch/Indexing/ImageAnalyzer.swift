import Foundation
import CoreGraphics
import CoreML
import ImageIO
import Vision

/// 一张图片的本机分析结果
struct AnalysisResult: Sendable {
    var labels: [LabelScore]
    var ocrText: String
    var faceCount: Int
    var flags: RecordFlags
}

/// 用 Apple Vision 在本机分析图片：场景/物体分类、中英文 OCR、人脸、二维码。
/// 图片数据不会离开设备。
enum ImageAnalyzer {
    /// 分析逻辑变化时调高版本号，旧索引会自动重建
    static let version = 2
    /// 分析用图的最长边（像素）：兼顾 OCR 清晰度和速度
    static let analysisMaxPixel: CGFloat = 1280
    /// 最长边不到这么多像素的图不做文字识别：Mac 上把图缩到 120 像素，开发集一个字都认不出，COCO 只剩 3%；
    /// 手机上这样的小图每张还要花约 80 毫秒。新手机上照片还在 iCloud 时，系统常常只给这么小的预览图
    static let minTextPixel = 200
    /// 低于此置信度的标签不入库
    static let storedLabelThreshold: Float = 0.08
    static let maxStoredLabels = 40
    /// 实验开关（设置里可开）：先用快速模式探一下有没有字，没有就不跑精确识别。
    /// 默认关，开了以后要确认「快速模式漏掉、精确模式能认出」的比例够低
    static let textFastGateKey = "textFastGate"
    static var textFastGateEnabled: Bool { UserDefaults.standard.bool(forKey: textFastGateKey) }

    /// 每做完一个 Vision 请求回调一次（哪个请求、用了多少秒）：建索引时用来统计各步骤的耗时
    typealias RequestTiming = (VNRequest, TimeInterval) -> Void

    /// includeText 为 false 时不做文字识别，记录上标「文字待识别」，留给建索引的第二步
    static func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, includeText: Bool = true,
                        timing: RequestTiming? = nil) -> AnalysisResult {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        return analyze(includeText: includeText) { try run($0, with: handler, timing: timing) }
    }

    /// 每一项识别独立执行：某一项在当前设备上跑不了（如模拟器无法运行神经网络模型），其它项照常保留，
    /// 跑不了的那一项留下对应标记，界面据此区分"没检测到"和"没跑成"。
    /// `perform` 负责执行单个请求，测试时可以注入失败。
    static func analyze(includeText: Bool = true, perform: (VNRequest) throws -> Void) -> AnalysisResult {
        var flags: RecordFlags = []

        // 1. 场景/物体分类（1303 类）
        var labels: [LabelScore] = []
        let classify = VNClassifyImageRequest()
        do {
            try perform(classify)
            labels = (classify.results ?? [])
                .filter { $0.confidence >= storedLabelThreshold }
                .sorted { $0.confidence > $1.confidence }
                .prefix(maxStoredLabels)
                .map { LabelScore(id: $0.identifier, confidence: $0.confidence) }
        } catch {
            // iOS 模拟器（Apple 芯片 Mac）无法创建 Vision 神经网络推理环境；真机上由神经网络引擎运行
            flags.insert(.classifierUnavailable)
        }

        // 2. 文字识别：四项里最花时间的一项（Mac 上约占三分之二），建索引时可以留到第二步再做
        var ocrText = ""
        if includeText {
            let text = recognizeText(perform: perform)
            ocrText = text.text
            if text.failed { flags.insert(.textRecognitionFailed) }
        } else {
            flags.insert(.textRecognitionPending)
        }

        // 3. 人脸数量
        var faceCount = 0
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try perform(faces)
            faceCount = faces.results?.count ?? 0
        } catch {
            flags.insert(.faceDetectionFailed)
        }

        // 4. 二维码 / 条形码
        let codes = VNDetectBarcodesRequest()
        do {
            try perform(codes)
            for obs in codes.results ?? [] {
                if obs.symbology == .qr || obs.symbology == .microQR || obs.symbology == .aztec {
                    flags.insert(.hasQRCode)
                } else {
                    flags.insert(.hasBarcode)
                }
            }
        } catch {
            flags.insert(.barcodeDetectionFailed)
        }

        return AnalysisResult(labels: labels, ocrText: ocrText, faceCount: faceCount, flags: flags)
    }

    /// 只做文字识别（建索引的第二步）。failed 为 true 表示没跑成，而不是图里没有字
    static func recognizeText(_ image: CGImage, orientation: CGImagePropertyOrientation = .up,
                              timing: RequestTiming? = nil) -> (text: String, failed: Bool) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        return recognizeText { try run($0, with: handler, timing: timing) }
    }

    /// 文字识别（简体/繁体中文 + 英文）
    static func recognizeText(perform: (VNRequest) throws -> Void) -> (text: String, failed: Bool) {
        // 实验：先用 .fast 探路。没有字时（相册里的大多数照片）就不必再跑慢的 .accurate
        if textFastGateEnabled, !hasTextFast(perform: perform) { return ("", false) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012
        do {
            try perform(request)
        } catch {
            return ("", true)
        }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.3 }
            .map(\.string)
            .joined(separator: "\n")
        return (text, false)
    }

    /// 快速模式先看一眼：任何一处文字置信度不低于 0.4 就认为可能有字，再跑精确识别。
    /// 快速模式跑不动（这台设备不支持）时按「有字」处理，退回精确识别
    private static func hasTextFast(perform: (VNRequest) throws -> Void) -> Bool {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .fast
        probe.recognitionLanguages = ["zh-Hans", "en-US"]
        probe.usesLanguageCorrection = false
        probe.minimumTextHeight = 0.012
        do { try perform(probe) } catch { return true }
        return (probe.results ?? []).contains { observation in
            guard let candidate = observation.topCandidates(1).first else { return false }
            return candidate.confidence >= 0.4
                && !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func run(_ request: VNRequest, with handler: VNImageRequestHandler, timing: RequestTiming?) throws {
        inFlight.insert(request)
        defer { inFlight.remove(request) }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { timing?(request, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
        try handler.perform([request])
    }

    /// 正在执行的 Vision 请求。同时做太多文字识别时，Vision 内部会互相等待、永远不返回（模拟器里同时 4 个时遇到过），
    /// 建索引长时间没有进展时，取消它们，让卡住的识别以失败返回
    private static let inFlight = InFlightRequests()

    /// 取消所有正在执行的 Vision 请求，返回取消了几个
    @discardableResult
    static func cancelInFlightRequests() -> Int { inFlight.cancelAll() }

    /// 一组正在执行的 Vision 请求（多个线程同时用，加锁）
    private final class InFlightRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ObjectIdentifier: VNRequest] = [:]

        func insert(_ r: VNRequest) { lock.lock(); requests[ObjectIdentifier(r)] = r; lock.unlock() }
        func remove(_ r: VNRequest) { lock.lock(); requests[ObjectIdentifier(r)] = nil; lock.unlock() }

        func cancelAll() -> Int {
            lock.lock()
            let all = Array(requests.values)
            lock.unlock()
            all.forEach { $0.cancel() }
            return all.count
        }
    }

    /// 从文件生成用于分析/展示的缩略图（自动按 EXIF 方向转正）
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// 读取图片文件的像素尺寸与拍摄时间（EXIF）
    static func fileInfo(at url: URL) -> (width: Int, height: Int, date: Date?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0, nil)
        }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) { swap(&w, &h) }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = f.date(from: s)
        }
        return (w, h, date)
    }
}
