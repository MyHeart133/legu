import Foundation

/// Legado 书源 → 内容源适配器(引擎驱动)
final class LegadoContentSource: ContentSource {
    let model: LegadoSource
    let identifier: String
    let displayName: String
    let capabilities: SourceCapabilities
    let baseURL: String

    private let session = HTTP.session(timeout: 25)
    private let extraHeaders: [String: String]

    init?(model: LegadoSource) {
        guard let base = model.cleanBaseURL else { return nil }
        self.model = model
        self.baseURL = base
        self.displayName = model.displayTitle
        self.extraHeaders = model.parsedHeaders
        self.identifier = "legado:" + Self.stableID(base + "|" + model.displayTitle)
        let hasSearch = !(model.searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.capabilities = SourceCapabilities(
            search: hasSearch,
            metadata: true,
            onlineReading: true,
            requiresAccount: false,
            allowsOffline: true
        )
    }

    static func stableID(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        guard let searchUrl = model.searchUrl, !searchUrl.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let (template, options) = Self.parseURLOptions(searchUrl)
        let encoding = HTTP.TextEncoding(label: options.charset) ?? .utf8
        let urlString = Self.expand(template, key: trimmed, page: "1", base: baseURL, encoding: encoding)
        var method = (options.method ?? "").uppercased()
        var body: Data? = nil
        if let bodyTemplate = options.body, !bodyTemplate.isEmpty {
            let expanded = Self.expand(bodyTemplate, key: trimmed, page: "1", base: baseURL, encoding: encoding)
            body = Self.encode(expanded, encoding: encoding)
            if method.isEmpty { method = "POST" }
        }
        if method.isEmpty { method = "GET" }

        let html = try await fetch(urlString, method: method, body: body, charset: options.charset)
        let root = HTMLParser.parse(html)
        let ctx = EvalContext(base: baseURL, key: trimmed)

        guard let searchRule = model.ruleSearch, let bookListRule = searchRule.bookList, !bookListRule.isEmpty else {
            return []
        }
        let nodes = RuleEvaluator.elements(bookListRule, in: root, ctx: ctx)
        var books: [SourceBook] = []
        var seen = Set<String>()

        for node in nodes {
            let title = field(searchRule.name, fallback: "text", in: node, ctx: ctx)
            let bookUrlRaw = field(searchRule.bookUrl, fallback: "a@href||href", in: node, ctx: ctx)
            guard !title.isEmpty, !bookUrlRaw.isEmpty else { continue }
            guard let resolved = Self.resolveURL(bookUrlRaw, base: baseURL) else { continue }
            guard !seen.contains(resolved) else { continue }
            seen.insert(resolved)

            let author = field(searchRule.author, fallback: "", in: node, ctx: ctx)
            let cover = field(searchRule.coverUrl, fallback: "", in: node, ctx: ctx)
            let intro = field(searchRule.intro, fallback: "", in: node, ctx: ctx)
            let kind = field(searchRule.kind, fallback: "", in: node, ctx: ctx)
            let lastChapter = field(searchRule.lastChapter, fallback: "", in: node, ctx: ctx)
            var subjects: [String] = []
            if !kind.isEmpty { subjects.append(kind) }
            if !lastChapter.isEmpty { subjects.append("最新:\(lastChapter)") }

            books.append(SourceBook(
                sourceID: identifier,
                sourceBookID: resolved,
                title: title,
                author: author,
                cover: cover.isEmpty ? nil : Self.resolveURL(cover, base: baseURL),
                language: "zh",
                summary: intro.isEmpty ? nil : intro,
                subjects: subjects
            ))
        }
        return books
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        let html = try await fetch(bookID, method: "GET", body: nil, charset: nil)
        let root = HTMLParser.parse(html)
        var ctx = EvalContext(base: baseURL, bookUrl: bookID)

        let info = model.ruleBookInfo
        if let initRule = info?.initRule, !initRule.isEmpty {
            for part in initRule.components(separatedBy: "@put:") where !part.isEmpty {
                RuleEvaluator.applyPut(rule: "@put:" + part, node: root, ctx: &ctx)
            }
        }

        var title = field(info?.name, fallback: "", in: root, ctx: ctx)
        if title.isEmpty {
            title = HTMLText.cleanInline(HTMLText.metaContent(html, property: "og:title") ?? "")
        }
        if title.isEmpty {
            title = HTMLText.cleanInline(HTMLText.firstCapture(pattern: "<title>(.*?)</title>", in: html) ?? "")
        }
        let author = field(info?.author, fallback: "", in: root, ctx: ctx)
        let cover = field(info?.coverUrl, fallback: "", in: root, ctx: ctx)
        let intro = field(info?.intro, fallback: "", in: root, ctx: ctx)
        let kind = field(info?.kind, fallback: "", in: root, ctx: ctx)
        let lastChapter = field(info?.lastChapter, fallback: "", in: root, ctx: ctx)
        let wordCount = field(info?.wordCount, fallback: "", in: root, ctx: ctx)

        var subjects: [String] = []
        if !kind.isEmpty { subjects.append(kind) }
        if !wordCount.isEmpty { subjects.append(wordCount) }
        if !lastChapter.isEmpty { subjects.append("最新:\(lastChapter)") }

        return SourceBook(
            sourceID: identifier,
            sourceBookID: bookID,
            title: title,
            author: author,
            cover: cover.isEmpty ? nil : Self.resolveURL(cover, base: baseURL),
            language: "zh",
            summary: intro.isEmpty ? nil : intro,
            subjects: subjects
        )
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        // 1. 书页(用于解析 tocUrl)
        let bookHTML = try await fetch(bookID, method: "GET", body: nil, charset: nil)
        let bookRoot = HTMLParser.parse(bookHTML)
        let bookCtx = EvalContext(base: baseURL, bookUrl: bookID)

        var tocURL = bookID
        if let tocRule = model.ruleBookInfo?.tocUrl, !tocRule.isEmpty {
            let v = RuleEvaluator.string(tocRule, in: bookRoot, ctx: bookCtx)
            if let resolved = Self.resolveURL(v, base: baseURL), resolved != bookID {
                tocURL = resolved
            }
        }

        var chapters: [SourceChapter] = []
        var seen = Set<String>()
        var visited = Set<String>()
        var pageURL: String? = tocURL
        var pages = 0

        while let current = pageURL, pages < 20, !visited.contains(current) {
            visited.insert(current)
            pages += 1
            let html: String
            if current == bookID {
                html = bookHTML
            } else {
                html = try await fetch(current, method: "GET", body: nil, charset: nil)
            }
            let root = HTMLParser.parse(html)
            let ctx = EvalContext(base: baseURL, bookUrl: bookID)
            guard let tocRule = model.ruleToc, let listRule = tocRule.chapterList, !listRule.isEmpty else { break }
            let nodes = RuleEvaluator.elements(listRule, in: root, ctx: ctx)
            for node in nodes {
                var name = field(tocRule.chapterName, fallback: "text", in: node, ctx: ctx)
                var urlRaw = field(tocRule.chapterUrl, fallback: "href", in: node, ctx: ctx)
                if urlRaw.isEmpty {
                    urlRaw = RuleEvaluator.string("a@href", in: node, ctx: ctx)
                }
                guard !urlRaw.isEmpty else { continue }
                guard let resolved = Self.resolveURL(urlRaw, base: current) ?? Self.resolveURL(urlRaw, base: baseURL) else { continue }
                guard !seen.contains(resolved) else { continue }
                seen.insert(resolved)
                if name.isEmpty { name = "第\(chapters.count + 1)章" }
                chapters.append(SourceChapter(id: resolved, index: chapters.count + 1, title: name, isFree: true))
            }
            // 下一页目录
            if let nextRule = tocRule.nextTocUrl, !nextRule.isEmpty {
                let v = RuleEvaluator.string(nextRule, in: root, ctx: ctx)
                let nextRaw = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextRaw.isEmpty {
                    pageURL = nil
                } else {
                    pageURL = Self.resolveURL(nextRaw, base: current) ?? Self.resolveURL(nextRaw, base: baseURL)
                }
            } else {
                pageURL = nil
            }
        }

        guard !chapters.isEmpty else { throw SourceError.notFound }
        return chapters
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        guard let contentRule = model.ruleContent?.content, !contentRule.isEmpty else {
            throw SourceError.unsupported("该书源未配置正文规则")
        }
        var collected: [String] = []
        var visited = Set<String>()
        var current: String? = chapterID

        while let url = current, collected.count < 20, !visited.contains(url) {
            visited.insert(url)
            let html = try await fetch(url, method: "GET", body: nil, charset: nil)
            let root = HTMLParser.parse(html)
            let ctx = EvalContext(base: baseURL, bookUrl: bookID)
            let raw = RuleEvaluator.string(contentRule, in: root, ctx: ctx)
            let text = Self.normalizeContent(raw)
            if !text.isEmpty {
                collected.append(text)
            }
            // 翻页
            if let nextRule = model.ruleContent?.nextContentUrl, !nextRule.isEmpty {
                let v = RuleEvaluator.string(nextRule, in: root, ctx: ctx)
                let nextRaw = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextRaw.isEmpty || nextRaw == url {
                    current = nil
                } else {
                    current = Self.resolveURL(nextRaw, base: url) ?? Self.resolveURL(nextRaw, base: baseURL)
                }
            } else {
                current = nil
            }
        }

        var text = collected.joined(separator: "\n")
        // 净化规则
        if let rr = model.ruleContent?.replaceRegex, !rr.isEmpty {
            let fake = "X" + (rr.hasPrefix("##") ? rr : "##" + rr)
            let processed = RuleEvaluator.splitPostProcess(fake)
            text = RuleEvaluator.applyReplacers(text, processed.replacers)
        }
        guard !text.isEmpty else { throw SourceError.unsupported("该章正文为空(可能需登录或已下架)") }
        return text
    }

    // MARK: - 字段求值

    private func field(_ rule: String?, fallback: String, in node: HTMLNode, ctx: EvalContext) -> String {
        let r = (rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = r.isEmpty ? fallback : r
        guard !effective.isEmpty else { return "" }
        let v = RuleEvaluator.string(effective, in: node, ctx: ctx)
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 网络

    private func fetch(_ urlString: String, method: String, body: Data?, charset: String?) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SourceError.network("无效地址:\(urlString.prefix(80))")
        }
        var headers = extraHeaders
        if headers["Referer"] == nil, headers["referer"] == nil {
            headers["Referer"] = baseURL + "/"
        }
        let encoding = charset.flatMap { HTTP.TextEncoding(label: $0) }
        return try await HTTP.fetchHTML(
            url, session: session,
            headers: headers,
            method: method,
            body: body,
            encoding: encoding
        )
    }

    // MARK: - 静态工具(可测)

    struct URLOptions {
        var method: String?
        var body: String?
        var charset: String?
        var headers: [String: String]?
    }

    /// `url,{"method":"POST",...}` 拆分
    static func parseURLOptions(_ raw: String) -> (url: String, options: URLOptions) {
        guard let range = raw.range(of: ",{", options: .backwards) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), URLOptions())
        }
        let url = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonPart = String(raw[range.lowerBound...].dropFirst())
        guard let data = jsonPart.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), URLOptions())
        }
        var o = URLOptions()
        o.method = obj["method"] as? String
        o.body = obj["body"] as? String
        o.charset = obj["charset"] as? String
        if let h = obj["headers"] as? [String: String] {
            o.headers = h
        }
        return (url, o)
    }

    /// 模板变量展开({{key}} / {{page}} / {{baseUrl}})
    static func expand(_ template: String, key: String, page: String, base: String, encoding: HTTP.TextEncoding) -> String {
        var s = template
        if s.contains("{{key}}") {
            s = s.replacingOccurrences(of: "{{key}}", with: HTTP.percentEncode(key, encoding: encoding))
        }
        if s.contains("{{page}}") {
            s = s.replacingOccurrences(of: "{{page}}", with: page)
        }
        if s.contains("{{baseUrl}}") {
            s = s.replacingOccurrences(of: "{{baseUrl}}", with: base)
        }
        return s
    }

    static func encode(_ s: String, encoding: HTTP.TextEncoding) -> Data {
        switch encoding {
        case .utf8:
            return Data(s.utf8)
        case .gb18030:
            let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return (s as NSString).data(using: cfEncoding) ?? Data(s.utf8)
        }
    }

    /// 相对地址补全(含站点根 / 路径相对)
    static func resolveURL(_ raw: String, base: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        if v.hasPrefix("/") { return base + v }
        return base + "/" + v
    }

    /// 正文规范化:HTML → 段落文本;纯文本 → 行清洗
    static func normalizeContent(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.contains("<") {
            return HTMLText.paragraphs(fromHTML: s)
        }
        return HTMLText.normalizeLines(s)
    }
}
