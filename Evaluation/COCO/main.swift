// COCO 2017 验证集评测（5,000 张日常照片，每张 5 条人工英文描述，80 类物体标注），
// 用 App 的同一套识别（Vision + MobileCLIP）、存储（IndexStore）和检索（SearchEngine）代码。
//
// 用法：
//   evaluate index <图片目录> <索引数据库> <模型目录> <资源目录>
//       给每张图做 Vision 分析、算 MobileCLIP 向量，存进 App 格式的 SQLite 索引（可中断后续跑）
//   evaluate model <索引数据库> <captions_val2017.json> <模型目录> <资源目录> <结果 JSON>
//       只测模型：每条英文描述在 5,000 张里找它对应的那张（文找图），每张图在 25,000 条描述里找自己的描述（图找文）
//   evaluate app <索引数据库> <instances_val2017.json> <queries_zh.json> <phrases_zh.tsv> <模型目录> <资源目录> <结果 JSON> [译文表.tsv]
//       测 App 整体：中文物体查询（相关 = 含该类物体且面积 ≥ 1%）；中文短语与英文原描述对比。
//       译文表每行「中文<TAB>英文」，是系统翻译对 SearchEngine.textForTranslation 给出的文本的译文；
//       给了就按 App 开着「整句翻译中文查询」时的方式检索（方案 D、E 和中文短语），不给就是逐词翻译

import Accelerate
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("用法见文件开头"); exit(2) }

func loadCLIP(models: URL, resources: URL) -> MobileCLIP {
    guard let tok = CLIPTokenizer(vocabURL: resources.appendingPathComponent("clip-vocab.json"),
                                  mergesURL: resources.appendingPathComponent("clip-merges.txt")),
          let clip = MobileCLIP(imageModelURL: models.appendingPathComponent("mobileclip_s2_image.mlmodelc"),
                                textModelURL: models.appendingPathComponent("mobileclip_s2_text.mlmodelc"),
                                tokenizer: tok) else { print("模型或词表加载失败"); exit(1) }
    return clip
}

func json(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

/// 矩阵乘法 C(m×n) = A(m×k) · B(k×n)，行优先
func matmul(_ a: [Float], _ b: [Float], m: Int, n: Int, k: Int) -> [Float] {
    var c = [Float](repeating: 0, count: m * n)
    vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
    return c
}

/// 读出 App 格式的索引，按 COCO 图片编号排序
func loadIndex(_ path: String) async throws -> (ids: [String], records: [String: ImageRecord], metas: [String: ImageMeta]) {
    let all = try await IndexStore(url: URL(fileURLWithPath: path)).loadAll().sorted { Int($0.id)! < Int($1.id)! }
    let ids = all.map(\.id)
    return (ids, Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: ids.map { ($0, ImageMeta()) }))
}

/// 相关性：图里有这些类别的物体，且每类最大的那个占画面 ≥ 1%；有但更小的不计入（既不算对也不算错）
func relevanceJudge(_ inst: [String: Any]) -> ([String]) -> (relevant: Set<String>, ignore: Set<String>) {
    var catName: [Int: String] = [:]
    for c in inst["categories"] as! [[String: Any]] { catName[c["id"] as! Int] = c["name"] as? String }
    var area: [Int: Double] = [:]
    for im in inst["images"] as! [[String: Any]] { area[im["id"] as! Int] = Double(im["width"] as! Int * (im["height"] as! Int)) }
    var largest: [String: [String: Double]] = [:]     // 类别 → 图片 id → 最大占比
    for a in inst["annotations"] as! [[String: Any]] {
        let img = a["image_id"] as! Int, cat = catName[a["category_id"] as! Int]!
        let ratio = ((a["area"] as? NSNumber)?.doubleValue ?? 0) / (area[img] ?? 1)
        largest[cat, default: [:]][String(img), default: 0] = max(largest[cat]?[String(img)] ?? 0, ratio)
    }
    return { cats in
        var rel: Set<String>? = nil, present: Set<String>? = nil
        for c in cats {
            let m = largest[c] ?? [:]
            let r = Set(m.filter { $0.value >= 0.01 }.keys), p = Set(m.keys)
            rel = rel.map { $0.intersection(r) } ?? r
            present = present.map { $0.intersection(p) } ?? p
        }
        return (rel ?? [], (present ?? []).subtracting(rel ?? []))
    }
}

/// 中文短语文件：每行「图片编号<TAB>英文<TAB>中文」，# 开头的是说明
func readPhrases(_ path: String) throws -> [[String]] {
    try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8).split(separator: "\n")
        .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        .filter { $0.count >= 3 }
}

switch args[1] {

// MARK: - 建索引
case "index":
    let imagesDir = URL(fileURLWithPath: args[2])
    let store = try IndexStore(url: URL(fileURLWithPath: args[3]))
    let clip = loadCLIP(models: URL(fileURLWithPath: args[4]), resources: URL(fileURLWithPath: args[5]))
    let done = Set(try await store.loadAll().map(\.id))
    let files = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path).filter { $0.hasSuffix(".jpg") }.sorted()
    let todo = files.filter { !done.contains(String(Int($0.dropLast(4)) ?? 0)) }
    print("共 \(files.count) 张，已索引 \(done.count) 张，这次处理 \(todo.count) 张", terminator: "\n")
    let start = Date()
    var processed = 0
    for chunkStart in stride(from: 0, to: todo.count, by: 64) {
        let chunk = Array(todo[chunkStart..<min(chunkStart + 64, todo.count)])
        final class Results: @unchecked Sendable {
            var items: [ImageRecord?]; let lock = NSLock()
            init(_ n: Int) { items = Array(repeating: nil, count: n) }
            func set(_ i: Int, _ r: ImageRecord) { lock.lock(); items[i] = r; lock.unlock() }
        }
        let results = Results(chunk.count)
        DispatchQueue.concurrentPerform(iterations: chunk.count) { i in
            let file = chunk[i]
            guard let img = ImageAnalyzer.downsampledImage(at: imagesDir.appendingPathComponent(file),
                                                           maxPixel: ImageAnalyzer.analysisMaxPixel) else { return }
            let a = ImageAnalyzer.analyze(img)
            let embedding = clip.embed(image: img)
            let r = ImageRecord(id: String(Int(file.dropLast(4)) ?? 0), source: .imported, sourceModificationDate: nil,
                                labels: a.labels, ocrText: a.ocrText, faceCount: a.faceCount, flags: a.flags,
                                pixelWidth: img.width, pixelHeight: img.height, analyzerVersion: ImageAnalyzer.version,
                                indexedAt: Date(), clipEmbedding: embedding, clipModel: clip.modelID)
            results.set(i, r)
        }
        try await store.upsert(results.items.compactMap { $0 })
        processed += chunk.count
        let rate = Date().timeIntervalSince(start) / Double(processed)
        print(String(format: "  %d / %d（%.0f ms/张）", processed, todo.count, rate * 1000))
    }
    print("完成，用时 \(Int(Date().timeIntervalSince(start))) 秒")

// MARK: - 只测模型：文找图 / 图找文
case "model":
    let store = try IndexStore(url: URL(fileURLWithPath: args[2]))
    let caps = try json(URL(fileURLWithPath: args[3]))
    let clip = loadCLIP(models: URL(fileURLWithPath: args[4]), resources: URL(fileURLWithPath: args[5]))
    let records = try await store.loadAll().filter { $0.clipEmbedding?.count == 512 }.sorted { Int($0.id)! < Int($1.id)! }
    let imageIndex = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, $0) })
    let nImg = records.count, d = 512
    var imgT = [Float](repeating: 0, count: d * nImg)   // 512 × N（转置，方便做乘法）
    for (j, r) in records.enumerated() { for k in 0..<d { imgT[k * nImg + j] = r.clipEmbedding![k] } }

    let anns = (caps["annotations"] as! [[String: Any]]).compactMap { a -> (img: Int, text: String)? in
        guard let id = a["image_id"] as? Int, let t = a["caption"] as? String, imageIndex[String(id)] != nil else { return nil }
        return (imageIndex[String(id)]!, t.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    print("图片 \(nImg) 张，描述 \(anns.count) 条；开始编码描述…")
    var t0 = Date()
    var txt = [Float](repeating: 0, count: anns.count * d)
    for (i, a) in anns.enumerated() {
        guard let e = clip.embed(text: a.text) else { continue }
        for k in 0..<d { txt[i * d + k] = e[k] }
        if (i + 1) % 5000 == 0 { print("  \(i + 1) 条（\(Int(Date().timeIntervalSince(t0))) 秒）") }
    }
    let textTime = Date().timeIntervalSince(t0) / Double(anns.count)
    t0 = Date()

    // 文找图：每条描述在全部图片里的排名
    var t2i = [Int](repeating: 0, count: anns.count)
    let chunk = 1000
    for s in stride(from: 0, to: anns.count, by: chunk) {
        let m = min(chunk, anns.count - s)
        let sims = matmul(Array(txt[(s * d)..<((s + m) * d)]), imgT, m: m, n: nImg, k: d)
        for i in 0..<m {
            let row = sims[(i * nImg)..<((i + 1) * nImg)]
            let target = row[row.startIndex + anns[s + i].img]
            t2i[s + i] = row.filter { $0 > target }.count + 1
        }
    }
    // 图找文：每张图在全部描述里，它自己的描述最靠前排第几
    var txtT = [Float](repeating: 0, count: d * anns.count)
    for i in 0..<anns.count { for k in 0..<d { txtT[k * anns.count + i] = txt[i * d + k] } }
    var ownCaptions = [[Int]](repeating: [], count: nImg)
    for (i, a) in anns.enumerated() { ownCaptions[a.img].append(i) }
    var i2t = [Int](repeating: 0, count: nImg)
    var imgRows = [Float](repeating: 0, count: nImg * d)
    for (j, r) in records.enumerated() { for k in 0..<d { imgRows[j * d + k] = r.clipEmbedding![k] } }
    for s in stride(from: 0, to: nImg, by: 250) {
        let m = min(250, nImg - s)
        let sims = matmul(Array(imgRows[(s * d)..<((s + m) * d)]), txtT, m: m, n: anns.count, k: d)
        for i in 0..<m {
            let row = sims[(i * anns.count)..<((i + 1) * anns.count)]
            let best = ownCaptions[s + i].map { row[row.startIndex + $0] }.max() ?? 1
            i2t[s + i] = row.filter { $0 > best }.count + 1
        }
    }
    func recall(_ ranks: [Int], _ k: Int) -> Double { Double(ranks.filter { $0 <= k }.count) / Double(ranks.count) }
    let summary: [String: Any] = [
        "images": nImg, "captions": anns.count, "text_ms_per_caption": textTime * 1000,
        "text_to_image": ["R@1": recall(t2i, 1), "R@5": recall(t2i, 5), "R@10": recall(t2i, 10)],
        "image_to_text": ["R@1": recall(i2t, 1), "R@5": recall(i2t, 5), "R@10": recall(i2t, 10)],
    ]
    print(String(format: "文找图（%d 条描述 → %d 张图）R@1 %.1f%%  R@5 %.1f%%  R@10 %.1f%%", anns.count, nImg,
                 recall(t2i, 1) * 100, recall(t2i, 5) * 100, recall(t2i, 10) * 100))
    print(String(format: "图找文（%d 张图 → %d 条描述）R@1 %.1f%%  R@5 %.1f%%  R@10 %.1f%%", nImg, anns.count,
                 recall(i2t, 1) * 100, recall(i2t, 5) * 100, recall(i2t, 10) * 100))
    print(String(format: "编码一条描述平均 %.1f ms；排名计算 %.1f 秒", textTime * 1000, Date().timeIntervalSince(t0)))
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[6]))

// MARK: - 测 App 整体
case "app":
    let store = try IndexStore(url: URL(fileURLWithPath: args[2]))
    let inst = try json(URL(fileURLWithPath: args[3]))
    let queryList = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[4]))) as! [[String: Any]]
    let phraseLines = try String(contentsOf: URL(fileURLWithPath: args[5]), encoding: .utf8).split(separator: "\n")
        .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        .filter { $0.count >= 3 }
    let models = URL(fileURLWithPath: args[6]), resources = URL(fileURLWithPath: args[7])
    let clip = loadCLIP(models: models, resources: resources)
    let dictionary = try LabelDictionary(contentsOf: resources.appendingPathComponent("LabelDictionary.txt"))
    let glossary = try Glossary(contentsOf: resources.appendingPathComponent("cedict-glossary.tsv"))

    var translations: [String: String] = [:]
    if args.count > 9 {
        for line in try String(contentsOfFile: args[9], encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, !parts[1].isEmpty { translations[parts[0]] = parts[1] }
        }
        print("译文表：\(translations.count) 条")
    }

    let all = try await store.loadAll().sorted { Int($0.id)! < Int($1.id)! }
    let ids = all.map(\.id)
    let records = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    let metas = Dictionary(uniqueKeysWithValues: ids.map { ($0, ImageMeta()) })

    // 相关性：图里有该类物体，且最大的那个占画面 ≥ 1%；有但更小的不计入（既不算对也不算错）
    var catName: [Int: String] = [:]
    for c in inst["categories"] as! [[String: Any]] { catName[c["id"] as! Int] = c["name"] as? String }
    var area: [Int: Double] = [:]
    for im in inst["images"] as! [[String: Any]] { area[im["id"] as! Int] = Double(im["width"] as! Int * (im["height"] as! Int)) }
    var largest: [String: [String: Double]] = [:]     // 类别 → 图片 id → 最大占比
    for a in inst["annotations"] as! [[String: Any]] {
        let img = a["image_id"] as! Int, cat = catName[a["category_id"] as! Int]!
        let ratio = ((a["area"] as? NSNumber)?.doubleValue ?? 0) / (area[img] ?? 1)
        largest[cat, default: [:]][String(img), default: 0] = max(largest[cat]?[String(img)] ?? 0, ratio)
    }
    func relevance(_ cats: [String]) -> (relevant: Set<String>, ignore: Set<String>) {
        var rel: Set<String>? = nil, present: Set<String>? = nil
        for c in cats {
            let m = largest[c] ?? [:]
            let r = Set(m.filter { $0.value >= 0.01 }.keys), p = Set(m.keys)
            rel = rel.map { $0.intersection(r) } ?? r
            present = present.map { $0.intersection(p) } ?? p
        }
        return (rel ?? [], (present ?? []).subtracting(rel ?? []))
    }

    let configs: [(name: String, options: SearchOptions?)] = [
        ("A 画面标签", SearchOptions(labels: true, text: false, expansion: false, semantic: false)),
        ("B 标签 + 图中文字", SearchOptions(labels: true, text: true, expansion: false, semantic: false)),
        ("C 标签 + 文字 + 词典扩展（接入前）", SearchOptions(labels: true, text: true, expansion: true, semantic: false)),
        ("D 当前 App", .all),
        ("E 只用 MobileCLIP 排序（对照）", nil),
    ]
    struct Acc { var shown = 0, shownRel = 0, shownIrr = 0, relTotal = 0, relShown = 0; var p10 = 0.0, ap = 0.0, n = 0 }
    var acc = [Acc](repeating: Acc(), count: configs.count)
    var perQuery: [[String: Any]] = []
    for q in queryList {
        let text = q["query"] as! String, cats = q["categories"] as! [String]
        let (rel, ignore) = relevance(cats)
        guard rel.count >= 5 else { continue }
        var row: [String: Any] = ["query": text, "categories": cats, "relevant": rel.count]
        for (k, cfg) in configs.enumerated() {
            let engine = SearchEngine(dictionary: dictionary, expander: .shared, textEmbedder: clip,
                                      options: cfg.options ?? .all, glossary: glossary)
            var ranked: [String], shown: [String]?
            let translation = engine.textForTranslation(text).flatMap { translations[$0] }
            if cfg.options == nil {
                guard let p = engine.semanticPrompt(for: engine.plan(for: text), query: text,
                                                    translation: SearchEngine.cleanedTranslation(translation)),
                      let v = clip.embed(text: p) else { continue }
                ranked = ids.sorted { MobileCLIP.similarity(records[$0]!.clipEmbedding ?? [], v) > MobileCLIP.similarity(records[$1]!.clipEmbedding ?? [], v) }
                shown = nil
                row["prompt"] = p
            } else {
                let out = engine.search(query: text, ids: ids, records: records, metas: metas, translation: translation)
                ranked = out.hits.map(\.id)
                shown = out.primaryHits.map(\.id)
                if k == 3 { row["prompt_d"] = out.semanticPrompt ?? NSNull() }
            }
            let judged = ranked.filter { !ignore.contains($0) }
            let top10 = judged.prefix(10)
            let p10 = top10.isEmpty ? 0 : Double(top10.filter(rel.contains).count) / Double(top10.count)
            var hits = 0, sumPrec = 0.0
            for (i, id) in judged.enumerated() where rel.contains(id) { hits += 1; sumPrec += Double(hits) / Double(i + 1) }
            let ap = sumPrec / Double(rel.count)
            acc[k].p10 += p10; acc[k].ap += ap; acc[k].n += 1; acc[k].relTotal += rel.count
            var entry: [String: Any] = ["p10": p10, "ap": ap]
            if let shown {
                let s = shown.filter { !ignore.contains($0) }
                let r = s.filter(rel.contains).count
                acc[k].shown += s.count; acc[k].shownRel += r; acc[k].shownIrr += s.count - r; acc[k].relShown += r
                entry["shown"] = s.count; entry["shown_relevant"] = r
                entry["top_irrelevant"] = Array(s.filter { !rel.contains($0) }.prefix(5))
            }
            row[String(cfg.name.prefix(1))] = entry
        }
        perQuery.append(row)
    }
    print("中文物体查询 \(perQuery.count) 个（相关 = 含该类物体且占画面 ≥ 1%）")
    print("方案                              P@10    AP     默认显示  其中不相关   相关的显示出来")
    var summary: [[String: Any]] = []
    for (k, cfg) in configs.enumerated() where acc[k].n > 0 {
        let a = acc[k], n = Double(a.n)
        var line = cfg.name.padding(toLength: 30, withPad: " ", startingAt: 0) + String(format: "  %.3f  %.3f", a.p10 / n, a.ap / n)
        if cfg.options != nil {
            line += String(format: "  %7d   %5d（%.0f%%）  %.0f%%", a.shown, a.shownIrr, Double(a.shownIrr) / Double(max(a.shown, 1)) * 100,
                           Double(a.relShown) / Double(max(a.relTotal, 1)) * 100)
        }
        print(line)
        summary.append(["config": cfg.name, "p10": a.p10 / n, "map": a.ap / n, "shown": a.shown, "shown_irrelevant": a.shownIrr,
                        "relevant_total": a.relTotal, "relevant_shown": a.relShown])
    }

    // 中文短语 vs 英文原描述：描述对应的那张图排第几（只看 MobileCLIP 相似度），以及 App 默认会不会显示它
    let engine = SearchEngine(dictionary: dictionary, expander: .shared, textEmbedder: clip, options: .all, glossary: glossary)
    func rank(of target: String, prompt: String?) -> Int {
        guard let p = prompt, let v = clip.embed(text: p), let t = records[target]?.clipEmbedding else { return Int.max }
        let ts = MobileCLIP.similarity(t, v)
        return ids.filter { MobileCLIP.similarity(records[$0]!.clipEmbedding ?? [], v) > ts }.count + 1
    }
    var enRanks: [Int] = [], zhRanks: [Int] = [], zhShown = 0, enShown = 0, noPrompt = 0
    var phraseRows: [[String: Any]] = []
    for p in phraseLines {
        let target = p[0], caption = p[1], zh = p[2]
        guard records[target] != nil else { continue }
        let enPrompt = "a photo of " + caption.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let zhTranslation = engine.textForTranslation(zh).flatMap { translations[$0] }
        let zhPrompt = engine.semanticPrompt(for: engine.plan(for: zh), query: zh,
                                             translation: SearchEngine.cleanedTranslation(zhTranslation))
        if zhPrompt == nil { noPrompt += 1 }
        let er = rank(of: target, prompt: enPrompt), zr = rank(of: target, prompt: zhPrompt)
        enRanks.append(er); zhRanks.append(zr)
        let zhOut = engine.search(query: zh, ids: ids, records: records, metas: metas, translation: zhTranslation)
        let enOut = engine.search(query: caption, ids: ids, records: records, metas: metas)
        if zhOut.primaryHits.contains(where: { $0.id == target }) { zhShown += 1 }
        if enOut.primaryHits.contains(where: { $0.id == target }) { enShown += 1 }
        phraseRows.append(["image": target, "caption": caption, "zh": zh, "zh_prompt": zhPrompt ?? NSNull(),
                           "en_rank": er == Int.max ? -1 : er, "zh_rank": zr == Int.max ? -1 : zr,
                           "zh_shown": zhOut.primaryHits.count])
    }
    func r(_ ranks: [Int], _ k: Int) -> Double { Double(ranks.filter { $0 <= k }.count) / Double(max(ranks.count, 1)) }
    let nP = Double(max(enRanks.count, 1))
    print(String(format: "\n中文短语 %d 条（对应图片在 %d 张里排第几，只看 MobileCLIP）", enRanks.count, ids.count))
    print(String(format: "  英文原描述  R@1 %.1f%%  R@5 %.1f%%  R@10 %.1f%%  R@50 %.1f%%   App 默认显示到它：%.0f%%",
                 r(enRanks, 1) * 100, r(enRanks, 5) * 100, r(enRanks, 10) * 100, r(enRanks, 50) * 100, Double(enShown) / nP * 100))
    print(String(format: "  中文短语    R@1 %.1f%%  R@5 %.1f%%  R@10 %.1f%%  R@50 %.1f%%   App 默认显示到它：%.0f%%   描述为空 %d 条",
                 r(zhRanks, 1) * 100, r(zhRanks, 5) * 100, r(zhRanks, 10) * 100, r(zhRanks, 50) * 100, Double(zhShown) / nP * 100, noPrompt))
    let result: [String: Any] = [
        "images": ids.count, "sentence_translations": translations.count, "object_queries": summary, "object_per_query": perQuery,
        "phrases": ["count": enRanks.count, "en_R@1": r(enRanks, 1), "en_R@5": r(enRanks, 5), "en_R@10": r(enRanks, 10),
                    "zh_R@1": r(zhRanks, 1), "zh_R@5": r(zhRanks, 5), "zh_R@10": r(zhRanks, 10),
                    "en_shown_rate": Double(enShown) / nP, "zh_shown_rate": Double(zhShown) / nP, "zh_no_prompt": noPrompt],
        "phrase_rows": phraseRows,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[8]))
    print("结果已写入 \(args[8])")

// MARK: - 比较几组过线标准（同样的数据、同样的查询）
//   evaluate sweep <索引数据库> <instances_val2017.json> <queries_zh.json> <phrases_zh.tsv> <模型目录> <资源目录>
case "sweep":
    let (ids, records, metas) = try await loadIndex(args[2])
    let judge = relevanceJudge(try json(URL(fileURLWithPath: args[3])))
    let queryList = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[4]))) as! [[String: Any]]
    let phrases = try readPhrases(args[5])
    let resources = URL(fileURLWithPath: args[7])
    let clip = loadCLIP(models: URL(fileURLWithPath: args[6]), resources: resources)
    let dictionary = try LabelDictionary(contentsOf: resources.appendingPathComponent("LabelDictionary.txt"))
    let glossary = try Glossary(contentsOf: resources.appendingPathComponent("cedict-glossary.tsv"))
    // 都用差距 0.10、逐词核对 z 1.5 / 相似度 0.15；比较 z 门槛（固定 3.0 或随图库大小变）和「整句强匹配免核对」
    func opt(adaptive: Bool, z: Float = 2.5, check: Bool = true, bypass: Float?) -> SearchOptions {
        SearchOptions(semanticMinZ: z, semanticMaxGap: 0.10, termCheckMinZ: check ? 1.5 : nil, termCheckMinSimilarity: 0.15,
                      termCheckBypassSimilarity: bypass, semanticAdaptiveZ: adaptive)
    }
    let variants: [(String, SearchOptions)] = [
        ("改前：不核对，z 2.5，无差距", SearchOptions(semanticMinZ: 2.5, semanticMaxGap: nil, termCheckMinZ: nil, semanticAdaptiveZ: false)),
        ("固定 z 3.0，总是核对", opt(adaptive: false, z: 3.0, bypass: nil)),
        ("随图库变 z，总是核对", opt(adaptive: true, bypass: nil)),
        ("随图库变 z，整句 ≥0.22 免核对", opt(adaptive: true, bypass: 0.22)),
        ("随图库变 z，整句 ≥0.25 免核对", opt(adaptive: true, bypass: 0.25)),
        ("随图库变 z，整句 ≥0.28 免核对", opt(adaptive: true, bypass: 0.28)),
        ("随图库变 z，不核对", opt(adaptive: true, check: false, bypass: nil)),
    ]
    print("方案                          单类：显示 不相关  召回 |  组合：显示 不相关  召回 | 中文短语：找到 平均显示 | 英文原句：找到")
    for (name, options) in variants {
        let engine = SearchEngine(dictionary: dictionary, expander: .shared, textEmbedder: clip, options: options, glossary: glossary)
        var stats = [(shown: 0, wrong: 0, found: 0, relevant: 0), (shown: 0, wrong: 0, found: 0, relevant: 0)]
        for q in queryList {
            let cats = q["categories"] as! [String]
            let (rel, ignore) = judge(cats)
            guard rel.count >= 5 else { continue }
            let shown = engine.search(query: q["query"] as! String, ids: ids, records: records, metas: metas)
                .primaryHits.map(\.id).filter { !ignore.contains($0) }
            let k = cats.count == 1 ? 0 : 1, found = shown.filter(rel.contains).count
            stats[k].shown += shown.count; stats[k].wrong += shown.count - found
            stats[k].found += found; stats[k].relevant += rel.count
        }
        var phraseHits = 0, phraseShown = 0, captionHits = 0
        for p in phrases where records[p[0]] != nil {
            let out = engine.search(query: p[2], ids: ids, records: records, metas: metas)
            if out.primaryHits.contains(where: { $0.id == p[0] }) { phraseHits += 1 }
            phraseShown += out.primaryHits.count
            let en = engine.search(query: p[1], ids: ids, records: records, metas: metas)
            if en.primaryHits.contains(where: { $0.id == p[0] }) { captionHits += 1 }
        }
        func cell(_ s: (shown: Int, wrong: Int, found: Int, relevant: Int)) -> String {
            String(format: "%6d %4.0f%% %4.0f%%", s.shown, Double(s.wrong) / Double(max(s.shown, 1)) * 100,
                   Double(s.found) / Double(max(s.relevant, 1)) * 100)
        }
        print(name.padding(toLength: 26, withPad: " ", startingAt: 0) + "  " + cell(stats[0]) + " | " + cell(stats[1])
              + String(format: " |      %4.0f%%  %6.0f |    %4.0f%%", Double(phraseHits) / Double(max(phrases.count, 1)) * 100,
                       Double(phraseShown) / Double(max(phrases.count, 1)),
                       Double(captionHits) / Double(max(phrases.count, 1)) * 100))
    }

default:
    print("未知命令 \(args[1])")
    exit(2)
}
