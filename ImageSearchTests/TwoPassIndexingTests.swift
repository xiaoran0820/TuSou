import Foundation
import Testing
import UIKit
import Vision
@testable import ImageSearch

@Suite("建索引分两步：先画面，后文字")
struct TwoPassIndexingTests {
    private typealias F = Fixture

    @Test("第一步不做文字识别：不发文字识别请求，记录标上「文字待识别」，不算没跑成")
    func analyzeWithoutText() {
        var requested: [String] = []
        let result = ImageAnalyzer.analyze(includeText: false) { request in
            requested.append(String(describing: type(of: request)))
        }
        #expect(!requested.contains("VNRecognizeTextRequest"))
        #expect(requested.count == 3)
        #expect(result.flags == .textRecognitionPending)
        #expect(result.ocrText.isEmpty)
    }

    @Test("单独的文字识别：没跑成和「没有字」分得开")
    func recognizeTextFailure() {
        struct Failure: Error {}
        let failed = ImageAnalyzer.recognizeText { _ in throw Failure() }
        #expect(failed.failed && failed.text.isEmpty)
        let ranButEmpty = ImageAnalyzer.recognizeText { _ in }
        #expect(!ranButEmpty.failed && ranButEmpty.text.isEmpty)
    }

    @Test("「文字待识别」不算索引不完整：「重新扫描」不会因此重做整张图，界面也不列成没跑成；但会计入待识别的数量")
    func pendingIsNotIncomplete() {
        let pending = F.record("p", flags: .textRecognitionPending)
        #expect(!IndexingEngine.isPartial(pending))
        #expect(IndexingEngine.unavailableAnalyses(of: pending).isEmpty)
        #expect(pending.flags.unavailableAnalysisNames.isEmpty)
        let stats = IndexStats.compute(ids: ["p", "q"], records: ["p": pending, "q": F.record("q")])
        #expect(stats.textPending == 1)
        #expect(stats.indexed == 2)
    }

    @Test("检索要看图中文字时（几乎所有词都会顺带查图中文字），文字还没识别的图片单独报告；不看文字的检索不报告")
    func searchReportsPendingText() {
        let records = [F.record("done", ocr: "TUSOU 2026"), F.record("waiting", flags: .textRecognitionPending),
                       F.record("other")]
        let out = F.search("TUSOU", records)
        #expect(out.hits.map(\.id) == ["done"])
        #expect(out.textPendingCount == 1)
        #expect(out.incomplete.isEmpty)
        let labelsOnly = SearchEngine(options: SearchOptions(text: false, expansion: false))
            .search(query: "猫", ids: records.map(\.id), records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                    metas: [:], now: F.now, calendar: F.calendar)
        #expect(labelsOnly.textPendingCount == 0)
    }

    /// 白底黑字的测试图（iOS 模拟器里文字识别能跑）。size 默认 1000×400；传小尺寸得到「小预览图」
    private func textImage(size: CGSize = CGSize(width: 1000, height: 400)) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ("TUSOU 2026" as NSString).draw(in: CGRect(x: size.width * 0.08, y: size.height * 0.3,
                                                     width: size.width * 0.9, height: size.height * 0.5), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: size.height * 0.3), .foregroundColor: UIColor.black,
            ])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("twopass-\(UUID().uuidString).png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    @Test("真实流程：第一步留下「待识别」，第二步读同一张图补上文字，和一次做完认出的文字一样")
    func realTwoPassMatchesSinglePass() async throws {
        let url = try textImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(await IndexingEngine.process(.imported(id: "i:text.png", url: url),
                                                              context: .init(deferText: true)))
        #expect(first.flags.contains(.textRecognitionPending))
        #expect(!first.flags.contains(.textRecognitionFailed))
        #expect(first.ocrText.isEmpty)

        let second = try #require(await IndexingEngine.process(.text(record: first, location: .file(url)),
                                                               context: .init()))
        #expect(!second.flags.contains(.textRecognitionPending))
        #expect(second.ocrText.contains("TUSOU"))
        // 第二步只动文字：画面识别的结果原样保留
        #expect(second.labels == first.labels)
        #expect(second.faceCount == first.faceCount)
        #expect(second.flags == first.flags.subtracting(.textRecognitionPending))

        let single = try #require(await IndexingEngine.process(.imported(id: "i:text.png", url: url),
                                                               context: .init(deferText: false)))
        #expect(!single.flags.contains(.textRecognitionPending))
        #expect(single.ocrText == second.ocrText)
    }

    @Test("只拿到很小的预览图（最长边不到 200 像素）：两种方式都不做文字识别，标成「小预览图」，不进第二步，「重新扫描」时重做")
    func smallPreviewSkipsText() async throws {
        let url = try textImage(size: CGSize(width: 160, height: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        for deferText in [true, false] {
            let r = try #require(await IndexingEngine.process(.imported(id: "i:small.png", url: url),
                                                              context: .init(deferText: deferText)))
            #expect(r.flags.contains(.smallPreview))
            #expect(!r.flags.contains(.textRecognitionPending))
            #expect(!r.flags.contains(.textRecognitionFailed))
            #expect(r.ocrText.isEmpty)
            #expect(IndexingEngine.isPartial(r))
        }
        // 第二步重新读图时还是小图：同样不识别，清掉「待识别」
        let pending = F.record("i:small.png", flags: .textRecognitionPending)
        let second = try #require(await IndexingEngine.process(.text(record: pending, location: .file(url)), context: .init()))
        #expect(second.flags.contains(.smallPreview))
        #expect(!second.flags.contains(.textRecognitionPending))
        #expect(second.ocrText.isEmpty)
        // 界面不把它列成某一项识别「没跑成」，单独计数
        #expect(second.flags.unavailableAnalysisNames.isEmpty)
        #expect(IndexStats.compute(ids: ["i:small.png"], records: ["i:small.png": second]).smallPreview == 1)
    }

    @Test("按图中文字搜：只拿到小预览图的照片算「没能完成文字识别」")
    func searchReportsSmallPreview() {
        let records = [F.record("done", ocr: "TUSOU 2026"), F.record("small", flags: .smallPreview)]
        let out = F.search("TUSOU", records)
        #expect(out.hits.map(\.id) == ["done"])
        #expect(out.incomplete == [IncompleteAnalysis(name: "文字识别", count: 1)])
    }

    @Test("流水线：第一步把读进来的图交出去，在内存里识别出的文字和重新读图识别的一样；小预览图不交出去")
    func inMemoryTextMatchesReload() async throws {
        let url = try textImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let handoff = ImageHandoff()
        let first = try #require(await IndexingEngine.process(.imported(id: "i:text.png", url: url),
                                                              context: .init(deferText: true, handoff: handoff)))
        let image = try #require(handoff.take("i:text.png"))
        let inMemory = try #require(await IndexingEngine.process(.textInMemory(record: first, image: image), context: .init()))
        #expect(!inMemory.flags.contains(.textRecognitionPending))
        #expect(inMemory.ocrText.contains("TUSOU"))
        let reloaded = try #require(await IndexingEngine.process(.text(record: first, location: .file(url)), context: .init()))
        #expect(inMemory.ocrText == reloaded.ocrText)
        #expect(inMemory.flags == reloaded.flags)

        let small = try textImage(size: CGSize(width: 160, height: 64))
        defer { try? FileManager.default.removeItem(at: small) }
        _ = await IndexingEngine.process(.imported(id: "i:small.png", url: small), context: .init(deferText: true, handoff: handoff))
        #expect(handoff.take("i:small.png") == nil)
    }

    @Test("第二步读不到图：不再「待识别」，改记为文字识别没跑成（「重新扫描」时重做）")
    func missingImageInSecondPass() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).png")
        let record = F.record("i:missing.png", flags: .textRecognitionPending)
        let out = try #require(await IndexingEngine.process(.text(record: record, location: .file(missing)),
                                                            context: .init()))
        #expect(!out.flags.contains(.textRecognitionPending))
        #expect(out.flags.contains(.textRecognitionFailed))
        #expect(IndexingEngine.isPartial(out))
    }
}
