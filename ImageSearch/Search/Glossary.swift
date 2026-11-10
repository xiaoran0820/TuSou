import Foundation

/// 离线中英对照表（由 CC-CEDICT 生成，见 Tools/make_glossary.py）：
/// 内置常用词表和标签词典都翻译不了的中文词（富士山、东京塔、金阁寺…），用它转成英文交给 MobileCLIP。
/// 每个词只有一个英文释义；找不到的词照旧只按图中文字匹配。
struct Glossary: Sendable {
    private let entries: [String: String]
    /// 最长的词有几个字（分词时最多往后看这么多字）
    let maxKeyLength: Int

    /// App 包里的对照表；没有这个文件时是空表（其余功能不受影响）
    static let shared: Glossary = {
        guard let url = Bundle.main.url(forResource: "cedict-glossary", withExtension: "tsv"),
              let glossary = try? Glossary(contentsOf: url) else { return Glossary(entries: [:]) }
        return glossary
    }()

    init(entries: [String: String]) {
        self.entries = entries
        maxKeyLength = entries.keys.map(\.count).max() ?? 0
    }

    /// 每行「中文<TAB>英文」，# 开头的是说明。直接按字节切行（逐行用 String 处理要慢好几倍）
    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        var map: [String: String] = [:]
        map.reserveCapacity(110_000)
        var longest = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var start = 0
            while start < n {
                var end = start
                while end < n && bytes[end] != 0x0A { end += 1 }          // \n
                if bytes[start] != 0x23 {                                  // # 开头是说明
                    var tab = start
                    while tab < end && bytes[tab] != 0x09 { tab += 1 }    // \t
                    if tab > start && tab < end {
                        let key = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<tab]), as: UTF8.self)
                        map[key] = String(decoding: UnsafeBufferPointer(rebasing: bytes[(tab + 1)..<end]), as: UTF8.self)
                        longest = max(longest, key.unicodeScalars.count)
                    }
                }
                start = end + 1
            }
        }
        entries = map
        maxKeyLength = longest
    }

    func english(for word: String) -> String? { entries[word] }
    var count: Int { entries.count }
}
