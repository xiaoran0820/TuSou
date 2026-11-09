import Testing
import Vision
@testable import ImageSearch

@Suite("识别失败的标记")
struct AnalysisFlagsTests {
    private struct InjectedFailure: Error {}

    /// 让满足条件的识别请求抛错，其它请求什么都不做（相当于"跑成了，但没检测到东西"）
    private func analyze(failing shouldFail: (VNRequest) -> Bool) -> AnalysisResult {
        ImageAnalyzer.analyze { request in
            if shouldFail(request) { throw InjectedFailure() }
        }
    }

    @Test("每一项识别失败都留下自己的标记，互不影响")
    func eachFailureHasItsOwnFlag() {
        #expect(analyze(failing: { $0 is VNClassifyImageRequest }).flags == .classifierUnavailable)
        #expect(analyze(failing: { $0 is VNRecognizeTextRequest }).flags == .textRecognitionFailed)
        #expect(analyze(failing: { $0 is VNDetectFaceRectanglesRequest }).flags == .faceDetectionFailed)
        #expect(analyze(failing: { $0 is VNDetectBarcodesRequest }).flags == .barcodeDetectionFailed)
    }

    @Test("人脸检测没跑成：人脸数是 0，但能和「没有人脸」区分开")
    func failedFaceDetectionIsDistinguishable() {
        let failed = analyze(failing: { $0 is VNDetectFaceRectanglesRequest })
        let ranButFoundNothing = analyze(failing: { _ in false })
        #expect(failed.faceCount == 0 && ranButFoundNothing.faceCount == 0)
        #expect(failed.flags.contains(.faceDetectionFailed))
        #expect(!ranButFoundNothing.flags.contains(.faceDetectionFailed))
    }

    @Test("都跑成时没有失败标记")
    func noFlagsWhenEverythingRuns() {
        #expect(analyze(failing: { _ in false }).flags.isEmpty)
    }

    @Test("有识别没跑成的记录，会在「重新扫描」时重试")
    func partialRecordsAreRetried() {
        #expect(IndexingEngine.isPartial(Fixture.record("face", flags: .faceDetectionFailed)))
        #expect(IndexingEngine.isPartial(Fixture.record("text", flags: .textRecognitionFailed)))
        #expect(IndexingEngine.isPartial(Fixture.record("failed", flags: .analysisFailed)))
        #expect(!IndexingEngine.isPartial(Fixture.record("ok", flags: .hasQRCode)))
    }

    @Test("界面上列出的识别项名称和顺序")
    func analysisNames() {
        let flags: RecordFlags = [.faceDetectionFailed, .hasQRCode, .classifierUnavailable]
        #expect(flags.unavailableAnalysisNames == ["画面识别", "人脸检测"])
    }
}
