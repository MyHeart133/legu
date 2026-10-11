import Foundation

/// HTML 文本工具:实体解码、标签剥离、meta 提取、正则与 JSON 助手
enum HTMLText {

    // MARK: - 实体

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = decodeEntity(entity) {
                    out.append(decoded)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "middot": "·", "bull": "•",
        "copy": "©", "reg": "®", "trade": "™", "times": "×", "divide": "÷",
        "laquo": "«", "raquo": "»", "deg": "°", "plusmn": "±", "sect": "§", "para": "¶",
    ]

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.isEmpty { return nil }
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body)
            }
            if let v = value, let scalar = UnicodeScalar(v) {
                return String(scalar)
            }
            return nil
        }
        return namedEntities[entity.lowercased()]
    }

    // MARK: - HTML → 文本

    /// 去除标签、解码实体,块级标签与 br 转行,逐行清洗
    static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<script.*?</script>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style.*?</style>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</div\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return normalizeLines(s)
    }

    /// 行级规范化:压缩行内空白、丢弃空行(含 \r 与全角空格伪空行)
    static func normalizeLines(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \t\r\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 单行文本清理(标题/作者等):去标签 + 实体 + 压缩空白
    static func cleanInline(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[\\s\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 段落文本:按 <p>/<br> 分段,逐段清洗(保留换行结构)
    static func paragraphs(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<script.*?</script>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        return normalizeLines(s)
    }

    // MARK: - 元数据 / URL

    /// 读取 `<meta property="..."|name="...">` 的 content
    static func metaContent(_ html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        if let v = firstCapture(pattern: "<meta[^>]+property=\"\(escaped)\"[^>]+content=\"([^\"]*)\"", in: html) {
            return decodeEntities(v)
        }
        if let v = firstCapture(pattern: "<meta[^>]+content=\"([^\"]*)\"[^>]+property=\"\(escaped)\"", in: html) {
            return decodeEntities(v)
        }
        if let v = firstCapture(pattern: "<meta[^>]+name=\"\(escaped)\"[^>]+content=\"([^\"]*)\"", in: html) {
            return decodeEntities(v)
        }
        return nil
    }

    /// 相对路径补全为绝对 URL
    static func absoluteURL(_ value: String, base: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        if v.hasPrefix("/") { return base + v }
        return base + "/" + v
    }

    /// 归一化书名(比对用)
    static func normalizedKey(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: "[\\s·・、,，.。:：!！?？\"'“”‘’《》()()【】\\[\\]-]+",
            with: "",
            options: .regularExpression
        )
        return stripped.lowercased()
    }

    // MARK: - 正则

    static func firstCapture(pattern: String, in text: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func allCaptures(pattern: String, in text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 正则替换(全部匹配);replacement 支持 $1 组引用
    static func replaceAll(pattern: String, replacement: String, in text: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return rx.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: replacement
        )
    }

    /// 正则删除全部匹配
    static func removeAll(pattern: String, in text: String) -> String {
        replaceAll(pattern: pattern, replacement: "", in: text)
    }

    // MARK: - 内嵌 JSON 状态(SSR)

    static func extractState(
        from html: String,
        marker: String = "__INITIAL_STATE__="
    ) -> [String: Any]? {
        guard let range = html.range(of: marker) else { return nil }
        guard let slice = balancedJSONSlice(in: html, from: range.upperBound) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    static func balancedJSONSlice(in text: String, from start: String.Index) -> Substring? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return text[open...index]
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - JSON 取值助手

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any]? { v as? [Any] }

    static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(Int(d)) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func flag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
}
