import Foundation
import Testing
@testable import ImageSearch

@Suite("打分与排序")
struct SearchEngineTests {
    private typealias F = Fixture

    @Test("按标签置信度排序，低于 0.25 的标签不算命中")
    func labelConfidenceOrder() {
        let out = F.search("猫", [
            F.record("a", labels: ["cat": 0.4]),
            F.record("b", labels: ["cat": 0.9]),
            F.record("c", labels: ["dog": 0.95]),
            F.record("d", labels: ["cat": 0.2]),
        ])
        #expect(out.hits.map(\.id) == ["b", "a"])
        #expect(!out.isLowConfidence)
        #expect(out.hits.first?.reasons == ["猫 90%"])
    }

    @Test("没有高置信度结果时放宽阈值，并标为「可能相关」")
    func lowConfidenceFallback() {
        let out = F.search("猫", [F.record("d", labels: ["cat": 0.2]), F.record("e", labels: ["dog": 0.9])])
        #expect(out.hits.map(\.id) == ["d"])
        #expect(out.isLowConfidence)
    }

    @Test("同分时按时间，新的在前")
    func tieBreakByRecency() {
        let out = F.search("猫", [F.record("new", labels: ["cat": 0.8]), F.record("old", labels: ["cat": 0.8])])
        #expect(out.hits.map(\.id) == ["new", "old"])
    }

    @Test("dog / 狗 不会命中土拨鼠（prairie_dog）")
    func misleadingComponent() {
        let records = [F.record("prairieDog", labels: ["prairie_dog": 0.9]), F.record("dog", labels: ["dog": 0.8])]
        #expect(F.search("dog", records).hits.map(\.id) == ["dog"])
        #expect(F.search("狗", records).hits.map(\.id) == ["dog"])
    }

    @Test("发票：画面标签 > 图中文字 > 跨语言同义词（RECEIPT）")
    func receiptAcrossLanguages() {
        let out = F.search("发票", [
            F.record("english", ocr: "RECEIPT #48213\nTOTAL 13.65"),
            F.record("chinese", ocr: "电子发票（普通发票）"),
            F.record("label", labels: ["receipt": 0.9]),
            F.record("unrelated", ocr: "会议纪要"),
        ])
        #expect(out.hits.map(\.id) == ["label", "chinese", "english"])
        #expect(out.hits.map(\.score) == [0.9, SearchEngine.ocrScore, SearchEngine.ocrSynonymScore])
    }

    @Test("多个检索词：全部命中的排在最前")
    func allTermsMatchedFirst() {
        let out = F.search("海边 日落", [
            F.record("beach", labels: ["beach": 0.95]),
            F.record("both", labels: ["beach": 0.7, "sunset_sunrise": 0.7]),
            F.record("sunset", labels: ["sunset_sunrise": 0.95]),
        ])
        #expect(out.termCount == 2)
        #expect(out.fullMatchCount == 1)
        #expect(out.hits.first?.id == "both")
        #expect(Set(out.hits.map(\.id)) == ["beach", "both", "sunset"])
    }

    @Test("停用词不影响结果")
    func stopWordsDoNotChangeResults() {
        let records = [F.record("cat", labels: ["cat": 0.9]), F.record("dog", labels: ["dog": 0.9])]
        #expect(F.search("我的猫", records).hits.map(\.id) == F.search("猫", records).hits.map(\.id))
    }

    @Test("截图来自照片属性")
    func screenshotFromMetadata() {
        let out = F.search("截图", [F.record("shot"), F.record("photo")],
                           metas: ["shot": ImageMeta(isScreenshot: true)])
        #expect(out.hits.map(\.id) == ["shot"])
    }

    // 有意的设计：日期词也匹配图中文字（截图、票据上的日期），但排在拍摄日期命中的后面
    @Test("搜年份：拍摄日期命中在前，图中文字命中在后，单号里的数字不算")
    func yearPrefersCaptureDate() {
        let records = [
            F.record("textOnly", ocr: "账单日期 2024-10-03"),
            F.record("orderNumber", ocr: "订单号 20241231"),
            F.record("taken2024"),
            F.record("taken2023"),
        ]
        let metas: [String: ImageMeta] = [
            "textOnly": ImageMeta(creationDate: F.date(2023, 5, 1)),
            "orderNumber": ImageMeta(creationDate: F.date(2023, 5, 1)),
            "taken2024": ImageMeta(creationDate: F.date(2024, 6, 1)),
            "taken2023": ImageMeta(creationDate: F.date(2023, 1, 1)),
        ]
        let out = F.search("2024", records, metas: metas)
        #expect(out.hits.map(\.id) == ["taken2024", "textOnly"])
        #expect(out.hits.map(\.score) == [1.0, SearchEngine.ocrDateScore])
    }

    @Test("文件名里的日期仍按子串匹配（IMG_20240603 属于 2024）")
    func yearInFileName() {
        let out = F.search("2024", [F.record("file")],
                           metas: ["file": ImageMeta(creationDate: F.date(2023, 1, 1), fileName: "IMG_20240603.jpg")])
        #expect(out.hits.map(\.id) == ["file"])
        #expect(out.hits.first?.score == SearchEngine.fileNameScore)
    }
}

@Suite("识别没跑成时的提示")
struct IncompleteAnalysisTests {
    private typealias F = Fixture

    @Test("合影：三张以上人脸才算；人脸检测没跑成的图片会被报告")
    func groupPhotoWithFailedFaceDetection() {
        let out = F.search("合影", [
            F.record("group", faces: 4),
            F.record("single", faces: 1),
            F.record("failed", flags: .faceDetectionFailed),
        ])
        #expect(out.hits.map(\.id) == ["group"])
        #expect(out.incomplete == [IncompleteAnalysis(name: "人脸检测", count: 1)])
    }

    @Test("二维码：识别没跑成的图片会被报告")
    func qrCodeWithFailedDetection() {
        let out = F.search("二维码", [
            F.record("qr", flags: .hasQRCode),
            F.record("failed", flags: .barcodeDetectionFailed),
            F.record("plain"),
        ])
        #expect(out.hits.map(\.id) == ["qr"])
        #expect(out.incomplete == [IncompleteAnalysis(name: "二维码/条形码识别", count: 1)])
    }

    @Test("只报告这次检索用得到的识别")
    func onlyRelevantAnalysesReported() {
        let simulatorRecord = F.record("sim", flags: [.classifierUnavailable, .faceDetectionFailed])
        #expect(F.search("猫", [simulatorRecord]).incomplete == [IncompleteAnalysis(name: "画面识别", count: 1)])
        #expect(F.search("截图", [simulatorRecord], metas: ["sim": ImageMeta(isScreenshot: true)]).hits.map(\.id) == ["sim"])
    }

    @Test("识别都跑成时不报告")
    func noNoticeWhenEverythingRan() {
        #expect(F.search("合影", [F.record("a", faces: 0), F.record("b", faces: 5)]).incomplete.isEmpty)
    }
}
