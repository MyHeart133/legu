import Foundation

/// 52书库(52shuku.net)适配器
///
/// - 书库:言情/耽美聚合站(囚于永夜等)
/// - 搜索:`/so/search.php?q=`(UTF-8)
/// - 详情:书页(标题形如「书名_作者【完结】在线阅读_52书库」)
/// - 目录:书页 `ul.list` 的「第N页」分页(站点以页为单位切分全文)
/// - 正文:`article.article-content`
final class Shuku52Source: ContentSource {
    let identifier = "shuku52"
    let displayName = "52书库"
    let capabilities = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    static let base = "https://www.52shuku.net"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.base)/so/search.php?q=\(encoded)") else {
            return []
        }
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": Self.base + "/"]
        )
        return Self.parseSearch(html)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: bookID) else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        guard let book = Self.parseDetail(html, bookURL: bookID) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let url = URL(string: bookID) else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        let chapters = Self.parseCatalog(html)
        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let url = URL(string: chapterID) else {
            throw SourceError.network("章节标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        let text = Self.parseChapter(html)
        guard !text.isEmpty else { throw SourceError.unsupported("该页正文为空") }
        return text
    }

    // MARK: - 解析(可测)

    /// 标题清洗:「1. 囚于永夜_麦香鸡呢【完结】」→ (书名, 作者)
    static func cleanTitle(_ raw: String) -> (title: String, author: String) {
        var s = HTMLText.cleanInline(raw)
        s = s.replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
        var author = ""
        if let underscore = s.firstIndex(of: "_") {
            let namePart = String(s[..<underscore])
            var authorPart = String(s[s.index(after: underscore)...])
            authorPart = authorPart.replacingOccurrences(of: "【.*?】", with: "", options: .regularExpression)
            author = authorPart.trimmingCharacters(in: .whitespaces)
            s = namePart
        }
        s = s.replacingOccurrences(of: "【.*?】", with: "", options: .regularExpression)
        return (s.trimmingCharacters(in: .whitespaces), author)
    }

    static func parseSearch(_ html: String) -> [SourceBook] {
        var books: [SourceBook] = []
        var seen = Set<String>()
        let pattern = "(?s)<article class=\"excerpt\">.*?<a href=\"([^\"]+)\"><h4>(.*?)</h4></a>.*?<span class=\"note\">(.*?)</span>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let titleRaw = ns.substring(with: m.range(at: 2))
            let noteRaw = ns.substring(with: m.range(at: 3))
            guard !href.isEmpty else { continue }
            let (title, author) = cleanTitle(titleRaw)
            guard !title.isEmpty, !seen.contains(href) else { continue }
            seen.insert(href)
            let intro = HTMLText.cleanInline(noteRaw)
                .replacingOccurrences(of: "《\(title)》", with: "")
                .trimmingCharacters(in: .whitespaces)
            books.append(SourceBook(
                sourceID: "shuku52",
                sourceBookID: href,
                title: title,
                author: author,
                cover: nil,
                language: "zh",
                summary: intro.isEmpty ? nil : intro,
                subjects: []
            ))
        }
        return books
    }

    static func parseDetail(_ html: String, bookURL: String) -> SourceBook? {
        let pageTitle = HTMLText.cleanInline(HTMLText.firstCapture(pattern: "(?s)<title>(.*?)</title>", in: html) ?? "")
        guard !pageTitle.isEmpty else { return nil }
        var namePart = pageTitle
        if let range = namePart.range(of: "在线阅读") {
            namePart = String(namePart[..<range.lowerBound])
        }
        let (title, author) = cleanTitle(namePart)
        guard !title.isEmpty else { return nil }
        var intro = ""
        if let desc = HTMLText.metaContent(html, property: "description"), !desc.isEmpty {
            intro = desc
        }
        return SourceBook(
            sourceID: "shuku52",
            sourceBookID: bookURL,
            title: title,
            author: author,
            cover: nil,
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: []
        )
    }

    static func parseCatalog(_ html: String) -> [SourceChapter] {
        var out: [SourceChapter] = []
        var seen = Set<String>()
        let pattern = "(?s)<li class=\"mulu\"><a href=\"([^\"]+)\">([^<]{1,20})</a></li>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            guard !href.isEmpty, !title.isEmpty, !seen.contains(href) else { continue }
            seen.insert(href)
            out.append(SourceChapter(id: href, index: out.count + 1, title: title, isFree: true))
        }
        return out
    }

    static func parseChapter(_ html: String) -> String {
        guard let start = html.range(of: "<article class=\"article-content\"") else { return "" }
        let tail = html[start.upperBound...]
        guard let gt = tail.firstIndex(of: ">") else { return "" }
        let afterTag = tail[tail.index(after: gt)...]
        let end = afterTag.range(of: "</article>")?.lowerBound ?? afterTag.endIndex
        let body = String(afterTag[..<end])
        let text = HTMLText.paragraphs(fromHTML: body)
        let junk = ["52书库", "www.52shuku", "请记住本站", "手机阅读", "上一页", "下一页", "加入书签"]
        let lines = text.components(separatedBy: "\n").filter { line in
            !junk.contains(where: { line.contains($0) })
        }
        return lines.joined(separator: "\n")
    }
}
