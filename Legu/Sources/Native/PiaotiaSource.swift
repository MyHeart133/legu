import Foundation

/// 飘天文学(piaotia.com)适配器
///
/// - 编码:GBK/GB2312 —— 搜索关键词需按 GB18030 百分号转义
/// - 搜索:GET `/modules/article/search.php?searchkey={GBK}&searchtype=articlename`
/// - 详情:`/bookinfo/{a}/{b}.html`(标题/作者/简介;无封面图)
/// - 目录:`/html/{a}/{b}/`(单页全目录,DOM 顺序即阅读顺序)
/// - 正文:`/html/{a}/{b}/{cid}.html`(单页,`<br />` 分段)
final class PiaotiaSource: ContentSource {
    let identifier = "piaotia"
    let displayName = "飘天文学"
    let capabilities = SourceCapabilities(search: true, metadata: true, onlineReading: true, requiresAccount: false, allowsOffline: true)

    static let base = "https://www.piaotia.com"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = HTTP.percentEncodedGBK(trimmed),
              let url = URL(string: "\(Self.base)/modules/article/search.php?searchkey=\(encoded)&searchtype=articlename") else {
            return []
        }
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": Self.base + "/"],
            encoding: .gb18030
        )
        return Self.parseSearch(html)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: "\(Self.base)/bookinfo/\(bookID).html") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        guard let book = Self.parseDetail(html, bookID: bookID) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let url = URL(string: "\(Self.base)/html/\(bookID)/") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        let chapters = Self.parseCatalog(html)
        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let url = URL(string: "\(Self.base)/html/\(bookID)/\(chapterID).html") else {
            throw SourceError.network("章节标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        let text = Self.parseChapter(html)
        guard !text.isEmpty else { throw SourceError.unsupported("该章正文为空") }
        return text
    }

    // MARK: - 解析(可测)

    /// 搜索结果表:每行「书名 / 最新章节 / 作者 / 字数 / 更新 / 状态」
    static func parseSearch(_ html: String) -> [SourceBook] {
        var books: [SourceBook] = []
        var seen = Set<String>()
        let rowPattern = "(?s)<tr>\\s*<td class=\"odd\"><a href=\"(https?://[^\"]*?/bookinfo/(\\d+/\\d+)\\.html)\"[^>]*>(.*?)</a></td>(.*?)</tr>"
        guard let rx = try? NSRegularExpression(pattern: rowPattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            let bookID = ns.substring(with: m.range(at: 2))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 3)))
            let rest = ns.substring(with: m.range(at: 4))
            guard !bookID.isEmpty, !title.isEmpty, !seen.contains(bookID) else { continue }
            seen.insert(bookID)
            let author = HTMLText.cleanInline(
                HTMLText.firstCapture(pattern: "<td class=\"odd\">(.*?)</td>", in: rest) ?? ""
            )
            // 状态是行内最后一个「偶数列」单元格(倒数第二列是更新时间,最后一列是状态)
            let status = HTMLText.cleanInline(
                HTMLText.allCaptures(pattern: "<td class=\"even\"[^>]*>([^<]*)</td>", in: rest).last ?? ""
            )
            books.append(SourceBook(
                sourceID: "piaotia",
                sourceBookID: bookID,
                title: title,
                author: author,
                cover: nil,
                language: "zh",
                summary: nil,
                subjects: status.isEmpty ? [] : [status]
            ))
        }
        return books
    }

    static func parseDetail(_ html: String, bookID: String) -> SourceBook? {
        var title = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "(?s)<h1>(.*?)</h1>", in: html)
                ?? HTMLText.firstCapture(pattern: "(?s)<title>(.*?)</title>", in: html)
                ?? ""
        )
        if let cut = title.components(separatedBy: "最新章节").first {
            title = cut.trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }

        let normalized = html.replacingOccurrences(of: "&nbsp;", with: " ")
        let author = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "作\\s*者[：:]\\s*([^<\\s][^<]*)", in: normalized) ?? ""
        )
        let category = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "类\\s*别[：:]\\s*([^<\\s][^<]*)", in: normalized) ?? ""
        )
        var intro = ""
        if let introRange = normalized.range(of: "内容简介") {
            let tail = normalized[introRange.upperBound...]
            if let end = tail.range(of: "</td>") {
                intro = HTMLText.plainText(fromHTML: String(tail[..<end.lowerBound]))
            }
        }
        return SourceBook(
            sourceID: "piaotia",
            sourceBookID: bookID,
            title: title,
            author: author,
            cover: nil,
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: category.isEmpty ? [] : [category]
        )
    }

    static func parseCatalog(_ html: String) -> [SourceChapter] {
        var out: [SourceChapter] = []
        var seen = Set<String>()
        let pattern = "(?s)<a href=\"(\\d{5,9})\\.html\"[^>]*>([^<]{1,50})</a>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cid = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            guard !cid.isEmpty, !title.isEmpty, !seen.contains(cid) else { continue }
            seen.insert(cid)
            out.append(SourceChapter(id: cid, index: out.count + 1, title: title, isFree: true))
        }
        return out
    }

    /// 正文位于 `</H1>` 与底部导航(`bottomlink`)之间;`<br />` 为分段
    static func parseChapter(_ html: String) -> String {
        var content = html
        if let h1End = content.range(of: "</H1>") ?? content.range(of: "</h1>") {
            content = String(content[h1End.upperBound...])
        }
        if let bottom = content.range(of: "<div class=\"bottomlink\">") {
            content = String(content[..<bottom.lowerBound])
        }
        // 去掉脚本块
        content = content.replacingOccurrences(of: "(?s)<script.*?</script>", with: "", options: .regularExpression)
        var text = content.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = HTMLText.decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{3000}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let filtered = lines.filter { line in
            guard !line.isEmpty else { return false }
            if line.contains("飘天文学") && (line.contains("www.piaotia.com") || line.contains("感谢各位书友")) {
                return false
            }
            if line.contains("返回目录") || line.contains("返回书页") { return false }
            if line.count <= 12 && (line.contains("上一章") || line.contains("下一章") || line.contains("快捷键")) {
                return false
            }
            return true
        }
        return filtered.joined(separator: "\n")
    }
}
