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
        let items = app.imports.items
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有导入图片", systemImage: "photo.badge.plus")
                    } description: {
                        Text("从「文件」或相册导入的图片会复制到本 App 中，同样会在本机建立索引，可以和相册照片一起用关键词检索。")
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
                        } else if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
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
            .photosPicker(isPresented: $showPhotosPicker, selection: $pickerItems, maxSelectionCount: 50,
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
            ThumbnailView(id: item.id)
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
                ThumbnailView(id: item.id)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    app.imports.delete(ids: [item.id])
                    app.engine.scheduleRescan()
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        isImporting = true
        let n = await app.imports.importFiles(urls)
        isImporting = false
        message = n > 0 ? "已导入 \(n) 张，可以去「搜索」里按关键词找到它们" : "没有导入任何图片"
        app.engine.scheduleRescan()
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        isImporting = true
        var payloads: [(data: Data, suggestedName: String, ext: String)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
            let ext = type?.preferredFilenameExtension ?? "jpg"
            payloads.append((data, "相册图片.\(ext)", ext))
        }
        let n = await app.imports.importData(payloads)
        pickerItems = []
        isImporting = false
        message = n > 0 ? "已导入 \(n) 张，可以去「搜索」里按关键词找到它们" : "没有导入任何图片"
        app.engine.scheduleRescan()
    }

    private func deleteSelection() {
        app.imports.delete(ids: selection)
        selection.removeAll()
        isSelecting = false
        app.engine.scheduleRescan()
    }
}
