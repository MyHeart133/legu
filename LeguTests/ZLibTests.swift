import XCTest
@testable import Legu

/// Z-Library:MiniZip / EPUB 解析 / 客户端映射(离线夹具,不联网)
@MainActor
final class ZLibTests: XCTestCase {

    // python 生成的迷你 ZIP:hello.txt(deflate)+ raw.txt(stored)
    private static let zipFixture =
        "UEsDBBQAAAAAAPJbTF22wpudPAAAADwAAAAJAAAAaGVsbG8udHh0SGVsbG8gWklQIOS4lueVjCAxMjNIZWxsbyBaSVAg5LiW55WM" +
        "IDEyM0hlbGxvIFpJUCDkuJbnlYwgMTIzUEsDBBQAAAAAAAAAIQBWXaF9FQAAABUAAAAHAAAAcmF3LnR4dFNUT1JFRCBDT05URU5U" +
        "IOS9oOWlvVBLAQIUABQAAAAAAPJbTF22wpudPAAAADwAAAAJAAAAAAAAAAAAAACAAQAAAABoZWxsby50eHRQSwECFAAUAAAAAAAA" +
        "ACEAVl2hfRUAAAAVAAAABwAAAAAAAAAAAAAAgAFjAAAAcmF3LnR4dFBLBQYAAAAAAgACAGwAAACdAAAAAAA="

    // python 生成的迷你 EPUB:2 章 + NCX + OPF
    private static let epubFixture =
        "UEsDBBQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAAAADyW0xdHgvX" +
        "yd0AAADdAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWw8P3htbCB2ZXJzaW9uPSIxLjAiPz48Y29udGFpbmVyIHZlcnNpb249" +
        "IjEuMCIgeG1sbnM9InVybjpvYXNpczpuYW1lczp0YzpvcGVuZG9jdW1lbnQ6eG1sbnM6Y29udGFpbmVyIj48cm9vdGZpbGVzPjxy" +
        "b290ZmlsZSBmdWxsLXBhdGg9Ik9FQlBTL2NvbnRlbnQub3BmIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi9vZWJwcy1wYWNrYWdl" +
        "K3htbCIvPjwvcm9vdGZpbGVzPjwvY29udGFpbmVyPlBLAwQUAAAAAADyW0xd+DrT1CYCAAAmAgAAEQAAAE9FQlBTL2NvbnRlbnQu" +
        "b3BmPD94bWwgdmVyc2lvbj0iMS4wIj8+PHBhY2thZ2UgeG1sbnM9Imh0dHA6Ly93d3cuaWRwZi5vcmcvMjAwNy9vcGYiIHZlcnNp" +
        "b249IjIuMCIgdW5pcXVlLWlkZW50aWZpZXI9ImlkIj48bWV0YWRhdGEgeG1sbnM6ZGM9Imh0dHA6Ly9wdXJsLm9yZy9kYy9lbGVt" +
        "ZW50cy8xLjEvIj48ZGM6dGl0bGU+5rWL6K+V5Lmm57GNPC9kYzp0aXRsZT48ZGM6Y3JlYXRvcj7mtYvor5XkvZzogIU8L2RjOmNy" +
        "ZWF0b3I+PC9tZXRhZGF0YT48bWFuaWZlc3Q+PGl0ZW0gaWQ9Im5jeCIgaHJlZj0idG9jLm5jeCIgbWVkaWEtdHlwZT0iYXBwbGlj" +
        "YXRpb24veC1kdGJuY3greG1sIi8+PGl0ZW0gaWQ9ImMxIiBocmVmPSJUZXh0L2NoMS54aHRtbCIgbWVkaWEtdHlwZT0iYXBwbGlj" +
        "YXRpb24veGh0bWwreG1sIi8+PGl0ZW0gaWQ9ImMyIiBocmVmPSJUZXh0L2NoMi54aHRtbCIgbWVkaWEtdHlwZT0iYXBwbGljYXRp" +
        "b24veGh0bWwreG1sIi8+PC9tYW5pZmVzdD48c3BpbmUgdG9jPSJuY3giPjxpdGVtcmVmIGlkcmVmPSJjMSIvPjxpdGVtcmVmIGlk" +
        "cmVmPSJjMiIvPjwvc3BpbmU+PC9wYWNrYWdlPlBLAwQUAAAAAADyW0xd5ufEdk8BAABPAQAADQAAAE9FQlBTL3RvYy5uY3g8P3ht" +
        "bCB2ZXJzaW9uPSIxLjAiPz48bmN4IHhtbG5zPSJodHRwOi8vd3d3LmRhaXN5Lm9yZy96Mzk4Ni8yMDA1L25jeC8iIHZlcnNpb249" +
        "IjIwMDUtMSI+PG5hdk1hcD48bmF2UG9pbnQgaWQ9Im4xIj48bmF2TGFiZWw+PHRleHQ+56ys5LiA56ugIOW8gOWnizwvdGV4dD48" +
        "L25hdkxhYmVsPjxjb250ZW50IHNyYz0iVGV4dC9jaDEueGh0bWwiLz48L25hdlBvaW50PjxuYXZQb2ludCBpZD0ibjIiPjxuYXZM" +
        "YWJlbD48dGV4dD7nrKzkuoznq6Ag57un57utPC90ZXh0PjwvbmF2TGFiZWw+PGNvbnRlbnQgc3JjPSJUZXh0L2NoMi54aHRtbCN0" +
        "b3AiLz48L25hdlBvaW50PjwvbmF2TWFwPjwvbmN4PlBLAwQUAAAAAADyW0xd1U2gg/8AAAD/AAAAFAAAAE9FQlBTL1RleHQvY2gx" +
        "LnhodG1sPD94bWwgdmVyc2lvbj0iMS4wIj8+PGh0bWwgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGh0bWwiPjxoZWFk" +
        "Pjx0aXRsZT7nrKzkuIDnq6Ag5byA5aeLPC90aXRsZT48c3R5bGU+cHtjb2xvcjpyZWR9PC9zdHlsZT48L2hlYWQ+PGJvZHk+PGgx" +
        "PuesrOS4gOeroCDlvIDlp4s8L2gxPjxwPui/meaYr+esrOS4gOeroOeahOesrOS4gOauteOAgjwvcD48cD7nrKzkuozmrrUgJmFt" +
        "cDsg5a6e5L2T5rWL6K+V44CCPC9wPjwvYm9keT48L2h0bWw+UEsDBBQAAAAAAPJbTF1F6ItA8QAAAPEAAAAUAAAAT0VCUFMvVGV4" +
        "dC9jaDIueGh0bWw8P3htbCB2ZXJzaW9uPSIxLjAiPz48aHRtbCB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMTk5OS94aHRtbCI+" +
        "PGhlYWQ+PHRpdGxlPuesrOS6jOeroCDnu6fnu608L3RpdGxlPjwvaGVhZD48Ym9keT48aDE+56ys5LqM56ugIOe7p+e7rTwvaDE+" +
        "PGRpdj7nrKzkuIDmrrXjgII8L2Rpdj48ZGl2PuesrOS6jOauteOAgjxici8+5o2i6KGM5ZCO44CCPC9kaXY+PHNjcmlwdD52YXIg" +
        "eD0xOzwvc2NyaXB0PjwvYm9keT48L2h0bWw+UEsBAhQAFAAAAAAAAAAhAG9hqywUAAAAFAAAAAgAAAAAAAAAAAAAAIABAAAAAG1p" +
        "bWV0eXBlUEsBAhQAFAAAAAAA8ltMXR4L18ndAAAA3QAAABYAAAAAAAAAAAAAAIABOgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQ" +
        "SwECFAAUAAAAAADyW0xd+DrT1CYCAAAmAgAAEQAAAAAAAAAAAAAAgAFLAQAAT0VCUFMvY29udGVudC5vcGZQSwECFAAUAAAAAADy" +
        "W0xd5ufEdk8BAABPAQAADQAAAAAAAAAAAAAAgAGgAwAAT0VCUFMvdG9jLm5jeFBLAQIUABQAAAAAAPJbTF3VTaCD/wAAAP8AAAAU" +
        "AAAAAAAAAAAAAACAARoFAABPRUJQUy9UZXh0L2NoMS54aHRtbFBLAQIUABQAAAAAAPJbTF1F6ItA8QAAAPEAAAAUAAAAAAAAAAAA" +
        "AACAAUsGAABPRUJQUy9UZXh0L2NoMi54aHRtbFBLBQYAAAAABgAGAHgBAABuBwAAAAA="

    // MARK: MiniZip

    func testMiniZipReadsStoredAndDeflated() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.zipFixture))
        let files = try MiniZip.read(data)
        XCTAssertEqual(String(data: files["hello.txt"] ?? Data(), encoding: .utf8),
                       "Hello ZIP 世界 123Hello ZIP 世界 123Hello ZIP 世界 123")
        XCTAssertEqual(String(data: files["raw.txt"] ?? Data(), encoding: .utf8), "STORED CONTENT 你好")
    }

    func testMiniZipRejectsGarbage() {
        XCTAssertThrowsError(try MiniZip.read(Data([1, 2, 3, 4, 5])))
    }

    // MARK: EPUB

    func testEPUBParse() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.epubFixture))
        let book = try EPUBParser.parse(data)
        XCTAssertEqual(book.title, "测试书籍")
        XCTAssertEqual(book.author, "测试作者")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "第一章 开始")
        XCTAssertTrue(book.chapters[0].text.contains("这是第一章的第一段。"))
        XCTAssertTrue(book.chapters[0].text.contains("实体测试"))
        XCTAssertFalse(book.chapters[0].text.contains("第一章 开始"))
        XCTAssertEqual(book.chapters[1].title, "第二章 继续")
        XCTAssertTrue(book.chapters[1].text.contains("换行后。"))
        XCTAssertFalse(book.chapters[1].text.contains("var x=1"))
    }

    func testNormalizePath() {
        XCTAssertEqual(EPUBParser.normalizePath("OEBPS/../OEBPS/Text/./a.xhtml"), "OEBPS/Text/a.xhtml")
        XCTAssertEqual(EPUBParser.normalizePath("a/b/c"), "a/b/c")
    }

    // MARK: 客户端映射

    func testSplitBookID() {
        let (id, hash) = ZLibraryClient.splitBookID("12345:abcdef")
        XCTAssertEqual(id, "12345")
        XCTAssertEqual(hash, "abcdef")
    }

    func testParseCookiesIgnoresExpires() {
        let header = "remix_userid=999; Path=/; Expires=Mon, 12 Oct 2026 03:31:40 GMT, remix_userkey=deadbeef; Path=/"
        let cookies = ZLibraryClient.parseCookies(header)
        XCTAssertEqual(cookies["remix_userid"], "999")
        XCTAssertEqual(cookies["remix_userkey"], "deadbeef")
    }

    func testMapSearchItem() {
        let b: [String: Any] = [
            "id": 26610712,
            "hash": "def1ec",
            "title": "三体",
            "author": "刘慈欣",
            "cover": "/img/cover.jpg",
            "extension": "epub",
            "filesize": 2600699,
            "language": "Chinese",
            "year": 2008,
        ]
        let book = ZLibraryClient.mapSearchItem(b, domain: "z-lib.gd")
        XCTAssertEqual(book?.sourceID, "zlib")
        XCTAssertEqual(book?.sourceBookID, "26610712:def1ec")
        XCTAssertEqual(book?.title, "三体")
        XCTAssertEqual(book?.cover, "https://z-lib.gd/img/cover.jpg")
        XCTAssertTrue(book?.subjects.contains("EPUB") == true)
        XCTAssertTrue(book?.subjects.contains("2008") == true)
    }

    func testNormalizeDomain() {
        XCTAssertEqual(ZLibSession.normalizeDomain("https://z-lib.sk/"), "z-lib.sk")
        XCTAssertEqual(ZLibSession.normalizeDomain(" http://z-lib.gd/foo "), "z-lib.gd")
        XCTAssertEqual(ZLibSession.normalizeDomain("z-lib.gl"), "z-lib.gl")
    }

    // MARK: 纯文本切章正则(兜底路径素材)

    func testPlainTextChapterPattern() {
        let pattern = "^第[0-9零一二三四五六七八九十百千两]{1,6}[章节回卷].{0,30}$"
        XCTAssertTrue(HTMLText.matches(pattern, in: "第一章 科学边界"))
        XCTAssertTrue(HTMLText.matches(pattern, in: "第十二回 大结局"))
        XCTAssertFalse(HTMLText.matches(pattern, in: "他说第一章很好看,真的"))
    }
}
