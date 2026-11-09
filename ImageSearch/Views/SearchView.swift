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
                 text: "请在弹窗中选择「允许完全访问」，这样才能搜索整个相册。照片只在这台 iPhone 上用 Apple Vision 分析，不会上传。") {
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
        switch engine.phase {
        case .loading, .scanning:
            HStack(spacing: 8) {
                ProgressView()
                Text(engine.phase == .loading ? "正在载入索引…" : "正在读取相册…")
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
                Text(classifierDown
                     ? "iOS 模拟器（Apple 芯片的 Mac）跑不了 Apple Vision 的神经网络模型，现在只能按图中文字、日期、截图等检索。装到 iPhone 真机上即可按画面内容（海边、猫、蛋糕…）搜索。"
                     : "可以在「设置」里点「重新扫描」重试。")
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

    var body: some View {
        let search = app.search
        let outcome = search.outcome
        VStack(alignment: .leading, spacing: 10) {
            InterpretationBar()
            HStack(alignment: .firstTextBaseline) {
                if search.isSearching && outcome.query != search.trimmedQuery {
                    ProgressView().controlSize(.small)
                } else if outcome.hits.isEmpty {
                    Text("没有找到相关图片").font(.headline)
                } else {
                    Text("找到 \(outcome.hits.count) 张").font(.headline)
                    if outcome.termCount > 1 {
                        Text("其中 \(outcome.fullMatchCount) 张完全匹配").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)

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
            if outcome.hits.isEmpty && !search.isSearching && app.engine.isBusy {
                Text("索引还在建立中，稍后结果会自动更新。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            PhotoGrid(ids: outcome.hits.map(\.id), context: .results,
                      captions: Dictionary(outcome.hits.map { ($0.id, $0.reasons.first ?? "") },
                                           uniquingKeysWith: { a, _ in a }))
        }
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
        }
        .padding(.horizontal)
    }

    private func describe(_ i: TermInterpretation) -> String {
        let names = i.labelNames.prefix(3).joined(separator: "·")
        switch i.via {
        case .semantic:
            return names.isEmpty ? i.term : "\(i.term) ≈ \(names)（近义词）"
        case .textOnly:
            return "\(i.term)：只匹配图中文字"
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

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 2)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(ids, id: \.self) { id in
                NavigationLink(value: DetailRoute(context: context, id: id)) {
                    ThumbnailView(id: id, caption: captions[id])
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ThumbnailView: View {
    let id: String
    var caption: String?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
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
            .task(id: id) {
                image = await ImageLoader.shared.thumbnail(for: id, pixelSize: 180 * displayScale)
            }
    }
}
