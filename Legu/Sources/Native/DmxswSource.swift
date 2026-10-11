import Foundation

/// 耽美小说(m.dmxsw.org)适配器
///
/// - 编码:GB2312/GB18030 —— 搜索关键词需按 GB18030 编码
/// - 搜索:POST `/e/search/index.php`(表单 `keyboard`/`show`/`classid`,跟随跳转到结果页)
/// - 详情/目录:书页 `/xhly/{id}.html`(h1 标题、作者、标签、简介、`.book_list` 全目录)
/// - 正文:`/view/{classid}-{bookid}-{n}.html`,内容在 `.read_article`
final class DmxswSource: ContentSource {
    let identifier = "dmxsw"
    let displayName = "耽美小说"
    let capabilities = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    static let base = "https://m.dmxsw.org"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "\(Self.base)/e/search/index.php") else { return [] }
        let bodyString = "keyboard=\(HTTP.percentEncodedGBK(trimmed))&show=title&classid=0"
        let body = Self.encodeGBK(bodyString)
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": Self.base + "/"],
            method: "POST", body: body, encoding: .gb18030
        )
        return Self.parseSearch(html)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: bookID) else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        guard let book = Self.parseDetail(html, bookURL: bookID) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let url = URL(string: bookID) else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        let chapters = Self.parseCatalog(html)
        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let url = URL(string: chapterID) else {
            throw SourceError.network("章节标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session, encoding: .gb18030)
        let text = Self.parseChapter(html)
        guard !text.isEmpty else { throw SourceError.unsupported("该章正文为空") }
        return text
    }

    // MARK: - 解析(可测)

    static func parseSearch(_ html: String) -> [SourceBook] {
        var books: [SourceBook] = []
        var seen = Set<String>()
        let pattern = "(?s)<div class=\"bk\">\\s*<a href=\"([^\"]+)\">.*?<h3>(.*?)</h3>.*?<p>(.*?)</p>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            let introRaw = ns.substring(with: m.range(at: 3))
            guard !href.isEmpty, !title.isEmpty else { continue }
            guard let resolved = HTMLText.absoluteURL(href, base: base), !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            let intro = HTMLText.cleanInline(introRaw)
                .replacingOccurrences(of: "《\(title)》作者：", with: "")
            let author = HTMLText.firstCapture(pattern: "作者[:：]\\s*([^\\s<　]+)", in: introRaw) ?? ""
            books.append(SourceBook(
                sourceID: "dmxsw",
                sourceBookID: resolved,
                title: title,
                author: HTMLText.cleanInline(author),
                cover: nil,
                language: "zh",
                summary: intro.isEmpty ? nil : intro,
                subjects: []
            ))
        }
        return books
    }

    static func parseDetail(_ html: String, bookURL: String) -> SourceBook? {
        let title = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "(?s)<h1>(.*?)</h1>", in: html) ?? ""
        )
        guard !title.isEmpty else { return nil }
        let author = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "作者：<a[^>]*>(.*?)</a>", in: html) ?? ""
        )
        var subjects: [String] = []
        if let tagsBlock = HTMLText.firstCapture(pattern: "(?s)<div class=\"tags\">(.*?)</div>", in: html) {
            let tags = HTMLText.allCaptures(pattern: ">([^<>]{1,12})</a>", in: tagsBlock)
            subjects.append(contentsOf: tags.map { HTMLText.cleanInline($0) }.filter { !$0.isEmpty && $0 != "标签:" })
        }
        var intro = ""
        if let raw = HTMLText.firstCapture(pattern: "(?s)<div class=\"infos\">.*?<p>(.*?)</p>", in: html) {
            intro = HTMLText.plainText(fromHTML: raw)
                .replacingOccurrences(of: "文案：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SourceBook(
            sourceID: "dmxsw",
            sourceBookID: bookURL,
            title: title,
            author: author,
            cover: nil,
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: subjects
        )
    }

    static func parseCatalog(_ html: String) -> [SourceChapter] {
        var out: [SourceChapter] = []
        var seen = Set<String>()
        let pattern = "(?s)<a href=\"(/view/[^\"]+\\.html)\"[^>]*>\\s*([^<]{1,40})</a>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            guard !path.isEmpty, !title.isEmpty, !seen.contains(path) else { continue }
            guard let resolved = HTMLText.absoluteURL(path, base: base) else { continue }
            seen.insert(path)
            out.append(SourceChapter(id: resolved, index: out.count + 1, title: title, isFree: true))
        }
        return out
    }

    static func parseChapter(_ html: String) -> String {
        guard let start = html.range(of: "<div class=\"read_article\">") else { return "" }
        var tail = html[start.upperBound...]
        if let end = tail.range(of: "<div class=\"page_chapter\">") {
            tail = tail[..<end.lowerBound]
        } else if let end = tail.range(of: "<div class=\"copyright\">") {
            tail = tail[..<end.lowerBound]
        }
        let body = String(tail)
        let text = HTMLText.paragraphs(fromHTML: body)
        let junk = ["耽美小说网", "www.dmxsw.org", "请记住本站", "手机版", "加入书签", "上一章", "下一章", "回目录"]
        let lines = text.components(separatedBy: "\n").filter { line in
            !junk.contains(where: { line.contains($0) })
        }
        return lines.joined(separator: "\n")
    }

    private static func encodeGBK(_ s: String) -> Data {
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return (s as NSString).data(using: cfEncoding) ?? Data(s.utf8)
    }
}
