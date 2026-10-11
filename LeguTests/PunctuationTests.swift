import UIKit
import XCTest
@testable import Legu

/// 中文标点挤压
final class PunctuationTests: XCTestCase {

    private func kernValue(_ s: NSAttributedString, at index: Int) -> CGFloat? {
        guard index >= 0 else { return nil }
        let raw = s.attribute(.kern, at: index, effectiveRange: nil)
        if let value = raw as? CGFloat { return value }
        if let number = raw as? NSNumber { return CGFloat(number.doubleValue) }
        return nil
    }

    func testCompressionAppliesToPeriodBeforeClosingQuote() {
        var typo = ReaderTypography()
        typo.fontSize = 20
        typo.punctuationCompression = true
        let s = ReaderTextRenderer.attributedString(
            "他说:「好。」",
            typo: typo,
            font: FontRegistry.shared.resolve("system")
        )
        let idx = (s.string as NSString).range(of: "。」").location
        XCTAssertNotEqual(idx, NSNotFound)
        let kern = kernValue(s, at: idx)
        XCTAssertNotNil(kern, "。」中的句号应带挤压字距")
        XCTAssertEqual(kern ?? 0, -10, accuracy: 0.01, "挤压量应为 -0.5 字宽")
    }

    func testCompressionDisabled() {
        var typo = ReaderTypography()
        typo.punctuationCompression = false
        let s = ReaderTextRenderer.attributedString(
            "好。」",
            typo: typo,
            font: FontRegistry.shared.resolve("system")
        )
        let idx = (s.string as NSString).range(of: "。」").location
        XCTAssertNotEqual(idx, NSNotFound)
        XCTAssertNil(kernValue(s, at: idx), "关闭挤压后不应有字距调整")
    }

    func testDashNotCompressed() {
        var typo = ReaderTypography()
        typo.punctuationCompression = true
        let s = ReaderTextRenderer.attributedString(
            "他走了——再也没回来。",
            typo: typo,
            font: FontRegistry.shared.resolve("system")
        )
        let idx = (s.string as NSString).range(of: "——").location
        XCTAssertNotEqual(idx, NSNotFound)
        XCTAssertNil(kernValue(s, at: idx), "破折号不应被挤压")
    }

    func testCommaBeforeClosingBracket() {
        var typo = ReaderTypography()
        typo.fontSize = 20
        typo.punctuationCompression = true
        let s = ReaderTextRenderer.attributedString(
            "「甲，乙，」",
            typo: typo,
            font: FontRegistry.shared.resolve("system")
        )
        let idx = (s.string as NSString).range(of: "，」").location
        XCTAssertNotEqual(idx, NSNotFound)
        XCTAssertNotNil(kernValue(s, at: idx), "，」组合应被挤压")
    }

    func testCompressionCombinesWithLetterSpacing() {
        var typo = ReaderTypography()
        typo.fontSize = 20
        typo.letterSpacing = 2
        typo.punctuationCompression = true
        let s = ReaderTextRenderer.attributedString(
            "好。」",
            typo: typo,
            font: FontRegistry.shared.resolve("system")
        )
        let idx = (s.string as NSString).range(of: "。」").location
        XCTAssertNotEqual(idx, NSNotFound)
        let kern = kernValue(s, at: idx)
        XCTAssertNotNil(kern)
        XCTAssertEqual(kern ?? 0, 2 - 10, accuracy: 0.01, "挤压应与字间距叠加")
    }
}
