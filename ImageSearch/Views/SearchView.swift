import SwiftUI
import Photos

struct SearchView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var search = app.search
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PhotoAccessCard()
                    IndexStatusCard()
                    AnalysisNoticeCard()
                    if search.evalMode { EvalControls() }
                    if search.trimmedQuery.isEmpty {
                        SuggestionsSection()
                        AllPhotosSection()
                    } else {
                        ResultsSection()
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("图搜")
            .searchable(text: $search.query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "输入关键词，如 海边、猫、发票")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: search.query) {
                try? await Task.sleep(for: .milliseconds(250))   // 输入防抖
                guard !Task.isCancelled else { return }
                await search.run()
            }
            .onChange(of: app.engine.revision) {
                Task { await search.refreshForIndexChange() }
            }
            .navigationDestination(for: DetailRoute.self) { PhotoDetailView(route: $0) }
        }
    }
}

// MARK: - 相册权限

private struct PhotoAccessCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.photoStatus {
        case .notDetermined:
            card(icon: "photo.on.rectangle.angled", title: "允许访问照片",
                 text: "请在弹窗中选择「允许完全访问」，这样才能搜索整个相册。照片只在这台 iPhone 上分析，不会上传。") {
                Button {
                    Task { await app.requestPhotoAccess() }
                } label: {
                    Text("允许访问照片").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("暂不，只检索导入的图片") { app.tab = .imported }
                    .font(.footnote)
            }
        case .denied, .restricted:
            card(icon: "lock.slash", title: "没有相册访问权限",
                 text: "目前只能检索在「导入」里添加的图片。如需检索相册，请到系统设置里开启照片权限。") {
                Button("去设置开启") { app.openSystemSettings() }
                    .buttonStyle(.bordered)
            }
        case .limited:
            card(icon: "photo.on.rectangle.angled", title: "目前只能访问部分照片",
                 text: "你只授权了 \(app.engine.photoCount) 张照片，搜索也只覆盖这些照片。想检索整个相册，请在系统设置里把照片权限改为「完全访问」。") {
                Button {
                    app.openSystemSettings()
                } label: {
                    Text("去设置改为完全访问").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("只再添加几张照片") { app.presentLimitedLibraryPicker() }
                    .font(.footnote)
            }
        default:
            EmptyView()
        }
    }

    private func card<Actions: View>(icon: String, title: String, text: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            actions()
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - 索引进度

private struct IndexStatusCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let engine = app.engine
        Group {
            phaseView(engine)
            // 索引存不下来时要说清楚，不能显示成"已完成"
            if let problem = engine.storageProblem {
                Label(problem, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if engine.unsavedCount > 0 {
                Label("有 \(engine.unsavedCount) 张图片的索引没能保存，暂时搜不到它们，下次扫描会重试。",
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func phaseView(_ engine: IndexingEngine) -> some View {
        switch engine.phase {
        case .loading, .scanning:
            HStack(spacing: 8) {
                ProgressView()
                Text(engine.isRebuilding ? "正在清空旧索引…" : engine.phase == .loading ? "正在载入索引…" : "正在读取相册…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        case .indexing:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("正在本机建立索引", systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(engine.progressDone) / \(engine.progressTotal)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(engine.progressDone), total: Double(max(engine.progressTotal, 1)))
                Text("识别场景、物体、图中文字和人脸；已完成的部分现在就能搜。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        case .done, .idle:
            if engine.indexedCount > 0 {
                Text("已索引 \(engine.indexedCount) 张图片 · 全部在本机完成")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }
}

// MARK: - 有识别没跑成的提示（如 iOS 模拟器跑不了 Vision 的神经网络模型）

private struct AnalysisNoticeCard: View {
    @Environment(AppModel.self) private var app

    /// 模拟器跑不了 Vision 神经网络模型时的说明；MobileCLIP 能用时，画面内容仍然可以按语义搜
    private var simulatorNote: String {
        app.semanticStatus == .ready
            ? "iOS 模拟器（Apple 芯片的 Mac）跑不了 Apple Vision 的神经网络模型，画面内容目前只靠 MobileCLIP 的画面语义比对来搜。装到 iPhone 真机上，Vision 的画面标签、人脸和二维码检测也会一起用上。"
            : "iOS 模拟器（Apple 芯片的 Mac）跑不了 Apple Vision 的神经网络模型，现在只能按图中文字、日期、截图等检索。装到 iPhone 真机上即可按画面内容（海边、猫、蛋糕…）搜索。"
    }

    var body: some View {
        let names = app.engine.unavailableAnalyses.unavailableAnalysisNames
        if !names.isEmpty {
            let classifierDown = app.engine.classifierUnavailable
            VStack(alignment: .leading, spacing: 6) {
                Label(classifierDown ? "此设备无法运行画面识别模型" : "部分图片没能完成识别",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("没跑成：\(names.joined(separator: "、"))。依赖这些识别的搜索结果可能不全。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(classifierDown ? simulatorNote : "可以在「设置」里点「重新扫描」重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }
}

// MARK: - 空搜索时：建议 & 全部图片

private struct SuggestionsSection: View {
    @Environment(AppModel.self) private var app
    private let examples = ["海边", "猫", "生日蛋糕", "发票", "日落", "美食", "二维码", "截图"]

    var body: some View {
        let _ = app.engine.revision   // 索引更新时刷新热门标签
        let popular = app.engine.topLabels(limit: 10)
        VStack(alignment: .leading, spacing: 10) {
            Text("试试搜").font(.headline)
            FlowLayout {
                ForEach(examples, id: \.self) { word in
                    Button { app.search.query = word } label: { Chip(text: word, systemImage: "magnifyingglass") }
                        .buttonStyle(.plain)
                }
            }
            if !popular.isEmpty {
                Text("你的图片里常见").font(.headline).padding(.top, 4)
                FlowLayout {
                    ForEach(popular, id: \.name) { item in
                        Button { app.search.query = item.name } label: {
                            Chip(text: "\(item.name) \(item.count)", tint: .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

private struct AllPhotosSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ids = app.engine.orderedIDs
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("全部图片 · \(ids.count)").font(.headline).padding(.horizontal)
                PhotoGrid(ids: ids, context: .all)
            }
        }
    }
}

// MARK: - 搜索结果

private struct ResultsSection: View {
    @Environment(AppModel.self) private var app
    /// 「只符合部分条件」的结果默认收起，换一次搜索就重新收起
    @State private var showPartial = false

    var body: some View {
        let search = app.search
        let outcome = search.outcome
        let primary = outcome.primaryHits
        let collapsed = outcome.collapsedHits
        let onlyPartial = outcome.termCount > 1 && outcome.fullMatchCount == 0 && !outcome.hits.isEmpty
        let showAll = search.showsAllHits
        VStack(alignment: .leading, spacing: 10) {
            InterpretationBar()
            HStack(alignment: .firstTextBaseline) {
                if search.isSearching && outcome.query != search.trimmedQuery {
                    ProgressView().controlSize(.small)
                } else if outcome.hits.isEmpty {
                    Text("没有找到相关图片").font(.headline)
                } else if showAll {
                    // 评测模式：全部按得分顺序列出，标题写明用的是哪种检索方式
                    Text(search.effectiveMode == .clipOnly ? "按相似度排列 \(outcome.hits.count) 张" : "找到 \(outcome.hits.count) 张")
                        .font(.headline)
                } else if onlyPartial {
                    Text("没有同时符合全部条件的图片").font(.headline)
                } else {
                    Text("找到 \(primary.count) 张").font(.headline)
                }
                Spacer()
                if showAll {
                    Text(search.effectiveMode.title + (search.importedOnly ? " · 只搜导入的" : " · 全部"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            if showAll {
                let partial = outcome.hits.count - outcome.fullMatchCount
                if outcome.termCount > 1 && partial > 0 && search.effectiveMode != .clipOnly {
                    Text("其中 \(partial) 张只符合部分条件（标有「部分」，排在完全符合的后面）")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else if onlyPartial {
                Text("下面 \(outcome.hits.count) 张只符合部分条件").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if outcome.isLowConfidence {
                Label("没有高置信度的结果，以下图片可能相关", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            if !outcome.incomplete.isEmpty {
                // 区分"没有"和"没检测成"：如 3 张图人脸检测没跑成，搜「合影」时它们不会出现
                Label(outcome.incomplete.map { "\($0.count) 张图片没能完成\($0.name)" }.joined(separator: "，")
                      + "，结果可能不全", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            // 分开说明：没建好索引的、读不出来的，和"检查过但不匹配"是两回事
            if outcome.pendingCount > 0 {
                Label("还有 \(outcome.pendingCount) 张图片没建好索引，没有参与这次检索；建好后结果会自动更新。",
                      systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if outcome.unreadableCount > 0 {
                Label("\(outcome.unreadableCount) 张图片读取失败，没有参与检索（可以在设置里重新扫描）。",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            if showAll {
                // 评测模式：不收起，左上角标出名次和编号（如「3 · IMG_07」），方便记录前 5 张
                let names = app.evalNames()
                let all = outcome.hits
                PhotoGrid(ids: all.map(\.id), context: .results,
                          captions: captions(all, markPartial: outcome.termCount > 1 ? outcome.termCount : nil),
                          badges: Dictionary(all.enumerated().map { i, h in
                              (h.id, names[h.id].map { "\(i + 1) · \($0)" } ?? "\(i + 1)")
                          }, uniquingKeysWith: { a, _ in a }))
            } else {
                PhotoGrid(ids: primary.map(\.id), context: .results, captions: captions(primary))
            }
            if !showAll && !collapsed.isEmpty {
                Button {
                    withAnimation { showPartial.toggle() }
                } label: {
                    Label(showPartial ? "收起只符合部分条件的 \(collapsed.count) 张" : "另有 \(collapsed.count) 张只符合部分条件",
                          systemImage: showPartial ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                }
                .padding(.horizontal)
                if showPartial {
                    PhotoGrid(ids: collapsed.map(\.id), context: .partialResults, captions: captions(collapsed))
                }
            }
        }
        .onChange(of: outcome.query) { showPartial = false }
    }

    /// 缩略图下的说明：每张图最主要的匹配原因。评测模式下只符合部分条件的前面加「部分」
    private func captions(_ hits: [SearchHit], markPartial termCount: Int? = nil) -> [String: String] {
        Dictionary(hits.map { h in
            let reason = h.reasons.first ?? ""
            let partial = termCount.map { h.matchedTerms < $0 } ?? false
            return (h.id, partial ? "部分 · " + reason : reason)
        }, uniquingKeysWith: { a, _ in a })
    }
}

/// 评测模式（第 0 轮对比测试）：切换检索方式和范围，并写明当前用的是哪种。平常不显示
private struct EvalControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var search = app.search
        VStack(alignment: .leading, spacing: 8) {
            Label("评测模式", systemImage: "testtube.2")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Picker("检索方式", selection: $search.mode) {
                ForEach(SearchModel.Mode.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("范围", selection: $search.importedOnly) {
                Text("全部图片").tag(false)
                Text("只搜导入的（\(app.engine.importedCount) 张）").tag(true)   // engine 的计数会随导入刷新界面
            }
            .pickerStyle(.segmented)
            Text("当前：\(search.mode.title)。\(search.mode.explanation)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if search.mode == .clipOnly && app.semanticStatus != .ready {
                Label(app.semanticStatus == .loading ? "MobileCLIP 还在加载，加载好之前这个方式没有结果"
                                                     : "这台设备上 MobileCLIP 不可用，这个方式没有结果",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

/// 展示每个检索词是怎么被理解的（词典 / 近义词 / 翻译 / 文字 / 日期）
private struct InterpretationBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let search = app.search
        let items = search.outcome.interpretations
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items) { item in
                        Chip(text: describe(item), systemImage: icon(item.via), tint: tint(item.via))
                    }
                }
            }
            // 交给 MobileCLIP 的英文描述：让用户知道"画面语义相符"是拿什么比的
            if let prompt = search.outcome.semanticPrompt {
                Label("画面语义比对（MobileCLIP）：\(prompt)", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func describe(_ i: TermInterpretation) -> String {
        let names = i.labelNames.prefix(3).joined(separator: "·")
        switch i.via {
        case .semantic:
            return names.isEmpty ? i.term : "\(i.term) ≈ \(names)（近义词）"
        case .textOnly:
            return i.bySemantic ? "\(i.term)：画面语义 + 图中文字" : "\(i.term)：只匹配图中文字"
        case .date:
            return "\(i.term)：按日期"
        default:
            return names.isEmpty ? i.term : "\(i.term) → \(names)"
        }
    }

    private func icon(_ via: TermInterpretation.Via) -> String {
        switch via {
        case .dictionary: return "character.book.closed"
        case .semantic: return "sparkles"
        case .meta: return "tag"
        case .date: return "calendar"
        case .textOnly: return "text.magnifyingglass"
        }
    }

    private func tint(_ via: TermInterpretation.Via) -> Color {
        switch via {
        case .semantic: return .orange
        case .textOnly: return .gray
        default: return .accentColor
        }
    }
}

// MARK: - 图片网格

struct PhotoGrid: View {
    let ids: [String]
    let context: GridContext
    var captions: [String: String] = [:]
    /// 左上角的标记（评测模式：名次和编号）
    var badges: [String: String] = [:]

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 2)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(ids, id: \.self) { id in
                NavigationLink(value: DetailRoute(context: context, id: id)) {
                    ThumbnailView(id: id, caption: captions[id], badge: badges[id])
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ThumbnailView: View {
    let id: String
    var caption: String?
    /// 左上角的标记，如评测模式下的「3 · IMG_07」
    var badge: String?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(AppModel.self) private var app

    var body: some View {
        let _ = app.engine.revision                        // 索引更新时重新检查版本
        let version = ImageLoader.shared.version(of: id)   // 照片被编辑后版本会变，需要重新加载
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if ImageID.source(of: id) == .imported {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .task(id: "\(id)#\(version)") {
                image = await ImageLoader.shared.thumbnail(for: id, pixelSize: 180 * displayScale)
            }
    }
}
