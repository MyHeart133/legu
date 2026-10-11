import Foundation

/// 规则求值上下文
struct EvalContext {
    var base: String
    var vars: [String: String] = [:]
    var key: String = ""
    var page: String = "1"
    var bookUrl: String = ""
}

/// Legado 书源规则求值器
///
/// 支持:
/// - 默认规则:`class.x@tag.a.0@href` / `.bk@a` / `id.list@li[!0:2]@a`(索引 .0 / [N]、切片 [a:b]、排除 [!...])
/// - XPath 子集:`//div[@id='x']//a/@href`、`[property$=book_name]@content`
/// - CSS 子集:`@css:#pages .gr:not([href='#'])@href`
/// - 后处理:`##正则##替换`、`###正则`(删除全部)
/// - 组合:`||` 回退、`&&` 拼接
/// - `@js:`(JavaScriptCore)、`@get:{k}` / `@put:{...}`(书页内缓存)
enum RuleEvaluator {

    static let getters: Set<String> = [
        "text", "textNodes", "ownText", "html", "all", "outerHtml",
        "href", "src", "content", "title", "alt", "value", "id", "class",
    ]

    // MARK: - 字段规则(返回字符串)

    static func string(_ rule: String, in node: HTMLNode, ctx: EvalContext) -> String {
        var ctx = ctx
        return evalField(rule: rule, node: node, ctx: &ctx)
    }

    static func evalField(rule rawRule: String, node: HTMLNode, ctx: inout EvalContext) -> String {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return "" }

        // @put: 批量写入(init 用)
        if rule.hasPrefix("@put:") {
            applyPut(rule: rule, node: node, ctx: &ctx)
            return ""
        }
        if rule.hasPrefix("@get:") {
            return ctx.vars[braceKey(rule)] ?? ""
        }

        // @js: 规则(整条)
        if rule.hasPrefix("@js:") {
            let code = String(rule.dropFirst(4))
            let input = node.textContent()
            return JSBridge.evaluate(code, result: input, ctx: ctx)
        }
        // 含 @js: 的混合规则:先算前段,再进 JS
        if let jsRange = rule.range(of: "@js:") {
            let basePart = String(rule[..<jsRange.lowerBound])
            var jsPart = String(rule[jsRange.upperBound...])
            // JS 尾部可能挂 ## 后处理
            var replacers: [Replacer] = []
            if let hashRange = jsPart.range(of: "##") {
                let pp = splitPostProcess(String(jsPart[hashRange.lowerBound...]))
                replacers = pp.replacers
                jsPart = String(jsPart[..<hashRange.lowerBound])
            }
            let input = basePart.isEmpty ? node.textContent() : evalField(rule: basePart, node: node, ctx: &ctx)
            let out = JSBridge.evaluate(jsPart, result: input, ctx: ctx)
            return applyReplacers(out, replacers)
        }

        // || 回退
        let orParts = splitTop(rule, by: "||")
        if orParts.count > 1 {
            for part in orParts {
                let v = evalField(rule: part, node: node, ctx: &ctx)
                if !v.isEmpty { return v }
            }
            return ""
        }
        // && 拼接
        let andParts = splitTop(rule, by: "&&")
        if andParts.count > 1 {
            var values: [String] = []
            for part in andParts {
                let v = evalField(rule: part, node: node, ctx: &ctx)
                if !v.isEmpty { values.append(v) }
            }
            return values.joined(separator: "\n")
        }

        // ## 后处理
        let processed = splitPostProcess(rule)
        let result = evalBase(processed.base, node: node, ctx: &ctx)
        return applyReplacers(result, processed.replacers)
    }

    // MARK: - 列表规则(返回元素数组)

    static func elements(_ rule: String, in root: HTMLNode, ctx: EvalContext) -> [HTMLNode] {
        var ctx = ctx
        return evalList(rule: rule, root: root, ctx: &ctx)
    }

    static func evalList(rule rawRule: String, root: HTMLNode, ctx: inout EvalContext) -> [HTMLNode] {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return [] }
        if rule.hasPrefix("@js:") { return [] }

        // || 分支:取第一个非空结果
        let orParts = splitTop(rule, by: "||")
        if orParts.count > 1 {
            for part in orParts {
                let list = evalList(rule: part, root: root, ctx: &ctx)
                if !list.isEmpty { return list }
            }
            return []
        }

        // XPath
        if rule.hasPrefix("//") || rule.hasPrefix(".//") {
            return XPathEval.evaluate(rule, in: root)
        }
        // CSS
        if rule.hasPrefix("@css:") {
            let sel = String(rule.dropFirst(5))
            return CSSEval.select(sel, in: root)
        }

        // 默认链:全为选择器段
        var current: [HTMLNode] = [root]
        for segment in splitChain(rule) {
            let seg = segment.trimmingCharacters(in: .whitespaces)
            if seg.isEmpty { continue }
            if getters.contains(seg) { break }
            current = selectSegment(seg, from: current)
            if current.isEmpty { return [] }
        }
        return current
    }

    // MARK: - 基础求值(无 && / ||)

    static func evalBase(_ base: String, node: HTMLNode, ctx: inout EvalContext) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }

        // XPath
        if base.hasPrefix("//") || base.hasPrefix(".//") {
            return XPathEval.stringValue(base, in: node)
        }
        // CSS
        if base.hasPrefix("@css:") {
            var rest = String(base.dropFirst(5))
            var getter = "text"
            if let atRange = rest.range(of: "@"), String(rest[atRange.upperBound...]).range(of: "@") == nil {
                let maybeGetter = String(rest[atRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if getters.contains(maybeGetter) {
                    getter = maybeGetter
                    rest = String(rest[..<atRange.lowerBound])
                }
            }
            let nodes = CSSEval.select(rest, in: node)
            return applyGetter(getter, nodes: nodes)
        }

        // 默认链
        let segments = splitChain(base)
        var current: [HTMLNode] = [node]
        var pendingGetter: String? = nil
        for (i, raw) in segments.enumerated() {
            let seg = raw.trimmingCharacters(in: .whitespaces)
            if seg.isEmpty {
                if i == 0 { continue }
                continue
            }
            if getters.contains(seg) {
                pendingGetter = seg
                break
            }
            current = selectSegment(seg, from: current)
            if current.isEmpty { return "" }
        }
        let getter = pendingGetter ?? "text"
        return applyGetter(getter, nodes: current)
    }

    /// 取值器
    static func applyGetter(_ getter: String, nodes: [HTMLNode]) -> String {
        switch getter {
        case "text":
            guard let first = nodes.first else { return "" }
            let raw = first.textContent()
            return collapseText(raw)
        case "textNodes":
            guard let first = nodes.first else { return "" }
            var parts: [String] = []
            collectTextNodes(first, into: &parts)
            return parts
                .map { $0.replacingOccurrences(of: "[ \t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case "ownText":
            guard let first = nodes.first else { return "" }
            return collapseText(first.ownText())
        case "html":
            guard let first = nodes.first else { return "" }
            return first.innerHTML()
        case "all", "outerHtml":
            return nodes.map { $0.outerHTML() }.joined(separator: "\n")
        case "href", "src", "content", "title", "alt", "value", "id", "class":
            guard let first = nodes.first else { return "" }
            return first.attr(getter) ?? ""
        default:
            guard let first = nodes.first else { return "" }
            return collapseText(first.textContent())
        }
    }

    private static func collectTextNodes(_ node: HTMLNode, into parts: inout [String]) {
        for c in node.children {
            switch c.kind {
            case .text:
                parts.append(c.text)
            case .element:
                if c.tag == "br" {
                    parts.append("\n")
                } else {
                    collectTextNodes(c, into: &parts)
                }
            }
        }
    }

    /// 文本折叠:压缩行内空白,保留段落换行,去首尾
    static func collapseText(_ raw: String) -> String {
        let decoded = HTMLText.decodeEntities(raw)
        var s = decoded
        s = s.replacingOccurrences(of: "[ \t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 选择器段

    struct Segment {
        enum Base {
            case tag(String)
            case className(String)
            case id(String)
            case attr(AttrPredicate)
            case selfNode
        }
        var base: Base
        var index: Int? = nil
        var slice: (Int, Int)? = nil
        var exclude: (Int, Int)? = nil
    }

    static func parseSegment(_ raw: String) -> Segment {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var seg = Segment(base: .selfNode)

        // 尾部 [..](索引/切片/排除)——仅当前缀非空且内容形如索引时作为后缀
        if s.hasSuffix("]"), let open = s.lastIndex(of: "[") {
            let prefix = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            let inside = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            if !prefix.isEmpty, isIndexSpec(inside) {
                s = prefix
                if inside.hasPrefix("!") {
                    let body = String(inside.dropFirst())
                    if let colon = body.firstIndex(of: ":") {
                        let a = Int(body[..<colon]) ?? 0
                        let b = Int(body[body.index(after: colon)...]) ?? Int.max
                        seg.exclude = (a, b)
                    } else if let n = Int(body) {
                        seg.exclude = (n, n + 1)
                    }
                } else if let colon = inside.firstIndex(of: ":") {
                    let a = Int(inside[..<colon]) ?? 0
                    let b = Int(inside[inside.index(after: colon)...]) ?? Int.max
                    seg.slice = (a, b)
                } else if let n = Int(inside) {
                    seg.index = n
                }
            }
        }

        // 属性谓词 [attr op val](可带前导标签,如 a[href])
        if s.contains("["), s.hasSuffix("]"), let open = s.firstIndex(of: "[") {
            let inside = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            if let pred = parseAttrPredicate(inside), !inside.contains(":") {
                let head = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                if head.isEmpty {
                    seg.base = .attr(pred)
                    return seg
                }
                seg.base = parseTagHead(head)
                return seg
            }
        }

        // class. / . / id. / tag.
        if s.hasPrefix("class.") {
            var value = String(s.dropFirst(6))
            value = extractTrailingIndex(&value, into: &seg)
            seg.base = .className(value)
            return seg
        }
        if s.hasPrefix(".") {
            var value = String(s.dropFirst(1))
            value = extractTrailingIndex(&value, into: &seg)
            seg.base = .className(value)
            return seg
        }
        if s.hasPrefix("id.") {
            var value = String(s.dropFirst(3))
            value = extractTrailingIndex(&value, into: &seg)
            seg.base = .id(value)
            return seg
        }
        if s.hasPrefix("tag.") {
            var value = String(s.dropFirst(4))
            value = extractTrailingIndex(&value, into: &seg)
            seg.base = .tag(value.lowercased())
            return seg
        }
        // 纯标签
        var value = s
        value = extractTrailingIndex(&value, into: &seg)
        if value.isEmpty {
            seg.base = .selfNode
        } else {
            seg.base = .tag(value.lowercased())
        }
        return seg
    }

    /// 判断 [] 内容是否为索引/切片/排除说明(如 "1" / "0:2" / "!0:2")
    static func isIndexSpec(_ inside: String) -> Bool {
        if inside.isEmpty { return false }
        if inside.hasPrefix("!") {
            let body = String(inside.dropFirst())
            if Int(body) != nil { return true }
            if let colon = body.firstIndex(of: ":") {
                let a = String(body[..<colon])
                let b = String(body[body.index(after: colon)...])
                return (a.isEmpty || Int(a) != nil) && (b.isEmpty || Int(b) != nil)
            }
            return false
        }
        if Int(inside) != nil { return true }
        if let colon = inside.firstIndex(of: ":") {
            let a = String(inside[..<colon])
            let b = String(inside[inside.index(after: colon)...])
            return (a.isEmpty || Int(a) != nil) && (b.isEmpty || Int(b) != nil)
        }
        return false
    }

    private static func parseTagHead(_ head: String) -> Segment.Base {
        if head.hasPrefix("class.") { return .className(String(head.dropFirst(6))) }
        if head.hasPrefix("id.") { return .id(String(head.dropFirst(3))) }
        if head.hasPrefix("tag.") { return .tag(String(head.dropFirst(4)).lowercased()) }
        return .tag(head.lowercased())
    }

    /// "a.0" / "bookbox.2" → 提取尾部索引
    private static func extractTrailingIndex(_ value: inout String, into seg: inout Segment) -> String {
        guard let dot = value.lastIndex(of: ".") else { return value }
        let tail = String(value[value.index(after: dot)...])
        if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) {
            seg.index = Int(tail)
            value = String(value[..<dot])
        }
        return value
    }

    struct AttrPredicate {
        var name: String
        var op: String
        var value: String
    }

    static func parseAttrPredicate(_ inside: String) -> AttrPredicate? {
        let ops = ["!=", "$=", "^=", "*=", "~=", "="]
        for op in ops {
            if let r = inside.range(of: op) {
                let name = String(inside[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var value = String(inside[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !name.isEmpty, name != "text()" else { return nil }
                return AttrPredicate(name: name.lowercased(), op: op, value: value)
            }
        }
        // 只有属性名
        let name = inside.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !name.contains("(") {
            return AttrPredicate(name: name.lowercased(), op: "exists", value: "")
        }
        return nil
    }

    static func matchAttr(_ el: HTMLNode, _ pred: AttrPredicate) -> Bool {
        switch pred.op {
        case "exists":
            return el.hasAttr(pred.name)
        case "=":
            return el.attr(pred.name) == pred.value
        case "!=":
            return el.attr(pred.name) != pred.value
        case "^=":
            return el.attr(pred.name)?.hasPrefix(pred.value) ?? false
        case "$=":
            return el.attr(pred.name)?.hasSuffix(pred.value) ?? false
        case "*=", "~=":
            let alts = pred.value.components(separatedBy: "|")
            guard let v = el.attr(pred.name) else { return false }
            return alts.contains { v.contains($0) }
        default:
            return false
        }
    }

    /// 对一个元素应用一个选择器段
    static func selectOne(_ segment: String, in el: HTMLNode) -> [HTMLNode] {
        let seg = parseSegment(segment)
        var candidates: [HTMLNode]
        switch seg.base {
        case .selfNode:
            candidates = [el]
        case .tag(let t):
            candidates = el.getElementsByTag(t)
        case .className(let c):
            candidates = el.getElementsByClass(c)
        case .id(let i):
            candidates = el.getElementByID(i).map { [$0] } ?? []
        case .attr(let pred):
            candidates = el.allElements(includeSelf: true).filter { matchAttr($0, pred) }
        }
        // 排除 / 切片 / 索引
        if let ex = seg.exclude {
            candidates = candidates.enumerated().filter { !(($0.offset >= ex.0) && ($0.offset < ex.1)) }.map { $0.element }
        }
        if let sl = seg.slice {
            let a = max(0, sl.0)
            let b = min(candidates.count, sl.1)
            candidates = a < b ? Array(candidates[a..<b]) : []
        }
        if let idx = seg.index {
            let i = idx < 0 ? candidates.count + idx : idx
            candidates = (i >= 0 && i < candidates.count) ? [candidates[i]] : []
        }
        return candidates
    }

    static func selectSegment(_ segment: String, from elements: [HTMLNode]) -> [HTMLNode] {
        var out: [HTMLNode] = []
        for el in elements {
            out.append(contentsOf: selectOne(segment, in: el))
        }
        return out
    }

    // MARK: - 拆分工具

    /// 顶层拆分(&& / ||)
    static func splitTop(_ s: String, by sep: String) -> [String] {
        guard s.contains(sep) else { return [s] }
        var parts: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix(sep) {
                parts.append(current)
                current = ""
                i = s.index(i, offsetBy: sep.count)
            } else {
                current.append(s[i])
                i = s.index(after: i)
            }
        }
        parts.append(current)
        return parts
    }

    /// 按 @ 拆链(跳过 @js: / @css: / @get: / @put: 前缀整体)
    static func splitChain(_ s: String) -> [String] {
        if s.hasPrefix("@js:") || s.hasPrefix("@css:") || s.hasPrefix("@get:") || s.hasPrefix("@put:") {
            return [s]
        }
        var parts: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "@" {
                // @js: / @css: 之后的全部内容不拆
                let tail = s[i...]
                if tail.hasPrefix("@js:") || tail.hasPrefix("@css:") {
                    current.append(contentsOf: tail)
                    break
                }
                parts.append(current)
                current = ""
                i = s.index(after: i)
            } else {
                current.append(ch)
                i = s.index(after: i)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - 后处理 ##

    struct Replacer {
        var pattern: String
        var replacement: String
        var deleteOnly: Bool
    }

    static func splitPostProcess(_ rule: String) -> (base: String, replacers: [Replacer]) {
        guard rule.contains("##") else { return (rule, []) }
        let parts = rule.components(separatedBy: "##")
        let base = parts[0]
        var replacers: [Replacer] = []
        var i = 1
        while i < parts.count {
            var pattern = parts[i]
            var deleteOnly = false
            if pattern.hasPrefix("#") {
                // "###pattern" → 删除全部
                pattern = String(pattern.dropFirst())
                deleteOnly = true
            }
            if i + 1 < parts.count, !deleteOnly {
                replacers.append(Replacer(pattern: pattern, replacement: parts[i + 1], deleteOnly: false))
                i += 2
            } else {
                replacers.append(Replacer(pattern: pattern, replacement: "", deleteOnly: true))
                i += 1
            }
        }
        return (base, replacers)
    }

    static func applyReplacers(_ input: String, _ replacers: [Replacer]) -> String {
        var out = input
        for r in replacers where !r.pattern.isEmpty {
            if r.deleteOnly {
                out = HTMLText.removeAll(pattern: r.pattern, in: out)
            } else {
                out = HTMLText.replaceAll(pattern: r.pattern, replacement: r.replacement, in: out)
            }
        }
        return out
    }

    // MARK: - @put / @get

    static func applyPut(rule: String, node: HTMLNode, ctx: inout EvalContext) {
        let jsonText = String(rule.dropFirst(5))
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (k, v) in obj {
            ctx.vars[k] = evalField(rule: v, node: node, ctx: &ctx)
        }
    }

    static func braceKey(_ rule: String) -> String {
        guard let open = rule.firstIndex(of: "{"), let close = rule.lastIndex(of: "}") else { return "" }
        return String(rule[rule.index(after: open)..<close])
    }
}
