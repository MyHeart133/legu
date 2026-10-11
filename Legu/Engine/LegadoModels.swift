import Foundation

/// Legado 书源模型(JSON 兼容子集,未知字段忽略)
struct LegadoSource: Codable {
    var bookSourceName: String?
    var bookSourceUrl: String?
    var bookSourceGroup: String?
    var bookSourceComment: String?
    var bookSourceType: Int?
    var enabled: Bool?
    var enabledExplore: Bool?
    var header: String?
    var searchUrl: String?
    var exploreUrl: String?
    var ruleSearch: RuleSearch?
    var ruleBookInfo: RuleBookInfo?
    var ruleToc: RuleToc?
    var ruleContent: RuleContent?
    var ruleExplore: RuleSearch?

    struct RuleSearch: Codable {
        var bookList: String?
        var name: String?
        var author: String?
        var bookUrl: String?
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
        var wordCount: String?
    }

    struct RuleBookInfo: Codable {
        var name: String?
        var author: String?
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
        var wordCount: String?
        var tocUrl: String?
        var initRule: String?

        private enum CodingKeys: String, CodingKey {
            case name, author, coverUrl, intro, kind, lastChapter, wordCount, tocUrl
            case initRule = "init"
        }
    }

    struct RuleToc: Codable {
        var chapterList: String?
        var chapterName: String?
        var chapterUrl: String?
        var nextTocUrl: String?
    }

    struct RuleContent: Codable {
        var content: String?
        var nextContentUrl: String?
        var replaceRegex: String?
    }

    // MARK: - 工具

    /// 清洗后的站点根地址(去掉 # 注释后缀与尾斜杠)
    var cleanBaseURL: String? {
        guard var u = bookSourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else { return nil }
        if let hash = u.firstIndex(of: "#") {
            u = String(u[..<hash])
        }
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u.isEmpty ? nil : u
    }

    var displayTitle: String {
        let n = bookSourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? (cleanBaseURL ?? "未知书源") : n
    }

    var groupTitle: String {
        let g = bookSourceGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return g.isEmpty ? "未分组" : g
    }

    /// 请求头(header 字段是 JSON 文本)
    var parsedHeaders: [String: String] {
        guard let header, let data = header.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj
    }

    /// 从 JSON 文本解析书源列表(兼容单对象 / 数组 / BOM)
    static func decodeList(_ text: String) -> [LegadoSource] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
        guard let data = s.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([LegadoSource].self, from: data) {
            return list
        }
        if let single = try? decoder.decode(LegadoSource.self, from: data) {
            return [single]
        }
        return []
    }

    static func decodeList(_ data: Data) -> [LegadoSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([LegadoSource].self, from: data) {
            return list
        }
        if let single = try? decoder.decode(LegadoSource.self, from: data) {
            return [single]
        }
        // BOM 兜底
        if data.count > 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return decodeList(String(decoding: data.dropFirst(3), as: UTF8.self))
        }
        return []
    }
}
