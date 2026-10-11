import XCTest
@testable import Legu

/// HTML 解析器与查询
final class HTMLNodeTests: XCTestCase {

    func testBasicParseAndQuery() {
        let html = """
        <html><body>
        <div class="book box"><a href="/book/1/">斗破</a><span class="author">天蚕土豆</span></div>
        <div class="book box"><a href="/book/2/">蛊真人</a><span class="author">蛊真人</span></div>
        </body></html>
        """
        let root = HTMLParser.parse(html)
        let books = root.getElementsByClass("book")
        XCTAssertEqual(books.count, 2)
        let links = root.getElementsByTag("a")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.attr("href"), "/book/1/")
        XCTAssertEqual(links.first?.textContent().trimmingCharacters(in: .whitespacesAndNewlines), "斗破")
    }

    func testSelfInclusiveTagSelection() {
        let html = "<div><a href=\"/x\">A</a></div>"
        let root = HTMLParser.parse(html)
        let div = root.getElementsByTag("div").first!
        let links = div.getElementsByTag("a")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.attr("href"), "/x")
        // 在 a 元素上再查 a:自身命中
        let again = links[0].getElementsByTag("a")
        XCTAssertEqual(again.count, 1)
    }

    func testClassMultiToken() {
        let html = "<ul class=\"list clearfix\"><li class=\"mulu\"><a href=\"/p2.html\">第1页</a></li></ul>"
        let root = HTMLParser.parse(html)
        let ul = root.getElementsByClass("list clearfix")
        XCTAssertEqual(ul.count, 1)
        let lis = ul[0].getElementsByClass("mulu")
        XCTAssertEqual(lis.count, 1)
    }

    func testEntitiesAndBr() {
        let html = "<p>a&amp;b<br/>c&lt;d</p>"
        let root = HTMLParser.parse(html)
        let p = root.getElementsByTag("p").first!
        let text = p.textContent()
        XCTAssertTrue(text.contains("a&b"))
        XCTAssertTrue(text.contains("c<d"))
        XCTAssertTrue(text.contains("\n"))
    }

    func testScriptSkipped() {
        let html = "<div>前<script>var x = \"<div>fake</div>\";</script>后</div>"
        let root = HTMLParser.parse(html)
        let div = root.getElementsByTag("div").first!
        let text = div.textContent()
        XCTAssertFalse(text.contains("fake"))
        XCTAssertTrue(text.contains("前"))
        XCTAssertTrue(text.contains("后"))
    }

    func testGetElementByID() {
        let html = "<div id=\"nr1\"><p>正文一</p><p>正文二</p></div>"
        let root = HTMLParser.parse(html)
        let el = root.getElementByID("nr1")
        XCTAssertNotNil(el)
        XCTAssertTrue(el!.textContent().contains("正文一"))
    }

    func testInnerHTML() {
        let html = "<div id=\"c\"><p>甲</p><p>乙</p></div>"
        let root = HTMLParser.parse(html)
        let el = root.getElementByID("c")!
        let inner = el.innerHTML()
        XCTAssertTrue(inner.contains("<p>甲</p>"))
        XCTAssertTrue(inner.contains("<p>乙</p>"))
    }

    func testUnclosedTags() {
        let html = "<div class=\"bk\"><a href=\"/a.html\">标题<div class=\"infos\"><h3>书名</h3></div></a></div>"
        let root = HTMLParser.parse(html)
        let bk = root.getElementsByClass("bk")
        XCTAssertEqual(bk.count, 1)
        let h3 = root.getElementsByTag("h3")
        XCTAssertEqual(h3.count, 1)
        XCTAssertEqual(h3[0].textContent().trimmingCharacters(in: .whitespacesAndNewlines), "书名")
    }
}
