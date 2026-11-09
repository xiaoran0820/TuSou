import Foundation
import SQLite3

/// 索引持久化：系统自带 SQLite（不依赖第三方库）。
/// 所有读写都在这个 actor 里串行执行。
actor IndexStore {
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
                indexed_at REAL NOT NULL
            );
            """)
    }

    deinit { sqlite3_close(db) }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Index", isDirectory: true).appendingPathComponent("index.sqlite")
    }

    // MARK: - 读

    func loadAll() throws -> [ImageRecord] {
        let sql = "SELECT id, source, mod_date, labels, ocr, faces, flags, width, height, version, indexed_at FROM images"
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
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))))
        }
        return out
    }

    // MARK: - 写

    func upsert(_ records: [ImageRecord]) throws {
        guard !records.isEmpty else { return }
        try Self.exec(db, "BEGIN IMMEDIATE TRANSACTION")
        let sql = """
            INSERT OR REPLACE INTO images (id, source, mod_date, labels, ocr, faces, flags, width, height, version, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            try? Self.exec(db, "ROLLBACK"); throw error()
        }
        defer { sqlite3_finalize(stmt) }
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
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let e = error()
                try? Self.exec(db, "ROLLBACK")
                throw e
            }
        }
        try Self.exec(db, "COMMIT")
    }

    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try Self.exec(db, "BEGIN IMMEDIATE TRANSACTION")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM images WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            try? Self.exec(db, "ROLLBACK"); throw error()
        }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, Self.transient)
            _ = sqlite3_step(stmt)
        }
        try Self.exec(db, "COMMIT")
    }

    func deleteAll() throws {
        try Self.exec(db, "DELETE FROM images")
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
