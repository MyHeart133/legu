import Foundation

/// XPath 子集求值器
///
/// 支持:`//tag`、`/child`、`[@attr]`、`[@attr='v']`(及 != ^= $= *= ~=)、
/// `[text()='v']`、`[contains(text(),'v')]`、`[N]`、`[last()]`、末尾 `/text()` 与 `/@attr`
enum XPathEval {

    struct Step {
        var descendant: Bool
        var tag: String            // "*" 表示任意元素
        var predicates: [String]
    }

    enum Final {
        case elements
        case text
        case attr(String)
    }

    // MARK: - 表达式解析

    static func parse(_ expr: String) -> (steps: [Step], final: Final)? {
        var s = expr.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(".//") { s = String(s.dropFirst(1)) }
        guard s.hasPrefix("//") || s.hasPrefix("/") else { return nil }

        var steps: [Step] = []
        var final: Final = .elements
        var i = s.startIndex

        while i < s.endIndex {
            var descendant = false
            if s[i...].hasPrefix("//") {
                descendant = true
                i = s.index(i, offsetBy: 2)
            } else if s[i] == "/" {
                descendant = false
                i = s.index(after: i)
            } else {
                return nil
            }
            // 读取一步(直到下一个不在括号/引号内的 '/')
            var stepText = ""
            var bracketDepth = 0
            var quote: Character? = nil
            while i < s.endIndex {
                let ch = s[i]
                if let q = quote {
                    if ch == q { quote = nil }
                    stepText.append(ch)
                } else if ch == "'" || ch == "\"" {
                    quote = ch
                    stepText.append(ch)
                } else if ch == "[" {
                    bracketDepth += 1
                    stepText.append(ch)
                } else if ch == "]" {
                    bracketDepth -= 1
                    stepText.append(ch)
                } else if ch == "/" && bracketDepth == 0 {
                    break
                } else {
                    stepText.append(ch)
                }
                i = s.index(after: i)
            }
            stepText = stepText.trimmingCharacters(in: .whitespaces)
            if stepText.isEmpty { continue }

            if stepText.hasPrefix("@") {
                final = .attr(String(stepText.dropFirst()))
                break
            }
            if stepText == "text()" || stepText.hasPrefix("text()") {
                final = .text
                break
            }
            // tag + predicates
            var tag = stepText
            var predicates: [String] = []
            if let open = stepText.firstIndex(of: "[") {
                tag = String(stepText[..<open]).trimmingCharacters(in: .whitespaces)
                predicates = extractBrackets(String(stepText[open...]))
            }
            steps.append(Step(descendant: descendant, tag: tag.isEmpty ? "*" : tag.lowercased(), predicates: predicates))
        }
        guard !steps.isEmpty else { return nil }
        return (steps, final)
    }

    private static func extractBrackets(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        var quote: Character? = nil
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
                if depth >= 1 { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                if depth >= 1 { current.append(ch) }
                continue
            }
            if ch == "[" {
                if depth >= 1 { current.append(ch) }
                depth += 1
                continue
            }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    out.append(current)
                    current = ""
                } else if depth >= 1 {
                    current.append(ch)
                }
                continue
            }
            if depth >= 1 { current.append(ch) }
        }
        return out
    }

    // MARK: - 求值

    static func evaluate(_ expr: String, in root: HTMLNode) -> [HTMLNode] {
        guard let (steps, final) = parse(expr) else { return [] }
        var current: [HTMLNode] = [root]
        for step in steps {
            var next: [HTMLNode] = []
            for el in current {
                let pool: [HTMLNode]
                if step.descendant {
                    pool = el.allElements(includeSelf: false)
                } else {
                    pool = el.children.filter { $0.kind == .element }
                }
                var matched = step.tag == "*" ? pool : pool.filter { $0.tag == step.tag }
                matched = applyPredicates(matched, predicates: step.predicates)
                next.append(contentsOf: matched)
            }
            current = dedupe(next)
            if current.isEmpty { return [] }
        }
        switch final {
        case .elements:
            return current
        case .text, .attr:
            return current
        }
    }

    /// 字段值:第一个匹配元素的文本 / 属性
    static func stringValue(_ expr: String, in node: HTMLNode) -> String {
        guard let (steps, final) = parse(expr) else { return "" }
        var current: [HTMLNode] = [node]
        for step in steps {
            var next: [HTMLNode] = []
            for el in current {
                let pool: [HTMLNode]
                if step.descendant {
                    pool = el.allElements(includeSelf: false)
                } else {
                    pool = el.children.filter { $0.kind == .element }
                }
                var matched = step.tag == "*" ? pool : pool.filter { $0.tag == step.tag }
                matched = applyPredicates(matched, predicates: step.predicates)
                next.append(contentsOf: matched)
            }
            current = dedupe(next)
            if current.isEmpty { return "" }
        }
        switch final {
        case .elements:
            guard let first = current.first else { return "" }
            return RuleEvaluator.collapseText(first.textContent())
        case .text:
            let texts = current.map { RuleEvaluator.collapseText($0.textContent()) }.filter { !$0.isEmpty }
            return texts.first ?? ""
        case .attr(let name):
            for el in current {
                if let v = el.attr(name) { return v }
            }
            return ""
        }
    }

    static func applyPredicates(_ nodes: [HTMLNode], predicates: [String]) -> [HTMLNode] {
        var result = nodes
        for raw in predicates {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            // 索引
            if let n = Int(p) {
                let idx = n - 1
                result = (idx >= 0 && idx < result.count) ? [result[idx]] : []
                continue
            }
            if p == "last()" {
                result = result.last.map { [$0] } ?? []
                continue
            }
            // text() 比较
            if p.hasPrefix("text()") {
                let tail = p.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if tail.hasPrefix("=") {
                    let v = cleanValue(String(tail.dropFirst()))
                    result = result.filter { RuleEvaluator.collapseText($0.textContent()) == v }
                } else if tail.isEmpty {
                    result = result.filter { !RuleEvaluator.collapseText($0.textContent()).isEmpty }
                }
                continue
            }
            if p.hasPrefix("contains(") {
                let inner = String(p.dropFirst(9).dropLast(1))
                if let comma = inner.firstIndex(of: ",") {
                    let target = String(inner[..<comma]).trimmingCharacters(in: .whitespaces)
                    let v = cleanValue(String(inner[inner.index(after: comma)...]))
                    if target == "text()" {
                        result = result.filter { RuleEvaluator.collapseText($0.textContent()).contains(v) }
                    } else if target.hasPrefix("@") {
                        let attr = String(target.dropFirst())
                        result = result.filter { ($0.attr(attr) ?? "").contains(v) }
                    }
                }
                continue
            }
            // 属性谓词
            var attrSpec = p
            if attrSpec.hasPrefix("@") {
                attrSpec = String(attrSpec.dropFirst())
            }
            if let pred = RuleEvaluator.parseAttrPredicate(attrSpec) {
                result = result.filter { RuleEvaluator.matchAttr($0, pred) }
                continue
            }
        }
        return result
    }

    private static func cleanValue(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return v
    }

    static func dedupe(_ nodes: [HTMLNode]) -> [HTMLNode] {
        var seen = Set<ObjectIdentifier>()
        var out: [HTMLNode] = []
        for n in nodes where !seen.contains(ObjectIdentifier(n)) {
            seen.insert(ObjectIdentifier(n))
            out.append(n)
        }
        return out
    }
}

/// CSS 选择器子集求值器
///
/// 支持:`tag`、`.class`、`#id`、`[attr=value]`、后代与 `>` 子代、`:not(简单选择器)`
enum CSSEval {

    struct Compound {
        var tag: String? = nil
        var id: String? = nil
        var classes: [String] = []
        var attrs: [RuleEvaluator.AttrPredicate] = []
        var nots: [Compound] = []
    }

    static func select(_ selector: String, in root: HTMLNode) -> [HTMLNode] {
        let tokens = tokenize(selector)
        guard !tokens.isEmpty else { return [] }
        var current: [HTMLNode] = [root]
        var childOnly = false
        for token in tokens {
            if token == ">" {
                childOnly = true
                continue
            }
            let compound = parseCompound(token)
            var next: [HTMLNode] = []
            for el in current {
                let pool: [HTMLNode]
                if childOnly {
                    pool = el.children.filter { $0.kind == .element }
                } else {
                    pool = el.allElements(includeSelf: false)
                }
                next.append(contentsOf: pool.filter { matches($0, compound) })
            }
            current = XPathEval.dedupe(next)
            childOnly = false
            if current.isEmpty { return [] }
        }
        return current
    }

    static func tokenize(_ selector: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var bracketDepth = 0
        var quote: Character? = nil
        for ch in selector {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == "(" { bracketDepth += 1; current.append(ch); continue }
            if ch == ")" { bracketDepth -= 1; current.append(ch); continue }
            if ch == "[" { bracketDepth += 1; current.append(ch); continue }
            if ch == "]" { bracketDepth -= 1; current.append(ch); continue }
            if (ch == " " || ch == "\t" || ch == "\n" || ch == ">") && bracketDepth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
                if ch == ">" { tokens.append(">") }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func parseCompound(_ s: String) -> Compound {
        var c = Compound()
        var i = s.startIndex
        var tagRead = false
        while i < s.endIndex {
            let ch = s[i]
            if ch == "." {
                var name = ""
                var j = s.index(after: i)
                while j < s.endIndex, s[j] != ".", s[j] != "#", s[j] != "[", s[j] != ":" {
                    name.append(s[j])
                    j = s.index(after: j)
                }
                if !name.isEmpty { c.classes.append(name) }
                i = j
            } else if ch == "#" {
                var name = ""
                var j = s.index(after: i)
                while j < s.endIndex, s[j] != ".", s[j] != "#", s[j] != "[", s[j] != ":" {
                    name.append(s[j])
                    j = s.index(after: j)
                }
                c.id = name
                i = j
            } else if ch == "[" {
                if let close = s[i...].firstIndex(of: "]") {
                    let inside = String(s[s.index(after: i)..<close])
                    if let pred = RuleEvaluator.parseAttrPredicate(inside) {
                        c.attrs.append(pred)
                    }
                    i = s.index(after: close)
                } else {
                    i = s.index(after: i)
                }
            } else if ch == ":" {
                // :not(...) 或伪类(忽略其它伪类)
                if s[i...].hasPrefix(":not(") {
                    if let open = s[i...].firstIndex(of: "(") {
                        var depth = 0
                        var j = open
                        var inner = ""
                        while j < s.endIndex {
                            let cj = s[j]
                            if cj == "(" { depth += 1 }
                            if cj == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            if depth >= 1 && cj != "(" { inner.append(cj) }
                            j = s.index(after: j)
                        }
                        c.nots.append(parseCompound(inner))
                        i = j < s.endIndex ? s.index(after: j) : j
                    } else {
                        i = s.index(after: i)
                    }
                } else {
                    // 其它伪类:跳到下一个边界
                    var j = s.index(after: i)
                    while j < s.endIndex, s[j] != ".", s[j] != "#", s[j] != "[", s[j] != ":" {
                        j = s.index(after: j)
                    }
                    i = j
                }
            } else {
                var name = ""
                var j = i
                while j < s.endIndex, s[j] != ".", s[j] != "#", s[j] != "[", s[j] != ":" {
                    name.append(s[j])
                    j = s.index(after: j)
                }
                if !tagRead {
                    c.tag = name.lowercased()
                    tagRead = true
                }
                i = j
            }
        }
        return c
    }

    static func matches(_ el: HTMLNode, _ c: Compound) -> Bool {
        if let t = c.tag, !t.isEmpty, t != "*", el.tag != t { return false }
        if let id = c.id, el.attr("id") != id { return false }
        if !c.classes.isEmpty {
            guard let cls = el.attr("class") else { return false }
            let set = Set(cls.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { String($0) })
            for need in c.classes where !set.contains(need) { return false }
        }
        for attr in c.attrs where !RuleEvaluator.matchAttr(el, attr) { return false }
        for not in c.nots where matches(el, not) { return false }
        return true
    }
}
