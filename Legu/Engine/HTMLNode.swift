import Foundation

/// 轻量容错 HTML 解析器 + DOM 查询
///
/// - 按 UTF-8 字节扫描(标签语法全为 ASCII),文本按 UTF-8 还原
/// - 容错:未闭合标签自动收尾、错配闭合标签向上寻配、script/style 内容整体跳过
/// - 实体在读取时解码(textContent / attr),序列化时保留原文
final class HTMLNode {
    enum Kind {
        case element
        case text
    }

    let kind: Kind
    var tag: String
    var attrs: [String: String]
    var text: String
    private(set) var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(element tag: String, attrs: [String: String] = [:]) {
        self.kind = .element
        self.tag = tag
        self.attrs = attrs
        self.text = ""
    }

    init(text: String) {
        self.kind = .text
        self.tag = ""
        self.attrs = [:]
        self.text = text
    }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    // MARK: - 查询

    /// 全部元素节点(先序),可选包含自身
    func allElements(includeSelf: Bool = true) -> [HTMLNode] {
        var out: [HTMLNode] = []
        var stack: [HTMLNode] = includeSelf ? [self] : children.reversed()
        if !includeSelf {
            // 展开为栈序
            stack = []
            for c in children.reversed() where c.kind == .element { stack.append(c) }
        }
        while let node = stack.popLast() {
            if node.kind == .element {
                out.append(node)
                for c in node.children.reversed() where c.kind == .element {
                    stack.append(c)
                }
            }
        }
        return out
    }

    /// 按标签名(自身 + 后代,文档序)
    func getElementsByTag(_ tag: String) -> [HTMLNode] {
        let t = tag.lowercased()
        guard !t.isEmpty else { return [] }
        return allElements(includeSelf: true).filter { $0.tag == t }
    }

    /// 按 class(后代;多个 class 以空格分隔时须全部命中)
    func getElementsByClass(_ classes: String) -> [HTMLNode] {
        let tokens = classes.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
        guard !tokens.isEmpty else { return [] }
        return allElements(includeSelf: false).filter { el in
            guard let cls = el.attr("class") else { return false }
            let set = Set(cls.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { String($0) })
            return tokens.allSatisfy { set.contains($0) }
        }
    }

    /// 按 id(自身 + 后代)
    func getElementByID(_ id: String) -> HTMLNode? {
        allElements(includeSelf: true).first { $0.attr("id") == id }
    }

    // MARK: - 属性 / 文本

    func attr(_ name: String) -> String? {
        guard let raw = attrs[name.lowercased()] else { return nil }
        return HTMLText.decodeEntities(raw)
    }

    func hasAttr(_ name: String) -> Bool {
        attrs[name.lowercased()] != nil
    }

    /// 全部文本(含后代;br 转行;实体解码)
    func textContent() -> String {
        var out = ""
        appendText(into: &out)
        return out
    }

    private func appendText(into out: inout String) {
        switch kind {
        case .text:
            out += HTMLText.decodeEntities(text)
        case .element:
            if tag == "br" {
                out += "\n"
                return
            }
            for c in children {
                c.appendText(into: &out)
            }
        }
    }

    /// 自身直接子文本(不含后代元素文本)
    func ownText() -> String {
        var out = ""
        for c in children where c.kind == .text {
            out += HTMLText.decodeEntities(c.text)
        }
        return out
    }

    /// 内部 HTML 序列化
    func innerHTML() -> String {
        var out = ""
        appendInner(into: &out)
        return out
    }

    private func appendInner(into out: inout String) {
        for c in children {
            switch c.kind {
            case .text:
                out += c.text
            case .element:
                out += c.outerHTML()
            }
        }
    }

    /// 外部 HTML 序列化(含自身标签)
    func outerHTML() -> String {
        switch kind {
        case .text:
            return text
        case .element:
            var out = "<" + tag
            for (k, v) in attrs {
                out += " \(k)=\"\(v)\""
            }
            if HTMLParser.voidTags.contains(tag) {
                out += ">"
                return out
            }
            out += ">"
            appendInner(into: &out)
            out += "</" + tag + ">"
            return out
        }
    }
}

// MARK: - 解析器

enum HTMLParser {
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    private static let autoCloseTags: Set<String> = [
        "li", "td", "tr", "th", "option", "p", "dt", "dd", "thead", "tbody",
    ]

    private static let rawTextTags: Set<String> = ["script", "style"]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(element: "document")
        var stack: [HTMLNode] = [root]
        let bytes = Array(html.utf8)
        let n = bytes.count
        var pos = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let slice = bytes[textStart..<end]
            let s = String(decoding: slice, as: UTF8.self)
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stack[stack.count - 1].append(HTMLNode(text: s))
            }
        }

        func indexOf(_ byte: UInt8, from: Int) -> Int? {
            var i = from
            while i < n {
                if bytes[i] == byte { return i }
                i += 1
            }
            return nil
        }

        func isWS(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }

        while pos < n {
            guard let lt = indexOf(0x3C, from: pos) else {
                flushText(upTo: n)
                break
            }
            flushText(upTo: lt)

            guard lt + 1 < n else {
                // 尾部孤立的 '<'
                stack[stack.count - 1].append(HTMLNode(text: "<"))
                textStart = lt + 1
                pos = lt + 1
                continue
            }

            let next = bytes[lt + 1]
            if next == 0x21 { // <!-- 注释 / <!DOCTYPE
                if lt + 3 < n, bytes[lt + 2] == 0x2D, bytes[lt + 3] == 0x2D {
                    // 注释:跳到 -->
                    if let end = findSequence(bytes, from: lt + 4, pattern: [0x2D, 0x2D, 0x3E]) {
                        pos = end + 3
                    } else {
                        pos = n
                    }
                } else {
                    if let gt = indexOf(0x3E, from: lt + 2) {
                        pos = gt + 1
                    } else {
                        pos = n
                    }
                }
                textStart = pos
                continue
            }

            if next == 0x2F { // 闭合标签
                guard let gt = indexOf(0x3E, from: lt + 2) else {
                    pos = n
                    break
                }
                let name = String(decoding: bytes[(lt + 2)..<gt], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !name.isEmpty {
                    // 向上寻找匹配的开放标签
                    if let idx = stack.lastIndex(where: { $0.tag == name }) {
                        if idx > 0 {
                            stack.removeSubrange(idx..<stack.count)
                        }
                    }
                }
                pos = gt + 1
                textStart = pos
                continue
            }

            // 开放标签:解析名称
            var i = lt + 1
            var nameEnd = i
            while nameEnd < n {
                let b = bytes[nameEnd]
                if isWS(b) || b == 0x2F || b == 0x3E { break }
                nameEnd += 1
            }
            let rawName = String(decoding: bytes[i..<nameEnd], as: UTF8.self).lowercased()
            guard !rawName.isEmpty, rawName.first.map({ $0.isLetter }) == true else {
                // 不是合法标签(如 "<3"),按文本处理
                textStart = lt
                pos = lt + 1
                continue
            }

            // 解析属性
            var attrs: [String: String] = [:]
            var selfClose = false
            i = nameEnd
            var closed = false
            while i < n {
                while i < n, isWS(bytes[i]) { i += 1 }
                guard i < n else { break }
                let b = bytes[i]
                if b == 0x3E {
                    i += 1
                    closed = true
                    break
                }
                if b == 0x2F {
                    selfClose = true
                    i += 1
                    continue
                }
                // 属性名
                var aEnd = i
                while aEnd < n {
                    let ab = bytes[aEnd]
                    if ab == 0x3D || isWS(ab) || ab == 0x2F || ab == 0x3E { break }
                    aEnd += 1
                }
                let aName = String(decoding: bytes[i..<aEnd], as: UTF8.self).lowercased()
                i = aEnd
                while i < n, isWS(bytes[i]) { i += 1 }
                var aValue = ""
                if i < n, bytes[i] == 0x3D {
                    i += 1
                    while i < n, isWS(bytes[i]) { i += 1 }
                    if i < n, bytes[i] == 0x22 || bytes[i] == 0x27 {
                        let quote = bytes[i]
                        i += 1
                        var vEnd = i
                        while vEnd < n, bytes[vEnd] != quote { vEnd += 1 }
                        aValue = String(decoding: bytes[i..<min(vEnd, n)], as: UTF8.self)
                        i = min(vEnd + 1, n)
                    } else {
                        var vEnd = i
                        while vEnd < n {
                            let vb = bytes[vEnd]
                            if isWS(vb) || vb == 0x3E { break }
                            vEnd += 1
                        }
                        aValue = String(decoding: bytes[i..<vEnd], as: UTF8.self)
                        i = vEnd
                    }
                }
                if !aName.isEmpty {
                    attrs[aName] = aValue
                }
            }
            guard closed else {
                // 标签未闭合到行尾,放弃解析该标签
                textStart = lt
                pos = lt + 1
                continue
            }

            // 自动闭合:同名标签嵌套(li/td/p 等)
            if autoCloseTags.contains(rawName), stack.last?.tag == rawName {
                stack.removeLast()
            }

            let node = HTMLNode(element: rawName, attrs: attrs)
            stack[stack.count - 1].append(node)

            let isVoid = selfClose || voidTags.contains(rawName)
            if rawTextTags.contains(rawName) {
                // script/style:跳过全部内容
                if let closeRange = findCloseTag(bytes, from: i, tag: rawName) {
                    pos = closeRange
                } else {
                    pos = n
                }
                textStart = pos
                continue
            }
            if !isVoid {
                stack.append(node)
            }
            pos = i
            textStart = pos
        }

        return root
    }

    private static func findSequence(_ bytes: [UInt8], from: Int, pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty else { return nil }
        var i = from
        let n = bytes.count
        while i + pattern.count <= n {
            var match = true
            for (k, p) in pattern.enumerated() where bytes[i + k] != p {
                match = false
                break
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    /// 找到 `</tag` 的结束位置(返回 `>` 之后的下标)
    private static func findCloseTag(_ bytes: [UInt8], from: Int, tag: String) -> Int? {
        let pattern = Array("</\(tag)".utf8)
        var i = from
        let n = bytes.count
        while i + pattern.count <= n {
            var match = true
            for (k, p) in pattern.enumerated() {
                let b = bytes[i + k]
                // 大小写不敏感
                let lower = (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
                if lower != p { match = false; break }
            }
            if match {
                var j = i + pattern.count
                while j < n, bytes[j] != 0x3E { j += 1 }
                return min(j + 1, n)
            }
            i += 1
        }
        return nil
    }
}
