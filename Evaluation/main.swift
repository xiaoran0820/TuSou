// 检索效果评测：在 Mac 上用 App 的同一套识别（Vision + MobileCLIP）和检索代码，
// 对评测集里的每个查询比较五种方案的 Precision@5、Recall@5 和 MRR。
//
// 用法：evaluate <图片目录> <queries.json> <编译好的 MobileCLIP 模型目录> <App 资源目录> [结果 JSON]
// 图片 id 用文件名；文件名匹配不参与（文件名里有类别名，会泄露答案）。

import CoreGraphics
import Foundation

struct Query: Decodable {
    let query: String
    let relevant: [String]
}

struct Metrics {
    var p5 = 0.0, r5 = 0.0, mrr = 0.0

    init() {}

    init(ranked: [String], relevant: Set<String>) {
        let hits = ranked.prefix(5).filter(relevant.contains).count
        p5 = Double(hits) / 5
        r5 = Double(hits) / Double(relevant.count)
        mrr = ranked.firstIndex(where: relevant.contains).map { 1.0 / Double($0 + 1) } ?? 0
    }

    static func mean(_ all: [Metrics]) -> Metrics {
        var m = Metrics()
        let n = Double(all.count)
        m.p5 = all.map(\.p5).reduce(0, +) / n
        m.r5 = all.map(\.r5).reduce(0, +) / n
        m.mrr = all.map(\.mrr).reduce(0, +) / n
        return m
    }
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("用法：evaluate <图片目录> <queries.json> <模型目录> <App 资源目录> [结果 JSON]")
    exit(2)
}
let imagesDir = URL(fileURLWithPath: args[1])
let queries = try JSONDecoder().decode([Query].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let modelsDir = URL(fileURLWithPath: args[3])
let resources = URL(fileURLWithPath: args[4])

let dictionary = try LabelDictionary(contentsOf: resources.appendingPathComponent("LabelDictionary.txt"))
let glossary = (try? Glossary(contentsOf: resources.appendingPathComponent("cedict-glossary.tsv"))) ?? Glossary(entries: [:])
guard let tokenizer = CLIPTokenizer(vocabURL: resources.appendingPathComponent("clip-vocab.json"),
                                    mergesURL: resources.appendingPathComponent("clip-merges.txt")),
      let clip = MobileCLIP(imageModelURL: modelsDir.appendingPathComponent("mobileclip_s2_image.mlmodelc"),
                            textModelURL: modelsDir.appendingPathComponent("mobileclip_s2_text.mlmodelc"),
                            tokenizer: tokenizer) else {
    print("模型或词表加载失败")
    exit(1)
}

// 1. 建索引：和 App 一样，每张图做 Vision 分析，并算 MobileCLIP 向量
let files = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path).filter { $0.hasSuffix(".jpg") }.sorted()
var ids: [String] = []
var records: [String: ImageRecord] = [:]
var metas: [String: ImageMeta] = [:]
var visionTime = 0.0, clipTime = 0.0
for file in files {
    let url = imagesDir.appendingPathComponent(file)
    guard let image = ImageAnalyzer.downsampledImage(at: url, maxPixel: ImageAnalyzer.analysisMaxPixel) else {
        print("读不出图片：\(file)")
        continue
    }
    var t = Date()
    let a = ImageAnalyzer.analyze(image)
    visionTime += Date().timeIntervalSince(t)
    t = Date()
    let embedding = clip.embed(image: image)
    clipTime += Date().timeIntervalSince(t)
    records[file] = ImageRecord(id: file, source: .imported, sourceModificationDate: nil, labels: a.labels,
                                ocrText: a.ocrText, faceCount: a.faceCount, flags: a.flags,
                                pixelWidth: image.width, pixelHeight: image.height,
                                analyzerVersion: ImageAnalyzer.version, indexedAt: Date(),
                                clipEmbedding: embedding, clipModel: clip.modelID)
    metas[file] = ImageMeta()
    ids.append(file)
}
print(String(format: "已索引 %d 张：Vision 平均 %.0f ms/张，MobileCLIP 平均 %.1f ms/张\n",
             ids.count, visionTime / Double(ids.count) * 1000, clipTime / Double(ids.count) * 1000))

// 2. 五种方案
let configs: [(name: String, options: SearchOptions?)] = [
    ("A 画面标签", SearchOptions(labels: true, text: false, expansion: false, semantic: false)),
    ("B 标签 + 图中文字", SearchOptions(labels: true, text: true, expansion: false, semantic: false)),
    ("C 标签 + 文字 + 词典扩展（接入前）", SearchOptions(labels: true, text: true, expansion: true, semantic: false)),
    ("D C + MobileCLIP（接入后）", .all),
    ("E 只用 MobileCLIP（对照）", nil),
]

/// ids：完整排名；shown：App 默认显示出来的结果（有完全匹配时只显示完全匹配），纯向量检索没有这一项
func ranking(_ query: String, _ options: SearchOptions?) -> (ids: [String], prompt: String?, shown: [String]?) {
    let base = SearchEngine(dictionary: dictionary, expander: .shared, textEmbedder: clip, options: options ?? .all,
                            glossary: glossary)
    guard let options else {
        // 纯向量检索：按相似度给全部图片排序，不设阈值
        guard let prompt = base.semanticPrompt(for: base.plan(for: query), query: query),
              let q = clip.embed(text: prompt) else { return ([], nil, nil) }
        let sorted = ids.sorted {
            MobileCLIP.similarity(records[$0]!.clipEmbedding ?? [], q) > MobileCLIP.similarity(records[$1]!.clipEmbedding ?? [], q)
        }
        return (sorted, prompt, nil)
    }
    let engine = SearchEngine(dictionary: dictionary, expander: .shared, textEmbedder: clip, options: options, glossary: glossary)
    let out = engine.search(query: query, ids: ids, records: records, metas: metas)
    return (out.hits.map(\.id), out.semanticPrompt, out.primaryHits.map(\.id))
}

var perConfig: [[Metrics]] = Array(repeating: [], count: configs.count)
var shownTotal = Array(repeating: 0, count: configs.count), shownIrrelevant = Array(repeating: 0, count: configs.count)
var report: [[String: Any]] = []
var searchTimes: [Double] = []
for q in queries {
    let relevant = Set(q.relevant)
    var row: [String: Any] = ["query": q.query, "relevant": q.relevant]
    var line = q.query.padding(toLength: 12, withPad: " ", startingAt: 0)
    for (k, config) in configs.enumerated() {
        let t = Date()
        let r = ranking(q.query, config.options)
        if k == 3 { searchTimes.append(Date().timeIntervalSince(t) * 1000) }
        let m = Metrics(ranked: r.ids, relevant: relevant)
        perConfig[k].append(m)
        line += String(format: " | %@ %.1f/%.2f/%.2f", String(config.name.prefix(1)), m.p5, m.r5, m.mrr)
        var entry: [String: Any] = ["p5": m.p5, "r5": m.r5, "mrr": m.mrr, "top5": Array(r.ids.prefix(5))]
        if let shown = r.shown {
            let wrong = shown.filter { !relevant.contains($0) }.count
            shownTotal[k] += shown.count
            shownIrrelevant[k] += wrong
            entry["shown"] = shown.count
            entry["shown_irrelevant"] = wrong
        }
        row[String(config.name.prefix(1))] = entry
        if k == 3 { row["prompt"] = r.prompt ?? NSNull() }
    }
    print(line)
    report.append(row)
}

print("\n方案                              Precision@5  Recall@5   MRR")
var summary: [[String: Any]] = []
for (k, config) in configs.enumerated() {
    let m = Metrics.mean(perConfig[k])
    print(config.name.padding(toLength: 30, withPad: " ", startingAt: 0) + String(format: "   %.3f      %.3f     %.3f", m.p5, m.r5, m.mrr))
    var s: [String: Any] = ["config": config.name, "precision@5": m.p5, "recall@5": m.r5, "mrr": m.mrr]
    if config.options != nil { s["shown"] = shownTotal[k]; s["shown_irrelevant"] = shownIrrelevant[k] }
    summary.append(s)
}
print("\n默认显示出来的结果（有完全匹配时只显示完全匹配）")
for (k, config) in configs.enumerated() where config.options != nil {
    let pct = shownTotal[k] == 0 ? 0 : Double(shownIrrelevant[k]) / Double(shownTotal[k]) * 100
    print(config.name.padding(toLength: 30, withPad: " ", startingAt: 0)
          + String(format: "   共 %d 张，不相关 %d 张（%.0f%%）", shownTotal[k], shownIrrelevant[k], pct))
}
searchTimes.sort()
print(String(format: "\n方案 D 的单次检索：中位数 %.1f ms，最慢 %.1f ms（%d 张图）", searchTimes[searchTimes.count / 2], searchTimes.last!, ids.count))

if args.count > 5 {
    let result: [String: Any] = [
        "images": ids.count, "queries": queries.count, "model": clip.modelID,
        "thresholds": ["min_similarity": SearchEngine.semanticMinSimilarity, "min_z": SearchEngine.semanticMinZ],
        "summary": summary, "per_query": report,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[5]))
    print("结果已写入 \(args[5])")
}
