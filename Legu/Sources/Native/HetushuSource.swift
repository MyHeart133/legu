import Foundation

/// 和图书(hetushu.com)适配器
///
/// - 书库:精校版网文镜像站(蛊真人等 2000+ 章全本)
/// - 搜索:`/search/?keyword=`(需带 Referer)
/// - 详情/目录:`/book/{id}/index.html`(单页全目录,DOM 顺序即阅读顺序)
/// - 正文:`/book/{id}/{cid}.html`,内容在 `<div id="content">` 的嵌套 div 中
final class HetushuSource: ContentSource {
    let identifier = "hetushu"
    let displayName = "和图书"
    let capabilities = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    static let base = "https://www.hetushu.com"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.base)/search/?keyword=\(encoded)") else {
            return []
        }
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": Self.base + "/"]
        )
        return Self.parseSearch(html)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: "\(Self.base)/book/\(bookID)/index.html") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        guard let book = Self.parseDetail(html, bookID: bookID) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let url = URL(string: "\(Self.base)/book/\(bookID)/index.html") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        let chapters = Self.parseCatalog(html, bookID: bookID)
        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let url = URL(string: "\(Self.base)/book/\(bookID)/\(chapterID).html") else {
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
        let pattern = "(?s)<dd><a href=\"/book/(\\d+)/index\\.html\"><img src=\"([^\"]*)\"[^>]*/></a>.*?<h4[^>]*><a[^>]*>(.*?)</a><span>\\s*/\\s*(.*?)\\s*/\\s*</span></h4>.*?<div class=\"intro\">(.*?)</div>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let bid = ns.substring(with: m.range(at: 1))
            let cover = ns.substring(with: m.range(at: 2))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 3)))
            let author = HTMLText.cleanInline(ns.substring(with: m.range(at: 4)))
            let intro = HTMLText.cleanInline(
                ns.substring(with: m.range(at: 5)).replacingOccurrences(of: "</p>", with: " ")
            )
            guard !bid.isEmpty, !title.isEmpty, !seen.contains(bid) else { continue }
            seen.insert(bid)
            books.append(SourceBook(
                sourceID: "hetushu",
                sourceBookID: bid,
                title: title,
                author: author,
                cover: HTMLText.absoluteURL(cover, base: base),
                language: "zh",
                summary: intro.isEmpty ? nil : intro,
                subjects: []
            ))
        }
        return books
    }

    static func parseDetail(_ html: String, bookID: String) -> SourceBook? {
        let title = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "(?s)<div class=\"book_info[^\"]*\">\\s*<img[^>]*/>\\s*<h2>(.*?)</h2>", in: html)
                ?? HTMLText.firstCapture(pattern: "(?s)<h2>(.*?)</h2>", in: html)
                ?? ""
        )
        guard !title.isEmpty else { return nil }
        let author = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "作者：<a[^>]*>(.*?)</a>", in: html) ?? ""
        )
        let kind = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "类型：(.*?)<", in: html) ?? ""
        )
        let words = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "字数：(.*?)<", in: html) ?? ""
        )
        var intro = ""
        if let introRange = html.range(of: "<div class=\"intro\">") {
            let tail = html[introRange.upperBound...]
            if let end = tail.range(of: "</div>") {
                intro = HTMLText.plainText(fromHTML: String(tail[..<end.lowerBound]))
            }
        }
        var subjects: [String] = []
        if !kind.isEmpty { subjects.append(kind) }
        if !words.isEmpty { subjects.append(words) }
        return SourceBook(
            sourceID: "hetushu",
            sourceBookID: bookID,
            title: title,
            author: author,
            cover: "\(base)/book/cover.pic/cover_\(bookID).jpg",
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: subjects
        )
    }

    static func parseCatalog(_ html: String, bookID: String) -> [SourceChapter] {
        var out: [SourceChapter] = []
        var seen = Set<String>()
        let pattern = "(?s)<a href=\"/book/\(NSRegularExpression.escapedPattern(for: bookID))/(\\d+)\\.html\"[^>]*>(.*?)</a>"
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

    static func parseChapter(_ html: String) -> String {
        guard let contentStart = html.range(of: "<div id=\"content\"") else { return "" }
        let tail = html[contentStart.upperBound...]
        guard let h2End = tail.range(of: "</h2>") else { return "" }
        let afterTitle = tail[h2End.upperBound...]
        let bodyEnd = afterTitle.range(of: "<script")?.lowerBound ?? afterTitle.endIndex
        let body = String(afterTitle[..<bodyEnd])
        let junk: Set<String> = ["书签", "加入书签", "上一章", "下一章", "章节报错", "推荐本书", "关闭", "背景", "字体", "设置"]
        let parts = HTMLText.allCaptures(pattern: "(?s)<div[^>]*>(.*?)</div>", in: body)
            .map { HTMLText.cleanInline($0) }
            .filter { !$0.isEmpty && !junk.contains($0) }
        return parts.joined(separator: "\n")
    }
}
