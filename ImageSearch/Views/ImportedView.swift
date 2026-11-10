import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// App 内导入的图片：从「文件」或系统照片选择器添加，和相册照片一起被检索
struct ImportedView: View {
    @Environment(AppModel.self) private var app
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isImporting = false
    @State private var message: String?
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 2)]

    var body: some View {
        let items = app.importedItems
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有导入图片", systemImage: "photo.badge.plus")
                    } description: {
                        Text("从「文件」或相册导入的图片会复制到本 App 中，同样会在本机建立索引，可以和相册照片一起用关键词检索。")
                            + Text(message.map { "\n\n\($0)" } ?? "")
                            + Text(app.search.evalMode ? "\n\n" + Self.evalHint : "")
                    } actions: {
                        importMenu(label: Label("导入图片", systemImage: "plus"))
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        if app.engine.phase == .indexing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在本机建立索引 \(app.engine.progressDone)/\(app.engine.progressTotal)")
                            }
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                                .padding(.horizontal).padding(.top, 6)
                        }
                        if app.search.evalMode {
                            Text(Self.evalHint).font(.footnote).foregroundStyle(.orange)
                                .padding(.horizontal).padding(.top, 6)
                        }
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(items) { item in
                                cell(item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("导入的图片")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    importMenu(label: Image(systemName: "plus"))
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isSelecting ? "完成" : "选择") {
                            isSelecting.toggle()
                            selection.removeAll()
                        }
                    }
                }
                if isSelecting {
                    ToolbarItem(placement: .bottomBar) {
                        Button("删除 \(selection.count) 张", role: .destructive) { confirmDelete = true }
                            .disabled(selection.isEmpty)
                    }
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("正在导入…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .confirmationDialog("从本 App 中删除 \(selection.count) 张导入的图片？", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) { deleteSelection() }
            } message: {
                Text("只删除 App 内的副本，不影响原文件和系统相册。")
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await importFiles(urls) } }
            }
            // 评测模式下选择器给选中的图标上 1、2、3 …，导入后按这个顺序编号
            .photosPicker(isPresented: $showPhotosPicker, selection: $pickerItems, maxSelectionCount: 50,
                          selectionBehavior: app.search.evalMode ? .ordered : .default,
                          matching: .images, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await importPicked(newItems) }
            }
            .navigationDestination(for: DetailRoute.self) { PhotoDetailView(route: $0) }
        }
    }

    private func importMenu<L: View>(label: L) -> some View {
        Menu {
            Button { showFileImporter = true } label: { Label("从「文件」导入", systemImage: "folder") }
            Button { showPhotosPicker = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
        } label: { label }
    }

    @ViewBuilder
    private func cell(_ item: ImportedImageStore.Item) -> some View {
        if isSelecting {
            ThumbnailView(id: item.id, badge: badge(item))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white, selection.contains(item.id) ? Color.accentColor : .black.opacity(0.3))
                        .padding(6)
                }
                .onTapGesture {
                    if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                }
        } else {
            NavigationLink(value: DetailRoute(context: .imported, id: item.id)) {
                ThumbnailView(id: item.id, badge: badge(item))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    deleteItems([item.id])
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    private static let evalHint = "评测模式：按文件名排列。从「文件」导入时保留原来的文件名；从相册选择时，原文件名已经是 IMG_07 这样的编号就沿用，其余按点选的顺序编号。"

    /// 评测模式下缩略图左上角显示导入时的文件名（IMG_07）
    private func badge(_ item: ImportedImageStore.Item) -> String? {
        app.search.evalMode ? ImportedImageStore.displayStem(of: item.originalName) : nil
    }

    private func importFiles(_ urls: [URL]) async {
        isImporting = true
        let result = await app.imports.importFiles(urls)
        isImporting = false
        message = describe(result)
        if result.imported > 0 { app.engine.scheduleRescan() }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        isImporting = true
        // 评测模式：先按选择顺序分好编号（选中的第 n 张拿第 n 个空闲编号）。某张读不出来时只空出它的编号，后面的不跟着错位
        // 照片在相册里的原文件名（需要相册权限；拿不到时为 nil，按顺序编号）
        let evalNames = app.search.evalMode
            ? ImportedImageStore.evalNames(
                originalNames: items.map { $0.itemIdentifier.flatMap(PhotoLibraryService.originalFileName(localIdentifier:)) },
                existingNames: app.imports.items.map(\.originalName))
            : nil
        var payloads: [(data: Data, suggestedName: String, ext: String)] = []
        var unreadable = 0
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                unreadable += 1
                continue
            }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
            let ext = type?.preferredFilenameExtension ?? "jpg"
            payloads.append((data, (evalNames?[i] ?? "相册图片") + ".\(ext)", ext))
        }
        var result = await app.imports.importData(payloads)
        result.failed += unreadable
        pickerItems = []
        isImporting = false
        message = describe(result) + (evalNames.map(evalSummary) ?? "")
        if result.imported > 0 { app.engine.scheduleRescan() }
    }

    /// 评测模式：这批图拿到了哪些编号、哪些没导入成功，以及有没有重名
    private func evalSummary(_ expected: [String]) -> String {
        let stems = app.imports.items.map { ImportedImageStore.displayStem(of: $0.originalName) }
        let present = Set(stems)
        let byNumber: (String, String) -> Bool = {
            (ImportedImageStore.evalNumber(in: $0) ?? 0) < (ImportedImageStore.evalNumber(in: $1) ?? 0)
        }
        let ok = expected.filter(present.contains).sorted(by: byNumber)
        let missing = expected.filter { !present.contains($0) }.sorted(by: byNumber)
        let duplicated = Set(expected).filter { name in stems.filter { $0 == name }.count > 1 }.sorted(by: byNumber)
        var parts: [String] = []
        if !ok.isEmpty { parts.append("编号 " + Self.list(ok)) }
        if !missing.isEmpty {
            parts.append("没导入成功的编号：" + missing.joined(separator: "、") + "（重新选这几张导入，会补上这些编号）")
        }
        if !duplicated.isEmpty {
            parts.append(duplicated.joined(separator: "、") + " 现在有不止一张，可以在「选择」里删掉多余的")
        }
        return parts.isEmpty ? "" : "。" + parts.joined(separator: "；")
    }

    /// 连续的编号写成「IMG_01–IMG_40」，否则逐个列出
    private static func list(_ names: [String]) -> String {
        let nums = names.compactMap(ImportedImageStore.evalNumber(in:))
        if names.count > 2, nums.count == names.count, zip(nums, nums.dropFirst()).allSatisfy({ $1 == $0 + 1 }) {
            return "\(names[0])–\(names[names.count - 1])"
        }
        return names.joined(separator: "、")
    }

    /// 成功和失败分开说，失败时带上原因
    private func describe(_ r: ImportedImageStore.ImportResult) -> String {
        var parts: [String] = []
        if r.imported > 0 { parts.append("已导入 \(r.imported) 张，可以去「搜索」里按关键词找到它们") }
        if r.failed > 0 { parts.append("\(r.failed) 张没能导入" + (r.errorMessage.map { "（\($0)）" } ?? "")) }
        return parts.isEmpty ? "没有导入任何图片" : parts.joined(separator: "；")
    }

    private func deleteSelection() {
        deleteItems(selection)
        selection.removeAll()
        isSelecting = false
    }

    /// 删除失败（清单写不进去）时什么都没删，如实告诉用户
    private func deleteItems(_ ids: Set<String>) {
        do {
            try app.imports.delete(ids: ids)
            message = nil
            app.engine.scheduleRescan()
        } catch {
            message = "删除失败，图片都还在：\(error.localizedDescription)"
        }
    }
}
