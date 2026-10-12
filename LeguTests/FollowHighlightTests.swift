import XCTest
@testable import Legu

/// 听读同步:偏移(UTF-16,渲染坐标)/ 高亮渲染 / NowReading
final class FollowHighlightTests: XCTestCase {

    // MARK: 偏移(UTF-16,渲染坐标)

    func testOffsetsUseUTF16() {
        let text = "😀第一句。第二句。"
        let sentences = SentenceSplitter.split(text)
        XCTAssertEqual(sentences, ["😀第一句。", "第二句。"])
        let offsets = SentenceSplitter.offsets(for: sentences, source: text)
        // 😀 占 2 个 UTF-16 单元,加「第一句。」4 个 = 6
        XCTAssertEqual(offsets, [0, 6])
    }

    func testOffsetsPlainText() {
        let text = "第一句。第二句。"
        let sentences = SentenceSplitter.split(text)
        let offsets = SentenceSplitter.offsets(for: sentences, source: text)
        XCTAssertEqual(offsets, [0, 4])
    }

    func testOffsetsMatchRenderedText() {
        let raw = "　　第一句。\r\n\r\n第二句。\r\n第三句。"
        let sentences = SentenceSplitter.split(raw)
        let rendered = ContentText.renderText(from: raw)
        let offsets = SentenceSplitter.offsets(for: sentences, source: raw)
        XCTAssertEqual(offsets.count, sentences.count)
        let ns = rendered as NSString
        for (i, sentence) in sentences.enumerated() {
            let start = offsets[i]
            XCTAssertLessThanOrEqual(start, ns.length, "句 \(i) 偏移越界")
            let end = min(start + sentence.utf16.count, ns.length)
            let slice = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            XCTAssertEqual(slice, sentence, "句 \(i) 偏移与渲染文本不一致")
        }
    }

    // MARK: 高亮渲染

    func testHighlightAttributeApplied() {
        let typo = ReaderTypography()
        let font = FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
        let content = "第一句。第二句。"
        let highlighted = ReaderTextRenderer.attributedString(
            content, typo: typo, font: font,
            highlight: NSRange(location: 4, length: 4)
        )
        let plain = ReaderTextRenderer.attributedString(content, typo: typo, font: font)
        XCTAssertNotNil(highlighted.attribute(.backgroundColor, at: 4, effectiveRange: nil))
        XCTAssertNil(highlighted.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(plain.attribute(.backgroundColor, at: 4, effectiveRange: nil))
        XCTAssertEqual(highlighted.string, plain.string)
    }

    func testHighlightClampedOutOfBounds() {
        let typo = ReaderTypography()
        let font = FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
        let attributed = ReaderTextRenderer.attributedString(
            "短文本。", typo: typo, font: font,
            highlight: NSRange(location: 500, length: 10)
        )
        XCTAssertEqual(attributed.string, "短文本。")
        XCTAssertNil(attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testHighlightEffectiveRange() {
        let typo = ReaderTypography()
        let font = FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
        let attributed = ReaderTextRenderer.attributedString(
            "第一句。第二句。", typo: typo, font: font,
            highlight: NSRange(location: 4, length: 4)
        )
        var effective = NSRange()
        let value = attributed.attribute(.backgroundColor, at: 5, effectiveRange: &effective)
        XCTAssertNotNil(value)
        XCTAssertEqual(effective.location, 4)
        XCTAssertEqual(effective.length, 4)
    }

    func testHighlightColorAdaptsToTheme() {
        let light = ReaderTextRenderer.highlightColor(
            for: ReaderTypography.Palette(background: "#FFFFFF", foreground: "#1A1A1A", secondary: "#8A8A8A")
        )
        let dark = ReaderTextRenderer.highlightColor(
            for: ReaderTypography.Palette(background: "#1C1C1E", foreground: "#C8C8C8", secondary: "#7A7A7A")
        )
        var la: CGFloat = 0, da: CGFloat = 0
        _ = light.getRed(nil, green: nil, blue: nil, alpha: &la)
        _ = dark.getRed(nil, green: nil, blue: nil, alpha: &da)
        XCTAssertGreaterThan(la, da, "浅色主题的高亮应更浓")
        XCTAssertGreaterThan(la, 0)
        XCTAssertGreaterThan(da, 0)
    }

    // MARK: 高度实测(CoreText,后台可用)

    func testMeasureHeightCoreText() {
        let typo = ReaderTypography()
        let font = FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
        let short = ReaderTextRenderer.attributedString("短句。", typo: typo, font: font)
        let long = ReaderTextRenderer.attributedString(
            String(repeating: "很长的一段文字内容。", count: 200),
            typo: typo, font: font
        )
        let shortHeight = ReaderTextRenderer.measureHeight(short, width: 300)
        let longHeight = ReaderTextRenderer.measureHeight(long, width: 300)
        XCTAssertGreaterThan(shortHeight, 0)
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertEqual(ReaderTextRenderer.measureHeight(short, width: 0), 0)

        // 行表(进度保存/恢复用):行数、首行偏移、单调性
        let layout = ReaderTextRenderer.measureLayout(long, width: 300)
        XCTAssertEqual(layout.height, longHeight)
        XCTAssertGreaterThan(layout.lines.count, 10)
        XCTAssertEqual(layout.lines.first?.offset, 0)
        let offsets = layout.lines.map { $0.offset }
        XCTAssertEqual(offsets, offsets.sorted())
    }

    // MARK: NowReading

    func testNowReadingEquatable() {
        let a = TTSService.NowReading(bookKey: "s|b", chapterIndex: 1, offset: 10, length: 5, isPlaying: true)
        let b = TTSService.NowReading(bookKey: "s|b", chapterIndex: 1, offset: 10, length: 5, isPlaying: true)
        let c = TTSService.NowReading(bookKey: "s|b", chapterIndex: 1, offset: 10, length: 5, isPlaying: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
