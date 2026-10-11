import Foundation

/// 笔趣阁(365 模板)适配器
///
/// - 搜索:POST `/s.php`(表单字段 `type=articlename` + `s`)
/// - 详情:`/book/{id}/`(og:novel 元数据)
/// - 目录:`/newbook/{id}/`(`<ul class="info">` 内全部章节,DOM 顺序即阅读顺序)
/// - 正文:`/chapter/{id}/{cid}.html`(`<div id="txt">`,`<br>` 分段)
final class Biquge365Source: ContentSource {
    let identifier = "biquge365"
    let displayName = "笔趣阁(365)"
    let capabilities = SourceCapabilities(search: true, metadata: true, onlineReading: true, requiresAccount: false, allowsOffline: true)

    static let base = "https://www.biquge365.net"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "\(Self.base)/s.php") else { return [] }
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": Self.base + "/"],
            method: "POST", form: ["type": "articlename", "s": trimmed]
        )
        return Self.parseSearch(html)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: "\(Self.base)/book/\(bookID)/") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        guard let book = Self.parseDetail(html, bookID: bookID) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let url = URL(string: "\(Self.base)/newbook/\(bookID)/") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        let chapters = Self.parseCatalog(html, bookID: bookID)
        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let url = URL(string: "\(Self.base)/chapter/\(bookID)/\(chapterID).html") else {
            throw SourceError.network("章节标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        let text = Self.parseChapter(html)
        guard !text.isEmpty else { throw SourceError.unsupported("该章正文为空") }
        return text
    }

    // MARK: - 解析(可测)

    static func parseSearch(_ html: String) -> [SourceBook] {
        var books: [SourceBook] = []
        var seen = Set<String>()
        let pattern = "(?s)<span class=\"name\"><a href=\"(/book/(\\d+)/)\"[^>]*>(.*?)</a></span>.*?<span class=\"zuo\"><a[^>]*>(.*?)</a></span>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            let bid = ns.substring(with: m.range(at: 2))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 3)))
            let author = HTMLText.cleanInline(ns.substring(with: m.range(at: 4)))
            guard !bid.isEmpty, !title.isEmpty, !seen.contains(bid) else { continue }
            seen.insert(bid)
            books.append(SourceBook(
                sourceID: "biquge365",
                sourceBookID: bid,
                title: title,
                author: author,
                cover: nil,
                language: "zh",
                summary: nil,
                subjects: []
            ))
        }
        return books
    }

    static func parseDetail(_ html: String, bookID: String) -> SourceBook? {
        let title = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:title") ?? "")
        guard !title.isEmpty else { return nil }
        let author = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:novel:author") ?? "")
        let intro = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:description") ?? "")
        let cover = HTMLText.metaContent(html, property: "og:image").flatMap {
            HTMLText.absoluteURL($0, base: base)
        }
        var subjects: [String] = []
        if let category = HTMLText.metaContent(html, property: "og:novel:category"), !category.isEmpty {
            subjects.append(HTMLText.cleanInline(category))
        }
        if let status = HTMLText.metaContent(html, property: "og:novel:status"), !status.isEmpty {
            subjects.append(HTMLText.cleanInline(status))
        }
        if let latest = HTMLText.metaContent(html, property: "og:novel:latest_chapter_name"), !latest.isEmpty {
            subjects.append("最新:\(HTMLText.cleanInline(latest))")
        }
        return SourceBook(
            sourceID: "biquge365",
            sourceBookID: bookID,
            title: title,
            author: author,
            cover: cover,
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: subjects
        )
    }

    static func parseCatalog(_ html: String, bookID: String) -> [SourceChapter] {
        // 优先取「全部章节」列表块;退化时从「全部章节」标题之后取,避免混入顶部倒序的「最新章节」块
        let scope: String
        if let listRange = html.range(of: "<ul class=\"info\">") {
            let tail = html[listRange.upperBound...]
            if let end = tail.range(of: "</ul>") {
                scope = String(tail[..<end.lowerBound])
            } else {
                scope = String(tail)
            }
        } else if let h2Range = html.range(of: "全部章节") {
            let tail = html[h2Range.upperBound...]
            if let end = tail.range(of: "class=\"footer\"") {
                scope = String(tail[..<end.lowerBound])
            } else {
                scope = String(tail)
            }
        } else {
            scope = html
        }
        var out: [SourceChapter] = []
        var seen = Set<String>()
        let pattern = "(?s)<a href=\"/chapter/\(NSRegularExpression.escapedPattern(for: bookID))/(\\d+)\\.html\"[^>]*>(.*?)</a>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = scope as NSString
        for m in rx.matches(in: scope, range: NSRange(location: 0, length: ns.length)) {
            let cid = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            guard !cid.isEmpty, !title.isEmpty, title != "开始阅读", !seen.contains(cid) else { continue }
            seen.insert(cid)
            out.append(SourceChapter(id: cid, index: out.count + 1, title: title, isFree: true))
        }
        return out
    }

    static func parseChapter(_ html: String) -> String {
        guard let start = html.range(of: "<div id=\"txt\""),
              let startEnd = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let end = html.range(of: "</div>", range: startEnd.upperBound..<html.endIndex) else {
            return ""
        }
        var content = String(html[startEnd.upperBound..<end.lowerBound])
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
            if line.contains("一秒记住") || line.contains("请记住本站") { return false }
            if line.contains("biquge365") && line.count < 80 { return false }
            return true
        }
        return filtered.joined(separator: "\n")
    }
}
