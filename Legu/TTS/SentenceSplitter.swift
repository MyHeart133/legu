import Foundation

/// 朗读断句:按中文标点切句,过长按限长硬切
enum SentenceSplitter {

    static let enders: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    static let closers: Set<Character> = ["」", "』", "\u{201D}", "\u{2019}", "）", ")", "】", "》", "〉", "〕"]

    /// 切句(段落先规范化;单句限长 maxLength)
    static func split(_ text: String, maxLength: Int = 140) -> [String] {
        let paragraphs = ContentText.paragraphs(from: text)
        var result: [String] = []
        for paragraph in paragraphs {
            let chars = Array(paragraph)
            var current = ""
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                current.append(ch)
                var ended = false
                if enders.contains(ch) {
                    // 连续句末标点与收尾标点一并归句(如 "……?" 与 "。」")
                    var j = i + 1
                    while j < chars.count, enders.contains(chars[j]) || closers.contains(chars[j]) {
                        current.append(chars[j])
                        j += 1
                    }
                    i = j - 1
                    ended = true
                }
                if ended || current.count >= maxLength {
                    appendIfNotEmpty(&result, current)
                    current = ""
                }
                i += 1
            }
            appendIfNotEmpty(&result, current)
        }
        return result
    }

    /// 每句在规范化(渲染)全文中的起始 UTF-16 偏移(用于听读同步 / 高亮)
    static func offsets(for sentences: [String], source text: String) -> [Int] {
        let full = ContentText.renderText(from: text)
        var offsets: [Int] = []
        var cursorIdx = full.startIndex
        var cursor16 = 0
        for sentence in sentences {
            if let range = full.range(of: sentence, range: cursorIdx..<full.endIndex),
               let lo16 = range.lowerBound.samePosition(in: full.utf16),
               let up16 = range.upperBound.samePosition(in: full.utf16) {
                let start = full.utf16.distance(from: full.utf16.startIndex, to: lo16)
                offsets.append(start)
                cursorIdx = range.upperBound
                cursor16 = full.utf16.distance(from: full.utf16.startIndex, to: up16)
            } else {
                offsets.append(cursor16)
            }
        }
        return offsets
    }

    private static func appendIfNotEmpty(_ list: inout [String], _ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list.append(trimmed)
        }
    }
}
