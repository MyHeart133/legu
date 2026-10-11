import XCTest
@testable import Legu

/// 正文文本规范化
final class ContentTextTests: XCTestCase {

    func testCRLFAndCRNormalized() {
        let raw = "第一段\r\n第二段\r第三段\n第四段"
        XCTAssertEqual(ContentText.paragraphs(from: raw), ["第一段", "第二段", "第三段", "第四段"])
    }

    func testBlankAndPhantomLinesDropped() {
        let raw = "甲\n\n乙\n \n丙\n\u{3000}\n丁\n\r\n戊"
        XCTAssertEqual(ContentText.paragraphs(from: raw), ["甲", "乙", "丙", "丁", "戊"])
    }

    func testTabsAndNBSP() {
        let raw = "甲\t乙\n丙\u{00A0}丁"
        XCTAssertEqual(ContentText.paragraphs(from: raw), ["甲 乙", "丙 丁"])
    }

    func testLeadingFullwidthIndentStripped() {
        let raw = "　　首行缩进的内容\n　　“对话”"
        let paras = ContentText.paragraphs(from: raw)
        XCTAssertEqual(paras[0], "首行缩进的内容")
        XCTAssertEqual(paras[1], "“对话”")
    }

    func testEmojiAndPunctuationPreserved() {
        let raw = "他笑了😀……\n「真的吗?」——是的。"
        let paras = ContentText.paragraphs(from: raw)
        XCTAssertEqual(paras[0], "他笑了😀……")
        XCTAssertEqual(paras[1], "「真的吗?」——是的。")
    }

    func testRenderTextNoBlankLines() {
        let raw = "甲\r\n\r\n乙\r\n\r\n\r\n丙"
        XCTAssertEqual(ContentText.renderText(from: raw), "甲\n乙\n丙")
    }

    func testInteriorSpacesCollapsed() {
        let raw = "前面　　后面  三个空格"
        let paras = ContentText.paragraphs(from: raw)
        XCTAssertEqual(paras[0], "前面 后面 三个空格")
    }

    func testIsBlank() {
        XCTAssertTrue(ContentText.isBlank("\r"))
        XCTAssertTrue(ContentText.isBlank("\u{3000} "))
        XCTAssertFalse(ContentText.isBlank("字"))
    }
}
