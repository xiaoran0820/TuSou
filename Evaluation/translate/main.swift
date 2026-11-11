// 评测用：在 Mac 上用系统自带的翻译（Translation 框架，在本机完成）把一批中文译成英文，
// 生成评测程序读的译文表。App 里的整句翻译用的是同一个框架（ImageSearch/App/SystemTranslator.swift）。
//
// 编译：swiftc -parse-as-library -O -o translate Evaluation/translate/main.swift
// 用法：translate <输入.txt，每行一条中文> <输出.tsv，每行「中文<TAB>英文」>
// 输入是 SearchEngine.textForTranslation 对每条查询给出的文本。需要 macOS 15 或更新的系统，
// 并且已经在「系统设置 › 通用 › 语言与地区 › 翻译语言」里下载好中文（简体）和英语。
// 翻译语言没装好时直接退出（退出码 3），不去翻译，所以不会弹出下载提示。
// 翻译会话要挂在一个显示出来的视图上，所以运行时会开一个小窗口，译完自动退出。
import SwiftUI
import Translation

let source = Locale.Language(identifier: "zh-Hans")
let target = Locale.Language(identifier: "en")

struct Runner: View {
    @State private var configuration: TranslationSession.Configuration?
    @State private var message = "正在检查翻译语言…"

    var body: some View {
        Text(message).padding().frame(width: 360, height: 80)
            .task {
                let status = await LanguageAvailability().status(from: source, to: target)
                guard status == .installed else {
                    print("翻译语言没有装好（状态：\(status)），没有翻译")
                    exit(3)
                }
                message = "正在用系统翻译…"
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
            .translationTask(configuration) { session in
                let args = CommandLine.arguments
                guard args.count == 3, let input = try? String(contentsOfFile: args[1], encoding: .utf8) else {
                    print("用法：mactranslate <输入.txt> <输出.tsv>")
                    exit(2)
                }
                var out = ""
                var failed = 0
                let start = Date()
                let lines = input.split(separator: "\n").map(String.init)
                for line in lines {
                    do {
                        let text = try await session.translate(line).targetText
                        out += line + "\t" + text.replacingOccurrences(of: "\n", with: " ") + "\n"
                    } catch {
                        failed += 1
                        out += line + "\t\n"
                    }
                }
                try? out.write(toFile: args[2], atomically: true, encoding: .utf8)
                print(String(format: "译了 %d 条，失败 %d 条，平均 %.0f 毫秒一条", lines.count, failed,
                             Date().timeIntervalSince(start) / Double(max(1, lines.count)) * 1000))
                exit(0)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.accessory)   // 不进 Dock，也不抢键盘焦点
        // 翻译会话要挂在一个显示出来的视图上，所以开一个小窗口
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 80), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.title = "图搜评测：系统翻译"
        w.contentView = NSHostingView(rootView: Runner())
        w.orderFrontRegardless()
        window = w
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
