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
        font: ResolvedFont
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
        return NSAttributedString(string: text, attributes: attrs)
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
