import Foundation
import UniformTypeIdentifiers

/// App 内导入的图片：复制到 App 自己的沙盒目录里管理（不需要相册权限）。
///
/// 清单（imported.json）是"哪些图片已导入"的唯一依据：
/// - 导入：先复制文件，再写清单；清单写不进去就删掉刚复制的文件，并报告失败。
/// - 删除：先写清单，成功后再删文件；清单写不进去就什么都不删，并抛出错误。
/// - 启动：清单读取成功时，删掉不在清单里的文件（中途失败留下的孤儿）；
///   清单读不出来（损坏或丢失）时一个文件都不删，而是把现有图片重新登记，避免丢掉用户的图片。
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

    /// 一次导入的结果
    struct ImportResult: Sendable, Equatable {
        var imported = 0
        var failed = 0
        var errorMessage: String?
    }

    enum StoreError: LocalizedError {
        case manifestWriteFailed(String)
        var errorDescription: String? {
            switch self {
            case .manifestWriteFailed(let m): return "导入清单保存失败：\(m)"
            }
        }
    }

    @Published private(set) var items: [Item] = []   // 按导入时间倒序

    nonisolated let directory: URL
    private let manifestURL: URL

    init(baseDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        directory = baseDirectory.appendingPathComponent("Imported", isDirectory: true)
        manifestURL = baseDirectory.appendingPathComponent("imported.json")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }

        if let data = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([Item].self, from: data) {
            // 丢掉文件已不存在的条目；删掉不在清单里的文件（导入或删除中途失败留下的）
            let present = Set(files)
            items = list.filter { present.contains($0.fileName) }
            let known = Set(items.map(\.fileName))
            for f in files where !known.contains(f) {
                try? fm.removeItem(at: directory.appendingPathComponent(f))
            }
            if items.count != list.count { try? writeManifest(items) }
        } else {
            // 清单不存在或读不出来：不删任何文件，把现有图片重新登记
            if fm.fileExists(atPath: manifestURL.path) {
                let backup = manifestURL.appendingPathExtension("corrupt")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: manifestURL, to: backup)
            }
            items = files.compactMap { Self.recoveredItem(fileName: $0, in: directory) }
                .sorted { $0.importedAt > $1.importedAt }
            if !items.isEmpty { try? writeManifest(items) }
        }
    }

    nonisolated func fileURL(forFileName name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func item(for id: String) -> Item? { items.first { $0.id == id } }

    /// 从「文件」App 等处导入（fileImporter 返回的 URL 需要安全作用域访问）
    func importFiles(_ urls: [URL]) async -> ImportResult {
        let dir = directory
        let (newItems, failed): ([Item], Int) = await Task.detached(priority: .userInitiated) {
            var out: [Item] = []
            var failed = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
                    failed += 1
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let name = UUID().uuidString + "." + (ext.isEmpty ? "jpg" : ext)
                let dest = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    let info = ImageAnalyzer.fileInfo(at: dest)
                    guard info.width > 0 else {
                        try? FileManager.default.removeItem(at: dest)
                        failed += 1
                        continue
                    }
                    out.append(Item(fileName: name, originalName: url.lastPathComponent, importedAt: Date(),
                                    creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height))
                } catch {
                    failed += 1
                }
            }
            return (out, failed)
        }.value
        return commit(newItems, failed: failed)
    }

    /// 从系统照片选择器导入（数据已由 PhotosPicker 读出）
    func importData(_ payloads: [(data: Data, suggestedName: String, ext: String)]) async -> ImportResult {
        let dir = directory
        let (newItems, failed): ([Item], Int) = await Task.detached(priority: .userInitiated) {
            var out: [Item] = []
            var failed = 0
            for p in payloads {
                let name = UUID().uuidString + "." + p.ext
                let dest = dir.appendingPathComponent(name)
                guard (try? p.data.write(to: dest, options: .atomic)) != nil else {
                    failed += 1
                    continue
                }
                let info = ImageAnalyzer.fileInfo(at: dest)
                guard info.width > 0 else {
                    try? FileManager.default.removeItem(at: dest)
                    failed += 1
                    continue
                }
                out.append(Item(fileName: name, originalName: p.suggestedName, importedAt: Date(),
                                creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height))
            }
            return (out, failed)
        }.value
        return commit(newItems, failed: failed)
    }

    /// 删除导入的图片：先写清单，成功后再删文件。清单写不进去就什么都不删，并抛出错误
    func delete(ids: Set<String>) throws {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let remaining = items.filter { !ids.contains($0.id) }
        try writeManifest(remaining)
        items = remaining
        for item in removed {
            // 删文件失败也不要紧：清单里已经没有它，下次启动会当作孤儿文件清理
            try? FileManager.default.removeItem(at: fileURL(forFileName: item.fileName))
        }
    }

    func meta(for item: Item) -> ImageMeta {
        ImageMeta(creationDate: item.creationDate ?? item.importedAt, fileName: item.originalName)
    }

    // MARK: - 评测编号（第 0 轮）

    /// 评测模式下从相册选择器导入的图片，按选择顺序命名为 IMG_01、IMG_02 …：
    /// 依次取还没被占用的最小编号（删掉 IMG_07 再导入一张，新图就是 IMG_07；没有空缺时接着往后编）
    nonisolated static func evalNames(count: Int, existingNames: [String]) -> [String] {
        let used = Set(existingNames.compactMap(evalNumber(in:)))
        var out: [String] = []
        var n = 1
        while out.count < count {
            if !used.contains(n) { out.append(String(format: "IMG_%02d", n)) }
            n += 1
        }
        return out
    }

    /// 评测模式下从相册导入一批图的名字：照片原来的文件名已经是测试编号（比如在 Mac 上改好名、隔空投送进相册的 IMG_07.JPG）就沿用；
    /// 其余的按选择顺序，取没被占用（包括这一批沿用的）的最小编号
    nonisolated static func evalNames(originalNames: [String?], existingNames: [String]) -> [String] {
        let kept = originalNames.map { name in name.flatMap { evalNumber(in: $0) != nil ? displayStem(of: $0) : nil } }
        var fresh = evalNames(count: kept.filter { $0 == nil }.count,
                              existingNames: existingNames + kept.compactMap { $0 }).makeIterator()
        return kept.map { $0 ?? fresh.next() ?? "" }
    }

    /// IMG_07.jpg → 7。只认 2～3 位数字，iPhone 相机自己的 IMG_1234.HEIC 不算评测编号
    nonisolated static func evalNumber(in name: String) -> Int? {
        let stem = displayStem(of: name)
        guard stem.hasPrefix("IMG_") else { return nil }
        let digits = stem.dropFirst(4)
        guard (2...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// 缩略图上显示的名字：去掉扩展名（IMG_07.jpg → IMG_07）
    nonisolated static func displayStem(of name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    // MARK: - 清单

    /// 把新复制进来的文件登记进清单；清单写不进去就删掉这些文件，整批算失败
    private func commit(_ newItems: [Item], failed: Int) -> ImportResult {
        var result = ImportResult(imported: 0, failed: failed)
        guard !newItems.isEmpty else { return result }
        let updated = newItems + items
        do {
            try writeManifest(updated)
            items = updated
            result.imported = newItems.count
        } catch {
            for item in newItems { try? FileManager.default.removeItem(at: fileURL(forFileName: item.fileName)) }
            result.failed += newItems.count
            result.errorMessage = error.localizedDescription
        }
        return result
    }

    private func writeManifest(_ list: [Item]) throws {
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw StoreError.manifestWriteFailed(error.localizedDescription)
        }
    }

    /// 清单丢失时，根据文件本身重新登记（原始文件名已不可知，用沙盒文件名代替）
    private nonisolated static func recoveredItem(fileName: String, in dir: URL) -> Item? {
        let url = dir.appendingPathComponent(fileName)
        let info = ImageAnalyzer.fileInfo(at: url)
        guard info.width > 0 else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let importedAt = (attrs?[.creationDate] as? Date) ?? Date()
        return Item(fileName: fileName, originalName: fileName, importedAt: importedAt,
                    creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height)
    }
}
