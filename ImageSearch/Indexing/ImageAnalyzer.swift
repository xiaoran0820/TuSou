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
    /// 低于此置信度的标签不入库
    static let storedLabelThreshold: Float = 0.08
    static let maxStoredLabels = 40

    static func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) -> AnalysisResult {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        return analyze { try handler.perform([$0]) }
    }

    /// 每一项识别独立执行：某一项在当前设备上跑不了（如模拟器无法运行神经网络模型），其它项照常保留，
    /// 跑不了的那一项留下对应标记，界面据此区分"没检测到"和"没跑成"。
    /// `perform` 负责执行单个请求，测试时可以注入失败。
    static func analyze(perform: (VNRequest) throws -> Void) -> AnalysisResult {
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

        // 2. 文字识别（简体/繁体中文 + 英文）
        var ocrText = ""
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        text.usesLanguageCorrection = true
        text.minimumTextHeight = 0.012
        do {
            try perform(text)
            ocrText = (text.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.3 }
                .map(\.string)
                .joined(separator: "\n")
        } catch {
            flags.insert(.textRecognitionFailed)
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
