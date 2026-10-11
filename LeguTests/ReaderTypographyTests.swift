import UIKit
import XCTest
@testable import Legu

/// 排版模型:向后兼容 / 主题色板 / 渲染属性
final class ReaderTypographyTests: XCTestCase {

    func testDecodeV1Data() throws {
        let v1 = """
        {"fontSize":18,"lineSpacing":1.7,"paragraphSpacing":10,"theme":"dark"}
        """
        let t = try JSONDecoder().decode(ReaderTypography.self, from: Data(v1.utf8))
        XCTAssertEqual(t.fontSize, 18)
        XCTAssertEqual(t.lineSpacing, 1.7, accuracy: 0.001)
        XCTAssertEqual(t.paragraphSpacing, 10)
        XCTAssertEqual(t.theme, .dark)
        XCTAssertEqual(t.fontID, "system")
        XCTAssertTrue(t.firstLineIndent)
        XCTAssertEqual(t.letterSpacing, 0)
        XCTAssertTrue(t.hideStatusBar)
    }

    func testRoundTrip() throws {
        var t = ReaderTypography()
        t.fontID = "kaiti"
        t.fontSize = 24
        t.bold = true
        t.letterSpacing = 1.5
        t.firstLineIndent = false
        t.theme = .black
        t.customBackground = "#123456"
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ReaderTypography.self, from: data)
        XCTAssertEqual(back, t)
    }

    func testPaletteAllThemes() {
        for theme in ReaderTypography.Theme.allCases {
            var t = ReaderTypography()
            t.theme = theme
            let p = t.palette
            XCTAssertTrue(p.background.hasPrefix("#"))
            XCTAssertTrue(p.foreground.hasPrefix("#"))
            XCTAssertTrue(p.secondary.hasPrefix("#"))
        }
    }

    func testCustomPaletteMix() {
        var t = ReaderTypography()
        t.theme = .custom
        t.customBackground = "#000000"
        t.customForeground = "#FFFFFF"
        let p = t.palette
        XCTAssertEqual(p.background, "#000000")
        XCTAssertEqual(p.foreground, "#FFFFFF")
        XCTAssertEqual(p.secondary, "#808080")
    }

    func testFontSizeRange() {
        XCTAssertEqual(ReaderTypography.minFont, 12)
        XCTAssertEqual(ReaderTypography.maxFont, 36)
    }

    func testRendererParagraphStyleValues() {
        var typo = ReaderTypography()
        typo.fontSize = 20
        typo.lineSpacing = 1.5
        typo.paragraphSpacing = 8
        typo.firstLineIndent = true
        typo.letterSpacing = 2
        let font = FontRegistry.shared.resolve("system")
        let s = ReaderTextRenderer.attributedString("第一段内容。\n第二段内容,带标点……\n第三段", typo: typo, font: font)
        XCTAssertEqual(s.string, "第一段内容。\n第二段内容,带标点……\n第三段")
        let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style)
        XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 40, accuracy: 0.1)
        XCTAssertEqual(style?.paragraphSpacing ?? -1, 8, accuracy: 0.1)
        XCTAssertEqual(style?.lineSpacing ?? -1, 10, accuracy: 0.1)
        let kernValue = s.attribute(.kern, at: 0, effectiveRange: nil)
        let kern = (kernValue as? CGFloat) ?? CGFloat((kernValue as? NSNumber)?.doubleValue ?? 0)
        XCTAssertEqual(kern, 2, accuracy: 0.01)
    }

    func testIndentOff() {
        var typo = ReaderTypography()
        typo.firstLineIndent = false
        let s = ReaderTextRenderer.attributedString("内容。", typo: typo, font: FontRegistry.shared.resolve("system"))
        let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 0, accuracy: 0.1)
    }

    func testBlankLinesRemovedInRendering() {
        var typo = ReaderTypography()
        typo.fontSize = 18
        let s = ReaderTextRenderer.attributedString("甲\r\n\r\n乙\n\u{3000}\n丙", typo: typo, font: FontRegistry.shared.resolve("system"))
        XCTAssertEqual(s.string, "甲\n乙\n丙")
        XCTAssertFalse(s.string.contains("\r"))
    }

    func testTextViewMeasuresHeight() {
        let long = String(repeating: "这是一段用于测试排版高度测量的中文文本,包含标点。", count: 40)
        let s = ReaderTextRenderer.attributedString(long, typo: ReaderTypography(), font: FontRegistry.shared.resolve("system"))
        let h = measure(s)
        XCTAssertGreaterThan(h, 200, "长文本测量高度应显著大于 200pt(实际 \(h))")
    }

    func testLongerTextTallerMeasurement() {
        let short = ReaderTextRenderer.attributedString("一句话。", typo: ReaderTypography(), font: FontRegistry.shared.resolve("system"))
        let long = ReaderTextRenderer.attributedString(String(repeating: "很多字。", count: 200), typo: ReaderTypography(), font: FontRegistry.shared.resolve("system"))
        XCTAssertGreaterThan(measure(long), measure(short))
    }

    private func measure(_ s: NSAttributedString) -> CGFloat {
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = s
        tv.frame = CGRect(x: 0, y: 0, width: 320, height: 50)
        return tv.sizeThatFits(CGSize(width: 320, height: .greatestFiniteMagnitude)).height
    }
}
