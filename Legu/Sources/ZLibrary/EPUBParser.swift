import Foundation

/// EPUB 解析:zip → container.xml → OPF(spine/manifest)→ 章节(标题 + 正文)
enum EPUBParser {

    struct ParsedBook {
        var title: String
        var author: String
        var chapters: [(title: String, text: String)]
    }

    static func parse(_ data: Data) throws -> ParsedBook {
        let files = try MiniZip.read(data)

        guard let containerData = files["META-INF/container.xml"],
              let container = decodeText(containerData),
              let opfPathRaw = HTMLText.firstCapture(pattern: "full-path=\"([^\"]+)\"", in: container) else {
            throw MiniZip.ZipError.badEntry("META-INF/container.xml")
        }
        let opfPath = normalizePath(opfPathRaw.removingPercentEncoding ?? opfPathRaw)
        guard let opfData = files[opfPath], let opf = decodeText(opfData) else {
            throw MiniZip.ZipError.badEntry(opfPath)
        }

        let title = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "<dc:title[^>]*>([^<]*)</dc:title>", in: opf) ?? "未命名"
        )
        let author = HTMLText.cleanInline(
            HTMLText.firstCapture(pattern: "<dc:creator[^>]*>([^<]*)</dc:creator>", in: opf) ?? ""
        )

        // manifest: id → href / properties
        var manifest: [String: String] = [:]
        var props: [String: String] = [:]
        for tag in HTMLText.allCaptures(pattern: "(<item\\b[^>]*/?>)", in: opf) {
            guard let id = attribute("id", in: tag), let href = attribute("href", in: tag) else { continue }
            manifest[id] = href
            props[id] = attribute("properties", in: tag) ?? ""
        }

        // spine 顺序
        var spine: [String] = []
        for tag in HTMLText.allCaptures(pattern: "(<itemref\\b[^>]*/?>)", in: opf) {
            if let idref = attribute("idref", in: tag) { spine.append(idref) }
        }

        let baseDir = (opfPath as NSString).deletingLastPathComponent

        // 目录标题:NCX 或 EPUB3 nav
        var tocTitles: [String: String] = [:]
        if let ncxHref = manifest.first(where: { $0.value.lowercased().hasSuffix(".ncx") })?.value,
           let ncxData = files[normalizePath(resolve(ncxHref, base: baseDir))],
           let ncx = decodeText(ncxData) {
            for g in allMatchGroups(pattern: "<navPoint[^>]*>.*?<text>(.*?)</text>.*?src=\"([^\"]+)\"", in: ncx) {
                guard g.count >= 3 else { continue }
                let t = HTMLText.cleanInline(g[1])
                let src = normalizePath(resolve(g[2], base: baseDir))
                if !t.isEmpty, tocTitles[src] == nil { tocTitles[src] = t }
            }
        }
        if tocTitles.isEmpty,
           let navHref = manifest.first(where: { props[$0.key]?.contains("nav") == true })?.value,
           let navData = files[normalizePath(resolve(navHref, base: baseDir))],
           let nav = decodeText(navData) {
            for g in allMatchGroups(pattern: "<a\\b[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", in: nav) {
                guard g.count >= 3 else { continue }
                let src = normalizePath(resolve(g[1], base: baseDir))
                let t = HTMLText.cleanInline(g[2])
                if !t.isEmpty, tocTitles[src] == nil { tocTitles[src] = t }
            }
        }

        // 逐章提取
        var chapters: [(title: String, text: String)] = []
        for idref in spine {
            guard let href = manifest[idref] else { continue }
            let path = normalizePath(resolve(href, base: baseDir))
            guard let fileData = files[path], let xhtml = decodeText(fileData) else { continue }
            let (chapterTitle, text) = extractChapter(xhtml, ncxTitle: tocTitles[path])
            guard text.count >= 8 else { continue }  // 跳过封面/版权等空页
            let finalTitle = chapterTitle.isEmpty ? "第 \(chapters.count + 1) 节" : chapterTitle
            chapters.append((finalTitle, text))
        }
        guard !chapters.isEmpty else { throw MiniZip.ZipError.badEntry("没有可读章节") }

        return ParsedBook(title: title, author: author, chapters: chapters)
    }

    // MARK: - 单章

    static func extractChapter(_ xhtml: String, ncxTitle: String?) -> (title: String, text: String) {
        var title = ncxTitle ?? ""
        if title.isEmpty, let h = firstHeadingText(xhtml) { title = h }
        if title.isEmpty,
           let t = HTMLText.firstCapture(pattern: "<title[^>]*>(.*?)</title>", in: xhtml) {
            let cleaned = HTMLText.cleanInline(t)
            if !cleaned.isEmpty, cleaned.lowercased() != "contents" { title = cleaned }
        }

        var body = xhtml
        body = HTMLText.removeAll(pattern: "(?is)<head.*?</head>", in: body)
        body = HTMLText.removeAll(pattern: "(?is)<style.*?</style>", in: body)
        body = HTMLText.removeAll(pattern: "(?is)<script.*?</script>", in: body)
        body = HTMLText.removeAll(pattern: "(?is)<svg.*?</svg>", in: body)
        body = stripFirstHeading(body, ifEquals: title)

        body = HTMLText.replaceAll(pattern: "(?i)<br\\s*/?>", replacement: "\n", in: body)
        body = HTMLText.replaceAll(pattern: "(?i)</p\\s*>", replacement: "\n", in: body)
        body = HTMLText.replaceAll(pattern: "(?i)</div\\s*>", replacement: "\n", in: body)
        body = HTMLText.replaceAll(pattern: "(?i)</h[1-6]\\s*>", replacement: "\n", in: body)
        body = HTMLText.replaceAll(pattern: "(?i)</li\\s*>", replacement: "\n", in: body)
        body = HTMLText.removeAll(pattern: "<[^>]+>", in: body)
        body = HTMLText.decodeEntities(body)
        let text = HTMLText.normalizeLines(body)
        return (title, text)
    }

    // MARK: - 工具

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        HTMLText.firstCapture(pattern: "\\b\(name)=\"([^\"]*)\"", in: tag)
            ?? HTMLText.firstCapture(pattern: "\\b\(name)='([^']*)'", in: tag)
    }

    static func resolve(_ href: String, base: String) -> String {
        let clean = href.components(separatedBy: "#")[0]
        guard !base.isEmpty else { return clean }
        return base + "/" + clean
    }

    /// 归一化路径(处理 ./ 与 ../)
    static func normalizePath(_ p: String) -> String {
        var parts: [String] = []
        for seg in p.components(separatedBy: "/") {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(seg)
        }
        return parts.joined(separator: "/")
    }

    private static func firstHeadingText(_ html: String) -> String? {
        guard let m = firstMatch(pattern: "(?is)<h[1-6][^>]*>(.*?)</h[1-6]>", in: html), m.count >= 2 else {
            return nil
        }
        let t = HTMLText.cleanInline(m[1])
        return t.isEmpty ? nil : t
    }

    private static func stripFirstHeading(_ html: String, ifEquals title: String) -> String {
        guard !title.isEmpty,
              let rx = try? NSRegularExpression(pattern: "(?is)<h[1-6][^>]*>(.*?)</h[1-6]>") else { return html }
        let ns = html as NSString
        guard let m = rx.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return html }
        let inner = ns.substring(with: m.range(at: 1))
        if HTMLText.cleanInline(inner) == title {
            return ns.replacingCharacters(in: m.range, with: "")
        }
        return html
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }

    private static func allMatchGroups(pattern: String, in text: String) -> [[String]] {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }
}
