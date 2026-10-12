import CoreText
import UIKit

/// 正文渲染器:把(已规范化的)章节文本 + 排版参数 → NSAttributedString
///
/// 排版全部由 NSParagraphStyle 精确控制:
/// - 行距:lineSpacing(倍数换算为点数)
/// - 段距:paragraphSpacing(与行距完全独立,0 = 真正紧贴)
/// - 首行缩进:firstLineHeadIndent(两字符宽)
/// - 字间距:kern
/// - 两端对齐(中文书籍排版惯例);禁则由系统排版引擎(Core Text)处理
enum ReaderTextRenderer {

    static func attributedString(
        _ content: String,
        typo: ReaderTypography,
        font: ResolvedFont,
        highlight: NSRange? = nil
    ) -> NSAttributedString {
        let text = ContentText.renderText(from: content)
        guard !text.isEmpty else { return NSAttributedString(string: "") }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(typo.fontSize * (typo.lineSpacing - 1))
        paragraph.paragraphSpacing = CGFloat(typo.paragraphSpacing)
        paragraph.paragraphSpacingBefore = 0
        paragraph.firstLineHeadIndent = typo.firstLineIndent ? CGFloat(typo.fontSize * 2) : 0
        paragraph.headIndent = 0
        paragraph.tailIndent = 0
        paragraph.alignment = .justified
        paragraph.lineBreakMode = .byWordWrapping

        let uiFont: UIFont
        if let name = font.postScriptName, let f = UIFont(name: name, size: typo.fontSize) {
            uiFont = f
        } else {
            uiFont = UIFont.systemFont(ofSize: typo.fontSize, weight: typo.bold ? .semibold : .regular)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor(hex: typo.palette.foreground),
        ]
        if typo.letterSpacing > 0 {
            attrs[.kern] = CGFloat(typo.letterSpacing)
        }
        let result = NSMutableAttributedString(string: text, attributes: attrs)
        if let highlight {
            let length = result.length
            let location = max(0, min(highlight.location, length))
            let hlLength = max(0, min(highlight.length, length - location))
            if hlLength > 0 {
                result.addAttribute(
                    .backgroundColor,
                    value: highlightColor(for: typo.palette),
                    range: NSRange(location: location, length: hlLength)
                )
            }
        }
        if typo.punctuationCompression {
            applyPunctuationCompression(result, fontSize: CGFloat(typo.fontSize), letterSpacing: CGFloat(typo.letterSpacing))
        }
        return result
    }

    /// 朗读高亮色:浅色底用较浓淡黄,深色底用低透明度琥珀(按背景亮度自适应)
    static func highlightColor(for palette: ReaderTypography.Palette) -> UIColor {
        let bg = UIColor(hex: palette.background)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let alpha: CGFloat = luminance > 0.5 ? 0.55 : 0.30
        return UIColor(red: 1.0, green: 0.83, blue: 0.29, alpha: alpha)
    }

    /// CoreText 实测整段高度(线程安全,可在后台线程调用;用于连续滚动的章节定位与补偿)
    nonisolated static func measureHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 10 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        return ceil(size.height)
    }

    // MARK: - 标点挤压

    /// 句末标点(前) + 收尾标点(后)相邻时收紧半个字宽
    /// 仅限全角标点:半角标点字身窄,负字距会导致视觉重叠
    private static let tightenAfter: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？", "…",
    ]
    private static let tightenBefore: Set<Character> = [
        "」", "』", "”", "’", "）", "】", "》", "〉", "〕", "］",
    ]

    static func applyPunctuationCompression(
        _ string: NSMutableAttributedString,
        fontSize: CGFloat,
        letterSpacing: CGFloat
    ) {
        let chars = Array(string.string)
        guard chars.count > 1 else { return }
        var i = 0
        while i + 1 < chars.count {
            if tightenAfter.contains(chars[i]), tightenBefore.contains(chars[i + 1]) {
                let value = letterSpacing - fontSize * 0.5
                string.addAttribute(.kern, value: value, range: NSRange(location: i, length: 1))
            }
            i += 1
        }
    }

    /// 章节标题样式(独立于正文:不加首行缩进、更弱色、可选加粗)
    static func attributedTitle(
        _ title: String,
        typo: ReaderTypography,
        font: ResolvedFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        let size = typo.fontSize * 0.85
        let uiFont: UIFont
        if let name = font.postScriptName, let f = UIFont(name: name, size: size) {
            uiFont = f
        } else {
            uiFont = UIFont.systemFont(ofSize: size, weight: .medium)
        }
        return NSAttributedString(string: title, attributes: [
            .font: uiFont,
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor(hex: typo.palette.secondary),
        ])
    }
}

// MARK: - 颜色工具

extension UIColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
