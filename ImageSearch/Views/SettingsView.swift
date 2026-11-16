import SwiftUI
import Photos

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRebuild = false
    /// 实验项：默认值和 MobileCLIP / ImageAnalyzer 里读的默认值一致
    @AppStorage(MobileCLIP.imageConcurrencyKey) private var clipConcurrency = 1
    @AppStorage(ImageAnalyzer.textFastGateKey) private var textFastGate = false
    @AppStorage(IndexingEngine.skipSmallPreviewEmbeddingKey) private var skipSmallEmbedding = false

    var body: some View {
        let engine = app.engine
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("完全离线运行").font(.headline)
                            Text("图搜不联网，也不包含任何网络请求代码。场景/物体识别、图中文字识别、人脸与二维码检测、画面语义比对（App 内置的 MobileCLIP 模型）、建立索引和搜索，全部在这台 iPhone 上完成，开着飞行模式也能正常使用。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                    }
                }

                Section {
                    HStack {
                        Text("访问权限")
                        Spacer()
                        Text(statusText(app.photoStatus)).foregroundStyle(.secondary)
                    }
                    switch app.photoStatus {
                    case .notDetermined:
                        Button("允许访问照片") { Task { await app.requestPhotoAccess() } }
                    case .limited:
                        Text("目前只能搜索你选中的照片。改为「完全访问」后会自动为整个相册建立索引。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("去设置改为完全访问") { app.openSystemSettings() }
                        Button("只再添加几张照片") { app.presentLimitedLibraryPicker() }
                    case .denied, .restricted:
                        Button("在系统设置中开启") { app.openSystemSettings() }
                    default:
                        EmptyView()
                    }
                } header: {
                    Text("相册")
                } footer: {
                    Text("如果开启了「优化 iPhone 储存空间」，原图只在 iCloud 的照片会用本机保存的预览图来识别，不会联网下载原图。")
                }

                Section {
                    stat("相册照片", engine.photoCount)
                    stat("导入的图片", engine.importedCount)
                    stat("已建立索引", engine.indexedCount)
                    if engine.failedCount > 0 { stat("暂时无法分析", engine.failedCount) }
                    if engine.unsavedCount > 0 { stat("索引没能保存（下次扫描重试）", engine.unsavedCount) }
                    if engine.textPendingCount > 0 { stat("图中文字还没识别", engine.textPendingCount) }
                    if engine.smallPreviewCount > 0 { stat("只拿到小预览图的照片", engine.smallPreviewCount) }
                    HStack {
                        Text("画面语义（MobileCLIP-S2）")
                        Spacer()
                        switch app.semanticStatus {
                        case .loading: Text("正在加载模型…").foregroundStyle(.secondary)
                        case .ready: Text("\(engine.embeddedCount) / \(engine.indexedCount) 张").foregroundStyle(.secondary)
                        case .unavailable: Text("模型未安装").foregroundStyle(.orange)
                        }
                    }
                    if let problem = engine.storageProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(engine.unavailableAnalyses.unavailableAnalysisNames, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            #if targetEnvironment(simulator)
                            Text("不可用（模拟器限制）").foregroundStyle(.orange)
                            #else
                            Text("部分图片未完成").foregroundStyle(.orange)
                            #endif
                        }
                    }
                    if engine.phase == .indexing {
                        ProgressView(value: Double(engine.progressDone), total: Double(max(engine.progressTotal, 1))) {
                            Text("\(engine.currentPass.map { $0 == .single ? "正在建立索引" : $0.title } ?? "正在建立索引") \(engine.progressDone)/\(engine.progressTotal)")
                                .font(.footnote)
                        }
                    }
                    Button("重新扫描") { engine.scheduleRescan(retryFailed: true) }
                        .disabled(engine.isBusy)
                    Button("重建全部索引", role: .destructive) { confirmRebuild = true }
                        .disabled(engine.isBusy)
                    if let err = engine.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("索引")
                } footer: {
                    Text("新拍的照片、编辑或删除照片都会自动增量更新索引。建索引时先识别画面，做完整个相册就能按画面搜；图中文字同时在识别，跟不上的随后补上。建索引时屏幕保持常亮，因为锁屏后 App 会被系统暂停。「只拿到小预览图的照片」是原图不在这台 iPhone 上（多半在 iCloud）、系统只给了很小预览图的照片：图搜不联网下载原图，这些照片画面识别不准，也认不出图中文字。照片下载到本机后，点「重新扫描」会重新识别。")
                }

                if !engine.lastPassStats.isEmpty {
                    Section {
                        ForEach(engine.lastPassStats.indices, id: \.self) { i in
                            let s = engine.lastPassStats[i]
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.pass.title)
                                    Spacer()
                                    Text(s.summary).foregroundStyle(.secondary)
                                }
                                Text(s.details).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("最近一次建索引的耗时")
                    } footer: {
                        Text("只统计 \(IndexingEngine.minImagesForStats) 张以上的建索引，只保存到 App 关闭为止。单张各步骤的时间是每张图在这一步上花的时间；几张图同时处理，所以平均每张的总时间比各步骤加起来短。")
                    }
                }

                Section {
                    Text("内置中英词典覆盖 Apple Vision 全部 1303 类识别结果的常用中文说法（含常见猫狗品种）。词典里没有的词，会用 iOS 自带的离线词向量找近义词（如「喵星人」→ 猫），并在图中文字里查找。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("关键词识别")
                }

                Section {
                    HStack {
                        Text("系统翻译")
                        Spacer()
                        switch app.translator.status {
                        case .ready: Text("可用").foregroundStyle(.secondary)
                        case .notInstalled: Text("翻译语言未下载").foregroundStyle(.orange)
                        case .unsupported:
                            #if targetEnvironment(simulator)
                            Text("不可用（模拟器限制）").foregroundStyle(.orange)
                            #else
                            Text("需要 iOS 18 或更新的系统").foregroundStyle(.orange)
                            #endif
                        }
                    }
                    Toggle("整句翻译中文查询", isOn: Bindable(app.translator).isEnabled)
                        .disabled(app.translator.status != .ready)
                } header: {
                    Text("中文查询的翻译")
                } footer: {
                    Text("MobileCLIP 只认英文。打开后，中文查询先由 iOS 自带的翻译整句译成英文，再去比对画面；翻译在这台 iPhone 上完成，不联网。这需要系统里已经下载好「中文（简体）」和「英语」两种翻译语言，可以在系统自带的「翻译」App 里下载。图搜自己不会下载；没有下载、或者关掉这个开关时，照旧逐词翻译。")
                }

                if app.search.evalMode {
                    Section {
                        Toggle("先识别画面，再识别文字", isOn: Bindable(engine).textInSecondPass)
                            .disabled(engine.isBusy)
                    } header: {
                        Text("建索引方式（评测用）")
                    } footer: {
                        Text("打开（默认）：先识别画面，做完整个相册就能按画面搜；图中文字同时识别，跟不上的随后补上。关掉：回到原来一张图一次做完全部识别的方式。改了以后点「重建全部索引」，在「最近一次建索引的耗时」里就能对比两种方式。")
                    }

                    Section {
                        Picker("每次扫描最多分析", selection: Bindable(engine).indexLimit) {
                            Text("全部").tag(0)
                            ForEach([100, 200, 500, 1000, 2000], id: \.self) { n in Text("\(n) 张").tag(n) }
                        }
                        Toggle("跳过文字识别", isOn: Bindable(engine).skipTextRecognition)
                        Picker("MobileCLIP 并发", selection: $clipConcurrency) {
                            Text("1 张（默认）").tag(1)
                            Text("2 张").tag(2)
                            Text("4 张").tag(4)
                        }
                        Toggle("小预览图先不建语义向量", isOn: $skipSmallEmbedding)
                        Toggle("文字识别先用快速模式探路", isOn: $textFastGate)
                    } header: {
                        Text("建索引实验（开发用）")
                    } footer: {
                        Text("「每次扫描最多分析」只做前 N 张新图，其余的留到下次扫描（不会删记录），适合开发时快速看到结果；想看全部就选「全部」再点「重新扫描」。打开「跳过文字识别」后，图片会标成文字待识别，搜索会如实提示结果不全，但建索引快很多。「MobileCLIP 并发」和「快速模式探路」都是实验项，重开 App 生效：并发解决的是第一步里 CLIP 只能一张一张算的问题；探路解决的是没有字的照片也要跑一遍慢识别的问题，开启后请确认漏字的比例可以接受。「小预览图先不建语义向量」针对原图只在 iCloud、系统只给很小预览图的照片：它们本来画面识别就不准，先跳过 CLIP 能明显缩短第一步，代价是这些图暂时不能按画面语义搜到，搜索会提示有多少张没比对；原图下载到本机后点「重新扫描」会补上。关掉评测模式会把这些实验开关恢复成默认。")
                    }
                }

                Section {
                    Toggle("评测模式", isOn: Bindable(app.search).evalMode)
                } header: {
                    Text("测试")
                } footer: {
                    Text("给对比测试用，平常不需要打开。打开后：搜索页出现「检索方式」（融合 / 只用 Vision / 只用 MobileCLIP）和「范围」（全部 / 只搜导入的图片）两组切换；结果按得分顺序全部列出，不再收起只符合部分条件的；缩略图标出名次和导入时的文件名；从相册导入的图片，原文件名已经是 IMG_07 这样的编号就沿用，其余按选择顺序命名为 IMG_01、IMG_02 …。关掉后恢复平常的搜索方式。")
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("快捷方式：在快捷指令中打开 tusou://search?q=关键词 可直接搜索。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("清空并重建全部索引？", isPresented: $confirmRebuild, titleVisibility: .visible) {
                Button("重建", role: .destructive) { Task { await engine.rebuildAll() } }
            } message: {
                Text("需要重新分析所有图片，照片多时会花一些时间。")
            }
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(value)").monospacedDigit().foregroundStyle(.secondary) }
    }

    private func statusText(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "全部照片"
        case .limited: return "部分照片"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
        }
    }
}
