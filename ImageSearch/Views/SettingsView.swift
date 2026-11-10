import SwiftUI
import Photos

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRebuild = false

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
                            Text("正在建立索引 \(engine.progressDone)/\(engine.progressTotal)").font(.footnote)
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
                    Text("新拍的照片、编辑或删除照片都会自动增量更新索引。")
                }

                Section {
                    Text("内置中英词典覆盖 Apple Vision 全部 1303 类识别结果的常用中文说法（含常见猫狗品种）。词典里没有的词，会用 iOS 自带的离线词向量找近义词（如「喵星人」→ 猫），并在图中文字里查找。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("关键词识别")
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
