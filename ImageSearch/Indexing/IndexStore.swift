import Accelerate
import Foundation
import SQLite3

/// 索引的持久化接口。默认实现是下面的 SQLite `IndexStore`；测试时换成会出错的实现，验证故障时的行为。
/// 约定：方法抛错就表示这次写入/删除没有生效（已回滚）。
protocol IndexPersistence: Sendable {
    func loadAll() async throws -> [ImageRecord]
    func upsert(_ records: [ImageRecord]) async throws
    func delete(ids: [String]) async throws
    func deleteAll() async throws
}

/// 索引持久化：系统自带 SQLite（不依赖第三方库）。
/// 所有读写都在这个 actor 里串行执行。
actor IndexStore: IndexPersistence {
    enum StoreError: Error, LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            if case .sqlite(let m) = self { return "数据库错误：\(m)" }
            return nil
        }
    }

    private var db: OpaquePointer?
    private let url: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(msg)
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY,
                source INTEGER NOT NULL,
                mod_date REAL,
                labels TEXT NOT NULL,
                ocr TEXT NOT NULL,
                faces INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                version INTEGER NOT NULL,
                indexed_at REAL NOT NULL,
                clip BLOB,
                clip_model TEXT
            );
            """)
        // 旧版本的数据库没有 MobileCLIP 向量的两列：补上（原有数据不动）
        let columns = try Self.columnNames(handle)
        if !columns.contains("clip") { try Self.exec(handle, "ALTER TABLE images ADD COLUMN clip BLOB") }
        if !columns.contains("clip_model") { try Self.exec(handle, "ALTER TABLE images ADD COLUMN clip_model TEXT") }
    }

    deinit { sqlite3_close(db) }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Index", isDirectory: true).appendingPathComponent("index.sqlite")
    }

    // MARK: - 读

    func loadAll() throws -> [ImageRecord] {
        let sql = "SELECT id, source, mod_date, labels, ocr, faces, flags, width, height, version, indexed_at, clip, clip_model FROM images"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        var out: [ImageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let source = ImageSourceKind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .photoLibrary
            let mod: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let labels = Self.decodeLabels(String(cString: sqlite3_column_text(stmt, 3)))
            let ocr = String(cString: sqlite3_column_text(stmt, 4))
            out.append(ImageRecord(
                id: id, source: source, sourceModificationDate: mod, labels: labels, ocrText: ocr,
                faceCount: Int(sqlite3_column_int(stmt, 5)),
                flags: RecordFlags(rawValue: Int(sqlite3_column_int(stmt, 6))),
                pixelWidth: Int(sqlite3_column_int(stmt, 7)), pixelHeight: Int(sqlite3_column_int(stmt, 8)),
                analyzerVersion: Int(sqlite3_column_int(stmt, 9)),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
                clipEmbedding: Self.blob(stmt, 11).map(Self.decodeEmbedding),
                clipModel: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 12))))
        }
        return out
    }

    // MARK: - 写

    func upsert(_ records: [ImageRecord]) throws {
        guard !records.isEmpty else { return }
        let sql = """
            INSERT OR REPLACE INTO images (id, source, mod_date, labels, ocr, faces, flags, width, height, version, indexed_at, clip, clip_model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        try transaction {
            try withStatement(sql) { stmt in
                for r in records {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, r.id, -1, Self.transient)
                    sqlite3_bind_int(stmt, 2, Int32(r.source.rawValue))
                    if let d = r.sourceModificationDate { sqlite3_bind_double(stmt, 3, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 3) }
                    sqlite3_bind_text(stmt, 4, Self.encodeLabels(r.labels), -1, Self.transient)
                    sqlite3_bind_text(stmt, 5, r.ocrText, -1, Self.transient)
                    sqlite3_bind_int(stmt, 6, Int32(r.faceCount))
                    sqlite3_bind_int(stmt, 7, Int32(r.flags.rawValue))
                    sqlite3_bind_int(stmt, 8, Int32(r.pixelWidth))
                    sqlite3_bind_int(stmt, 9, Int32(r.pixelHeight))
                    sqlite3_bind_int(stmt, 10, Int32(r.analyzerVersion))
                    sqlite3_bind_double(stmt, 11, r.indexedAt.timeIntervalSince1970)
                    if let e = r.clipEmbedding {
                        let data = Self.encodeEmbedding(e)
                        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 12, $0.baseAddress, Int32(data.count), Self.transient) }
                    } else {
                        sqlite3_bind_null(stmt, 12)
                    }
                    if let m = r.clipModel { sqlite3_bind_text(stmt, 13, m, -1, Self.transient) } else { sqlite3_bind_null(stmt, 13) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
                }
            }
        }
    }

    /// 删除若干条记录：任何一条没删成就整体回滚并报错（不会"看起来删了，其实还在"）
    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            try withStatement("DELETE FROM images WHERE id = ?") { stmt in
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, id, -1, Self.transient)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
                }
            }
        }
    }

    func deleteAll() throws {
        try transaction { try Self.exec(db, "DELETE FROM images") }
    }

    /// 测试用：开启后插入和删除语句在执行时失败（事务本身能开始），模拟写到一半出错的情况。
    /// 用的是只存在于当前连接的临时触发器，不会写进数据库文件。
    func setSimulatedWriteFailure(_ on: Bool) throws {
        if on {
            try Self.exec(db, """
                CREATE TEMP TRIGGER IF NOT EXISTS simulated_insert_failure BEFORE INSERT ON images
                BEGIN SELECT RAISE(ABORT, 'simulated insert failure'); END;
                CREATE TEMP TRIGGER IF NOT EXISTS simulated_delete_failure BEFORE DELETE ON images
                BEGIN SELECT RAISE(ABORT, 'simulated delete failure'); END;
                """)
        } else {
            try Self.exec(db, "DROP TRIGGER IF EXISTS simulated_insert_failure; DROP TRIGGER IF EXISTS simulated_delete_failure;")
        }
    }

    // MARK: - 事务

    /// 在一个事务里执行：任何一步失败（包括 COMMIT）都回滚，并把错误抛出去
    private func transaction(_ body: () throws -> Void) throws {
        try Self.exec(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    // MARK: - 工具

    /// 标签编码为 "beach:0.912;sky:0.800"，紧凑且易读
    static func encodeLabels(_ labels: [LabelScore]) -> String {
        labels.map { "\($0.id):\(String(format: "%.3f", $0.confidence))" }.joined(separator: ";")
    }

    static func decodeLabels(_ s: String) -> [LabelScore] {
        s.split(separator: ";").compactMap { part in
            guard let i = part.lastIndex(of: ":"), let c = Float(part[part.index(after: i)...]) else { return nil }
            return LabelScore(id: String(part[..<i]), confidence: c)
        }
    }

    /// 向量以半精度（Float16）存储：512 维只占 1 KB，精度足够比较相似度
    static func encodeEmbedding(_ v: [Float]) -> Data {
        var halves = [UInt16](repeating: 0, count: v.count)
        v.withUnsafeBufferPointer { src in
            halves.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(v.count), rowBytes: v.count * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(v.count), rowBytes: v.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return halves.withUnsafeBytes { Data($0) }
    }

    static func decodeEmbedding(_ data: Data) -> [Float] {
        let n = data.count / 2
        guard n > 0 else { return [] }
        var halves = [UInt16](repeating: 0, count: n)
        _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var floats = [Float](repeating: 0, count: n)
        halves.withUnsafeMutableBufferPointer { src in
            floats.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
        }
        return floats
    }

    private static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data? {
        guard sqlite3_column_type(stmt, column) == SQLITE_BLOB, let p = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private static func columnNames(_ db: OpaquePointer?) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(images)", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db")
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return names
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    private func error() -> StoreError {
        StoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db")
    }
}
