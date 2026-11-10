//  CLIPTokenizer.swift
//
//  CLIP 的 BPE 分词器：MobileCLIP 的文本编码器要求输入 77 个 token。
//  算法沿用 OpenAI CLIP 的 simple_tokenizer；Swift 写法参考了 Hugging Face swift-coreml-transformers
//  （Apache License 2.0）和 Apple ml-mobileclip 的 iOS 示例（MIT License）。相对示例的改动：
//  - 只使用前 48,894 条合并规则（与 OpenAI 一致；示例用了全部 262,144 条，生僻词会合并出词表里没有的片段而被丢掉）；
//  - 词表文件缺失时返回 nil，而不是崩溃；
//  - 超过 75 个 token 时截断（示例会数组越界）；
//  - 字节到字符的映射按 GPT-2 的规则计算，而不是硬编码；
//  - 不可变的 struct，可以在后台线程使用。
//  许可证全文见 ThirdPartyNotices.md。

import Foundation

struct CLIPTokenizer: Sendable {
    static let contextLength = 77
    /// OpenAI CLIP 使用的合并规则条数：49,152 − 256 − 2
    static let mergeCount = 48_894

    let startToken: Int
    let endToken: Int
    private let encoder: [String: Int]
    private let ranks: [Pair: Int]

    private struct Pair: Hashable, Sendable {
        let a: String
        let b: String
    }

    /// 从 App 包里的 clip-vocab.json 和 clip-merges.txt 加载
    init?(bundle: Bundle = .main) {
        guard let vocab = bundle.url(forResource: "clip-vocab", withExtension: "json"),
              let merges = bundle.url(forResource: "clip-merges", withExtension: "txt") else { return nil }
        self.init(vocabURL: vocab, mergesURL: merges)
    }

    init?(vocabURL: URL, mergesURL: URL) {
        guard let data = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int].self, from: data),
              let text = try? String(contentsOf: mergesURL, encoding: .utf8),
              let sot = vocab["<|startoftext|>"], let eot = vocab["<|endoftext|>"] else { return nil }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(Self.mergeCount)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = ranks.count
            if ranks.count == Self.mergeCount { break }
        }
        self.encoder = vocab
        self.ranks = ranks
        self.startToken = sot
        self.endToken = eot
    }

    /// 文本 → token id（不含起止符）
    func encode(_ text: String) -> [Int] {
        let cleaned = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ns = cleaned as NSString
        var ids: [Int] = []
        for match in Self.pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            let mapped = String(piece.utf8.map { Self.byteToChar[Int($0)] })
            for token in bpe(mapped) {
                if let id = encoder[token] { ids.append(id) }
            }
        }
        return ids
    }

    /// 模型输入：起始符 + token + 结束符，补 0 到 77 个；太长时只保留前 75 个 token
    func inputIDs(for text: String) -> [Int32] {
        var ids = [startToken] + encode(text).prefix(Self.contextLength - 2) + [endToken]
        ids += Array(repeating: 0, count: Self.contextLength - ids.count)
        return ids.map { Int32($0) }
    }

    // MARK: - BPE

    private static let pattern = try! NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+")

    /// GPT-2 的 bytes_to_unicode：把 256 个字节映射成可见字符
    static let byteToChar: [Character] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var n = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + n)
            n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bytes, chars) { table[b] = Character(Unicode.Scalar(UInt32(c))!) }
        return table
    }()

    /// 按合并规则的优先级，反复合并相邻的两段，直到不能再合并
    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }
}
