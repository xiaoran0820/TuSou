import Foundation
import Observation
import SwiftUI
import Translation

/// 把一段中文整句翻成英文。没有可用的翻译时返回 nil，检索退回逐词翻译
@MainActor
protocol QueryTranslating: AnyObject {
    func english(for chinese: String) async -> String?
}

/// 中文查询的整句翻译：用 iOS 自带的翻译（Translation 框架），在本机完成，不联网。
/// 前提是系统里已经下载好「中文」和「英语」两种翻译语言。没有下载时这里什么都不做：
/// 图搜不会弹出下载提示，也不会自己下载，检索照旧逐词翻译。
@Observable @MainActor
final class SystemTranslator: QueryTranslating {
    enum Status: Equatable {
        /// iOS 18 以前的系统，或者模拟器
        case unsupported
        /// 系统支持，但翻译语言还没有下载
        case notInstalled
        case ready
    }

    private(set) var status: Status = .unsupported
    /// 设置里的开关：关掉后一律逐词翻译
    var isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled != oldValue { onChange?() }
        }
    }
    /// 现在的检索会不会用整句翻译
    var isActive: Bool { isEnabled && status == .ready }
    /// 翻译变得可用或不可用时调用：让当前的查询重新搜一遍
    @ObservationIgnored var onChange: (() -> Void)?

    private enum Keys { static let enabled = "useSystemTranslation" }
    private static let source = Locale.Language(identifier: "zh-Hans")
    private static let target = Locale.Language(identifier: "en")
    /// 翻译迟迟不回来时不让检索一直等：这一次退回逐词翻译
    private static let timeout: Duration = .seconds(3)
    private static let cacheLimit = 300

    private struct Request {
        let text: String
        let reply: Reply
    }

    /// 一次请求的回信：翻译结果和超时谁先到用谁的，只回一次
    private final class Reply {
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func resume(_ value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var requests: AsyncStream<Request>.Continuation?
    @ObservationIgnored private var serveGeneration = 0
    /// TranslationSession.Configuration；iOS 18 才有这个类型，所以按 Any 存
    @ObservationIgnored private var storedConfiguration: Any?

    /// 查一次系统里有没有装好中文 → 英语的翻译语言（只是查询，不会触发下载）。启动和回到前台时调用
    func refreshStatus() async {
        let old = status
        #if targetEnvironment(simulator)
        status = .unsupported   // 模拟器里用不了系统翻译
        #else
        if #available(iOS 18.0, *) {
            switch await LanguageAvailability().status(from: Self.source, to: Self.target) {
            case .installed: status = .ready
            case .supported: status = .notInstalled
            default: status = .unsupported
            }
            if status == .ready, storedConfiguration == nil {
                storedConfiguration = TranslationSession.Configuration(source: Self.source, target: Self.target)
            }
        } else {
            status = .unsupported
        }
        #endif
        if status != old { onChange?() }
    }

    /// 交给视图的 translationTask。只有语言已经装好、开关开着时才不是 nil：
    /// 语言没装时去翻译，系统会弹出下载提示，图搜不做这件事
    @available(iOS 18.0, *)
    var configuration: TranslationSession.Configuration? {
        isActive ? storedConfiguration as? TranslationSession.Configuration : nil
    }

    /// 在视图的 translationTask 闭包里调用。翻译会话只在这个闭包里有效，所以在这里循环处理翻译请求，
    /// 直到视图消失或配置变了（那时这个任务被取消，循环结束）
    @available(iOS 18.0, *)
    func serve(_ session: TranslationSession) async {
        serveGeneration += 1
        let generation = serveGeneration
        let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
        requests = continuation
        onChange?()
        for await request in stream {
            let text = try? await session.translate(request.text).targetText
            request.reply.resume(text)
        }
        if generation == serveGeneration { requests = nil }
    }

    func english(for chinese: String) async -> String? {
        guard isActive, let requests else { return nil }
        if let hit = cache[chinese] { return hit }
        let result: String? = await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            requests.yield(Request(text: chinese, reply: reply))
            Task { @MainActor in
                try? await Task.sleep(for: Self.timeout)
                reply.resume(nil)
            }
        }
        if let result {
            if cache.count >= Self.cacheLimit { cache.removeAll() }
            cache[chinese] = result
        }
        return result
    }
}

/// 挂在根视图上：系统翻译可用时，让 SystemTranslator 拿到翻译会话
struct SystemTranslationHost: ViewModifier {
    let translator: SystemTranslator

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(translator.configuration) { session in
                await translator.serve(session)
            }
        } else {
            content
        }
    }
}
