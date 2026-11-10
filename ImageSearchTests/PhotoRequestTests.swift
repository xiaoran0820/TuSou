import Foundation
import Photos
import Testing
import UIKit
@testable import ImageSearch

/// 线程安全地记下被取消的 PhotoKit 请求号
private final class CancelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [PHImageRequestID] = []
    var values: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return ids }
    func append(_ id: PHImageRequestID) { lock.lock(); ids.append(id); lock.unlock() }
}

@Suite("PhotoKit 取图：等待一定会结束")
struct PhotoRequestTests {
    private let degraded: [AnyHashable: Any] = [PHImageResultIsDegradedKey: true]
    private let final: [AnyHashable: Any] = [PHImageResultIsDegradedKey: false]

    @Test("高质量请求：降级预览不算结束，最终回调才结束，多余的回调被忽略")
    func degradedPreviewThenFinal() async {
        let state = ImageRequestState(highQuality: true, cancelRequest: { _ in })
        let preview = UIImage(), full = UIImage()
        let result = await withCheckedContinuation { cont in
            #expect(state.begin(cont))
            state.handle(image: preview, info: degraded)
            state.handle(image: full, info: final)
            state.handle(image: preview, info: nil)
        }
        #expect(result === full)
    }

    @Test("只收到降级预览、最终回调一直不来：超时结束等待，并取消 PhotoKit 请求")
    func timeoutEndsTheWait() async {
        let log = CancelLog()
        let state = ImageRequestState(highQuality: true, cancelRequest: { log.append($0) })
        let result = await withCheckedContinuation { cont in
            _ = state.begin(cont)
            state.setRequestID(42)
            state.handle(image: UIImage(), info: degraded)
            state.cancel()   // 超时到了
        }
        #expect(result == nil)
        #expect(log.values == [42])
    }

    @Test("请求被取消或出错的回调：结束等待，返回空")
    func cancelledOrFailedCallback() async {
        for info: [AnyHashable: Any] in [[PHImageCancelledKey: true],
                                          [PHImageErrorKey: NSError(domain: "test", code: 1)]] {
            let state = ImageRequestState(highQuality: true, cancelRequest: { _ in })
            let result = await withCheckedContinuation { cont in
                _ = state.begin(cont)
                state.handle(image: UIImage(), info: info)
            }
            #expect(result == nil)
        }
    }

    @Test("任务在发请求前就被取消：直接结束，不发请求；之后拿到的请求号也会被取消")
    func cancelledBeforeStart() async {
        let log = CancelLog()
        let state = ImageRequestState(highQuality: true, cancelRequest: { log.append($0) })
        state.cancel()
        let result = await withCheckedContinuation { cont in
            #expect(!state.begin(cont))
        }
        #expect(result == nil)
        state.setRequestID(7)
        #expect(log.values == [7])
    }

    @Test("原图只在 iCloud（最终回调没有图）：结束等待，交给调用方退回本机预览")
    func finalCallbackWithoutImage() async {
        let state = ImageRequestState(highQuality: true, cancelRequest: { _ in })
        let result = await withCheckedContinuation { cont in
            _ = state.begin(cont)
            state.handle(image: nil, info: [PHImageResultIsInCloudKey: true])
        }
        #expect(result == nil)
    }

    @Test("快速模式下，降级图就是最终结果")
    func fastFormatAcceptsDegraded() {
        #expect(ImageRequestState.classify(info: degraded, highQuality: false) == .finished)
        #expect(ImageRequestState.classify(info: degraded, highQuality: true) == .keepWaiting)
    }
}
