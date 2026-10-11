import Foundation

/// 正文文本规范化(所有来源统一入口)
///
/// 处理:CRLF / CR / LF 换行、制表符、全角空格、NBSP、连续空白、
/// 伪空白行(仅含 \r / 空格 / U+3000 的行)、多空行折叠。
/// 输出为「段落数组」,每个段落已去首尾空白(首行缩进由渲染层按设置施加)。
enum ContentText {

    static func paragraphs(from raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var s = raw
        // 统一换行
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        // 制表符与 NBSP
        s = s.replacingOccurrences(of: "\t", with: " ")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        // 逐行清洗
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            // 行首行尾空白(含全角空格)
            l = l.replacingOccurrences(of: "^[ \u{3000}]+", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "[ \u{3000}]+$", with: "", options: .regularExpression)
            // 行内连续空白压缩为单个半角空格(不触碰中文标点)
            l = l.replacingOccurrences(of: "[ \u{3000}]{2,}", with: " ", options: .regularExpression)
            return l
        }
        // 丢弃空行 / 伪空白行
        return lines.filter { !$0.isEmpty }
    }

    /// 段落数组 → 渲染文本(段落间以换行分隔;空行不会出现)
    static func renderText(from raw: String) -> String {
        paragraphs(from: raw).joined(separator: "\n")
    }

    /// 是否为空白行(含全角空格、\r、NBSP)
    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\u{00A0}\u{3000}")).isEmpty
    }
}
