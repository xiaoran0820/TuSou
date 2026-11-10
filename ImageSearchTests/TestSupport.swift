import Foundation
@testable import ImageSearch

/// 测试用的固定数据：固定的"现在"、日历和时区，让日期相关的结果不随运行时间和地区变化
enum Fixture {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.firstWeekday = 2   // 一周从周一开始
        return c
    }()

    /// 2026-11-09 15:00，周一
    static let now = date(2026, 11, 9, hour: 15)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func record(_ id: String, labels: [String: Float] = [:], ocr: String = "",
                       faces: Int = 0, flags: RecordFlags = [], modified: Date? = nil) -> ImageRecord {
        ImageRecord(id: id, source: .photoLibrary, sourceModificationDate: modified,
                    labels: labels.map { LabelScore(id: $0.key, confidence: $0.value) }
                        .sorted { $0.confidence > $1.confidence },
                    ocrText: ocr, faceCount: faces, flags: flags, pixelWidth: 100, pixelHeight: 100,
                    analyzerVersion: ImageAnalyzer.version, indexedAt: Date(timeIntervalSince1970: 0))
    }

    /// records 的顺序就是"时间倒序"：同分时排在前面的先出
    static func search(_ query: String, _ records: [ImageRecord],
                       metas: [String: ImageMeta] = [:]) -> SearchOutcome {
        SearchEngine().search(query: query, ids: records.map(\.id),
                              records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                              metas: metas, now: now, calendar: calendar)
    }

    static func parse(_ query: String) -> [QueryTerm] {
        QueryParser.parse(query, dictionary: .shared, now: now, calendar: calendar)
    }

    /// 只看解析出的检索词文本
    static func words(_ query: String) -> [String] { parse(query).map(\.text) }
}
