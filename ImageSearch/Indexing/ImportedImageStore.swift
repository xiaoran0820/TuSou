import Foundation
import UniformTypeIdentifiers

/// App 内导入的图片：复制到 App 自己的沙盒目录里管理（不需要相册权限）
@MainActor
final class ImportedImageStore: ObservableObject {
    struct Item: Codable, Identifiable, Hashable, Sendable {
        let fileName: String          // 沙盒里的文件名（UUID.扩展名）
        let originalName: String
        let importedAt: Date
        let creationDate: Date?       // EXIF 拍摄时间
        let pixelWidth: Int
        let pixelHeight: Int
        var id: String { ImageID.imported(fileName) }
    }

    @Published private(set) var items: [Item] = []   // 按导入时间倒序

    nonisolated let directory: URL
    private let manifestURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Imported", isDirectory: true)
        manifestURL = base.appendingPathComponent("imported.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([Item].self, from: data) {
            // 丢弃文件已不存在的条目
            items = list.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
        }
    }

    nonisolated func fileURL(forFileName name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func item(for id: String) -> Item? { items.first { $0.id == id } }

    /// 从「文件」App 等处导入（fileImporter 返回的 URL 需要安全作用域访问）
    func importFiles(_ urls: [URL]) async -> Int {
        let dir = directory
        let newItems: [Item] = await Task.detached(priority: .userInitiated) {
            var out: [Item] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { continue }
                let ext = url.pathExtension.lowercased()
                let name = UUID().uuidString + "." + (ext.isEmpty ? "jpg" : ext)
                let dest = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    let info = ImageAnalyzer.fileInfo(at: dest)
                    guard info.width > 0 else { try? FileManager.default.removeItem(at: dest); continue }
                    out.append(Item(fileName: name, originalName: url.lastPathComponent, importedAt: Date(),
                                    creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height))
                } catch {
                    continue
                }
            }
            return out
        }.value
        add(newItems)
        return newItems.count
    }

    /// 从系统照片选择器导入（数据已由 PhotosPicker 读出）
    func importData(_ payloads: [(data: Data, suggestedName: String, ext: String)]) async -> Int {
        let dir = directory
        let newItems: [Item] = await Task.detached(priority: .userInitiated) {
            var out: [Item] = []
            for p in payloads {
                let name = UUID().uuidString + "." + p.ext
                let dest = dir.appendingPathComponent(name)
                guard (try? p.data.write(to: dest, options: .atomic)) != nil else { continue }
                let info = ImageAnalyzer.fileInfo(at: dest)
                guard info.width > 0 else { try? FileManager.default.removeItem(at: dest); continue }
                out.append(Item(fileName: name, originalName: p.suggestedName, importedAt: Date(),
                                creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height))
            }
            return out
        }.value
        add(newItems)
        return newItems.count
    }

    func delete(ids: Set<String>) {
        for item in items where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: fileURL(forFileName: item.fileName))
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    private func add(_ newItems: [Item]) {
        guard !newItems.isEmpty else { return }
        items.insert(contentsOf: newItems, at: 0)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    func meta(for item: Item) -> ImageMeta {
        ImageMeta(creationDate: item.creationDate ?? item.importedAt, fileName: item.originalName)
    }
}
