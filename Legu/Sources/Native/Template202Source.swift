import Foundation

/// 「202 模板」聚合书源家族(202xs.com / 非凡中文 / 新笔趣阁 等同构镜像)
///
/// - 搜索:POST `/search.html`(表单字段 `s`);新版模板结果在 `<div class="block"><ul><li>`,
///   旧版模板结果在 `<span class="s2">`,两套结构都兼容
/// - 详情:`/book/{id}/`(og:novel 元数据)
/// - 目录:`/book/{id}/{page}/` 分页目录(解析 `<select>` 的全部页,按章节 ID 数值升序重排)
/// - 正文:`/read/0/{id}/{cid}.html`;长章节分页 `{cid}_{k}.html`,
///   越界时站点回退第 1 页(用「第N/M页」标题做终止判定)
final class Template202Source: ContentSource {
    struct Config {
        let id: String
        let name: String
        let base: String
    }

    let config: Config
    let identifier: String
    let displayName: String
    let capabilities = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    private let session = HTTP.session(timeout: 25)

    init(_ config: Config) {
        self.config = config
        self.identifier = config.id
        self.displayName = config.name
    }

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: config.base + "/search.html") else { return [] }
        let html = try await HTTP.fetchHTML(
            url, session: session,
            headers: ["Referer": config.base + "/"],
            method: "POST", form: ["s": trimmed]
        )
        return Self.parseSearch(html, sourceID: identifier, base: config.base)
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        guard let url = URL(string: "\(config.base)/book/\(bookID)/") else {
            throw SourceError.network("书目标识无效")
        }
        let html = try await HTTP.fetchHTML(url, session: session)
        guard let book = Self.parseDetail(html, bookID: bookID, sourceID: identifier, base: config.base) else {
            throw SourceError.notFound
        }
        return book
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        guard let firstURL = URL(string: "\(config.base)/book/\(bookID)/1/") else {
            throw SourceError.network("书目标识无效")
        }
        let firstHTML = try await HTTP.fetchHTML(firstURL, session: session)
        let pagePaths = Self.catalogPagePaths(from: firstHTML, bookID: bookID)
        var allChapters = Self.parseCatalog(firstHTML, bookID: bookID)

        let rest = pagePaths.filter { $0 != "/book/\(bookID)/1/" }
        let capped = Array(rest.prefix(300))
        let session = self.session
        let base = config.base
        for batch in stride(from: 0, to: capped.count, by: 12).map({ Array(capped[$0..<min($0 + 12, capped.count)]) }) {
            await withTaskGroup(of: [SourceChapter].self) { group in
                for path in batch {
                    group.addTask {
                        guard let url = URL(string: base + path) else { return [] }
                        guard let html = try? await HTTP.fetchHTML(url, session: session) else { return [] }
                        return Self.parseCatalog(html, bookID: bookID)
                    }
                }
                for await chapters in group {
                    allChapters.append(contentsOf: chapters)
                }
            }
        }

        let unique = Self.sortedUnique(allChapters)
        guard !unique.isEmpty else { throw SourceError.notFound }
        return unique
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        var pages: [String] = []
        var pageNumber = 0
        while pageNumber < 40 {
            let expected = pageNumber + 1
            let path = expected == 1
                ? "/read/0/\(bookID)/\(chapterID).html"
                : "/read/0/\(bookID)/\(chapterID)_\(expected - 1).html"
            guard let url = URL(string: config.base + path) else { break }
            let html: String
            do {
                html = try await HTTP.fetchHTML(url, session: session)
            } catch {
                break
            }
            guard let parsed = Self.parseChapterPage(html) else { break }
            if expected > 1, parsed.pageNumber != expected {
                break // 越界回退
            }
            if !parsed.text.isEmpty {
                pages.append(parsed.text)
            }
            if parsed.pageNumber != expected {
                break
            }
            pageNumber = expected
        }
        guard !pages.isEmpty else {
            throw SourceError.unsupported("该章正文为空(可能被删除或需要登录)")
        }
        return pages.joined(separator: "\n")
    }

    // MARK: - 解析(可测)

    static func parseSearch(_ html: String, sourceID: String, base: String) -> [SourceBook] {
        var books: [SourceBook] = []
        var seen = Set<String>()

        // 新版模板
        let newPattern = "(?s)<li><a href=\"/book/(\\d+)/\"[^>]*>(.*?)</a><span>(.*?)</span></li>"
        if let rx = try? NSRegularExpression(pattern: newPattern) {
            let ns = html as NSString
            for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let bid = ns.substring(with: m.range(at: 1))
                let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
                let author = HTMLText.cleanInline(ns.substring(with: m.range(at: 3)))
                guard !bid.isEmpty, !title.isEmpty, !seen.contains(bid) else { continue }
                seen.insert(bid)
                books.append(SourceBook(
                    sourceID: sourceID,
                    sourceBookID: bid,
                    title: title,
                    author: author,
                    cover: nil,
                    language: "zh",
                    summary: nil,
                    subjects: []
                ))
            }
        }
        if !books.isEmpty { return books }

        // 旧版模板
        let oldPattern = "(?s)<span class=\"s2\"><a href=\"(/book/(\\d+)/)\"[^>]*>(.*?)</a></span>\\s*<span class=\"s5\">(.*?)</span>"
        if let rx = try? NSRegularExpression(pattern: oldPattern) {
            let ns = html as NSString
            for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let bid = ns.substring(with: m.range(at: 2))
                let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 3)))
                let author = HTMLText.cleanInline(ns.substring(with: m.range(at: 4)))
                guard !bid.isEmpty, !title.isEmpty, !seen.contains(bid) else { continue }
                seen.insert(bid)
                books.append(SourceBook(
                    sourceID: sourceID,
                    sourceBookID: bid,
                    title: title,
                    author: author,
                    cover: nil,
                    language: "zh",
                    summary: nil,
                    subjects: []
                ))
            }
        }
        return books
    }

    static func parseDetail(_ html: String, bookID: String, sourceID: String, base: String) -> SourceBook? {
        let title = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:title") ?? "")
        guard !title.isEmpty else { return nil }
        let author = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:novel:author") ?? "")
        let intro = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:description") ?? "")
        let coverRaw = HTMLText.metaContent(html, property: "og:image") ?? ""
        let cover = HTMLText.absoluteURL(coverRaw, base: base)
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
            sourceID: sourceID,
            sourceBookID: bookID,
            title: title,
            author: author,
            cover: cover,
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: subjects
        )
    }

    static func catalogPagePaths(from html: String, bookID: String) -> [String] {
        let pattern = "value=\"(/book/\(NSRegularExpression.escapedPattern(for: bookID))/\\d+/)\""
        var paths = HTMLText.allCaptures(pattern: pattern, in: html)
        if !paths.contains("/book/\(bookID)/1/") {
            paths.insert("/book/\(bookID)/1/", at: 0)
        }
        return Array(Set(paths)).sorted {
            let a = Int($0.split(separator: "/").last ?? "") ?? 0
            let b = Int($1.split(separator: "/").last ?? "") ?? 0
            return a < b
        }
    }

    static func parseCatalog(_ html: String, bookID: String) -> [SourceChapter] {
        let pattern = "(?s)<a href=\"/read/0/\(NSRegularExpression.escapedPattern(for: bookID))/(\\d+)\\.html\"[^>]*>(.*?)</a>"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var out: [SourceChapter] = []
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cid = ns.substring(with: m.range(at: 1))
            let title = HTMLText.cleanInline(ns.substring(with: m.range(at: 2)))
            guard !cid.isEmpty, !title.isEmpty, !isButtonTitle(title) else { continue }
            out.append(SourceChapter(id: cid, index: 0, title: title, isFree: true))
        }
        return out
    }

    static func isButtonTitle(_ title: String) -> Bool {
        ["立即阅读", "加入书架", "小说详情", "开始阅读", "查看全部"].contains(title)
    }

    static func sortedUnique(_ chapters: [SourceChapter]) -> [SourceChapter] {
        var seen = Set<String>()
        var unique: [SourceChapter] = []
        for c in chapters where !seen.contains(c.id) {
            seen.insert(c.id)
            unique.append(c)
        }
        unique.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        return unique.enumerated().map { i, c in
            var c = c
            c.index = i + 1
            return c
        }
    }

    struct ChapterPage {
        var pageNumber: Int
        var title: String
        var text: String
    }

    static func parseChapterPage(_ html: String) -> ChapterPage? {
        // 新版模板:h2 标题 + #novelcontent
        if let h2 = HTMLText.firstCapture(pattern: "(?s)<h2>(.*?)</h2>", in: html),
           let content = HTMLText.firstCapture(pattern: "(?s)<div id=\"novelcontent\"[^>]*>(.*?)</div>", in: html) {
            let title = HTMLText.cleanInline(h2)
            let pageNumber = Int(HTMLText.firstCapture(pattern: "第(\\d+)/\\d+页", in: title) ?? "1") ?? 1
            let text = filteredParagraphs(content)
            return ChapterPage(pageNumber: pageNumber, title: title, text: text)
        }

        // 旧版模板:chapter-title + read_btn 包裹
        guard let h2Range = html.range(of: "<h2 class=\"chapter-title\">") else { return nil }
        let afterH2 = html[h2Range.upperBound...]
        let h2End = afterH2.range(of: "</h2>")?.upperBound ?? afterH2.startIndex
        let title = HTMLText.cleanInline(String(afterH2[afterH2.startIndex..<h2End]))
        let pageNumber = Int(HTMLText.firstCapture(pattern: "第(\\d+)页", in: title) ?? "1") ?? 1

        let navMarker = "<div class=\"read_btn\">"
        guard let nav1 = html.range(of: navMarker, range: h2End..<html.endIndex),
              let nav1End = html.range(of: "</div>", range: nav1.upperBound..<html.endIndex) else {
            return nil
        }
        let bodyEnd: String.Index
        if let nav2 = html.range(of: navMarker, range: nav1End.upperBound..<html.endIndex) {
            bodyEnd = nav2.lowerBound
        } else if let tail = html.range(of: "<div class=\"phb_fm", range: nav1End.upperBound..<html.endIndex) {
            bodyEnd = tail.lowerBound
        } else {
            bodyEnd = html.endIndex
        }
        let body = String(html[nav1End.upperBound..<bodyEnd])
        let text = filteredParagraphs(body)
        return ChapterPage(pageNumber: pageNumber, title: title, text: text)
    }

    /// `<p>` 段落提取 + 广告行过滤
    static func filteredParagraphs(_ body: String) -> String {
        let paragraphs = HTMLText.allCaptures(pattern: "(?s)<p[^>]*>(.*?)</p>", in: body)
            .map { HTMLText.cleanInline($0) }
            .filter { !$0.isEmpty && !isAdLine($0) }
        return paragraphs.joined(separator: "\n")
    }

    static func isAdLine(_ line: String) -> Bool {
        if line.contains("一秒记住") || line.contains("请记住本站") || line.contains("手机浏览器扫描") {
            return true
        }
        if line.contains("本章未完") || line.contains("点击下一页") {
            return true
        }
        if line.hasPrefix("《") && line.contains("页）") {
            return true
        }
        return false
    }
}

// MARK: - 同构镜像实例

extension Template202Source {
    static let mirrors: [Template202Source] = [
        Template202Source(Config(id: "202xs", name: "202小说网", base: "https://202xs.com")),
        Template202Source(Config(id: "ffzw", name: "非凡中文", base: "https://ffzw.cc")),
        Template202Source(Config(id: "xinbiqu", name: "新笔趣阁", base: "https://xinbiqu.org")),
    ]
}
