import XCTest
@testable import Legu

/// 规则求值器:默认链 / XPath / CSS / 后处理 / 组合
final class RuleEvaluatorTests: XCTestCase {

    private let ctx = EvalContext(base: "https://m.dmxsw.org")

    private let dmxswSearch = """
    <div class="books m-cols">
    <div class="bk">
    <a href="/xhly/15871.html">
    <div class="infos">
    <h3>囚于永夜</h3>
    <div class="booknews"><label class="autor">size：</label><label class="autor">1.07 MB</label> <label class="date">2024-10-08</label></div>
    <p>　　《囚于永夜》作者：麦香鸡呢<br />文案:97.5%</p>
    </div>
    </a>
    </div>
    </div>
    """

    func testBookListAndFields() {
        let root = HTMLParser.parse(dmxswSearch)
        let nodes = RuleEvaluator.elements(".bk@a", in: root, ctx: ctx)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(RuleEvaluator.string("h3@text", in: nodes[0], ctx: ctx), "囚于永夜")
        XCTAssertEqual(RuleEvaluator.string("a@href", in: nodes[0], ctx: ctx), "/xhly/15871.html")
        XCTAssertEqual(RuleEvaluator.string(".date@text", in: nodes[0], ctx: ctx), "2024-10-08")
        let intro = RuleEvaluator.string(".infos@tag.p.0@text", in: nodes[0], ctx: ctx)
        XCTAssertTrue(intro.contains("麦香鸡呢"))
    }

    func testClassChainWithExclude() {
        let html = """
        <div class="ampag">
        <li><a href="/a1">目录</a></li>
        <li><a href="/a2">上一页</a></li>
        <li><a href="/a3">第一章</a></li>
        <li><a href="/a4">第二章</a></li>
        </div>
        """
        let root = HTMLParser.parse(html)
        let nodes = RuleEvaluator.elements(".ampag@li[!0:2]@a", in: root, ctx: ctx)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(RuleEvaluator.string("href", in: nodes[0], ctx: ctx), "/a3")
    }

    func testIndexAndNegative() {
        let html = "<div class=\"t\"><a href=\"/1\">A</a><a href=\"/2\">B</a><a href=\"/3\">C</a></div>"
        let root = HTMLParser.parse(html)
        XCTAssertEqual(RuleEvaluator.string(".t@a.0@href", in: root, ctx: ctx), "/1")
        XCTAssertEqual(RuleEvaluator.string(".t@a.-1@href", in: root, ctx: ctx), "/3")
        XCTAssertEqual(RuleEvaluator.string(".t@a[1]@href", in: root, ctx: ctx), "/2")
        XCTAssertEqual(RuleEvaluator.string(".t@a[0:2]@text", in: root, ctx: ctx), "A")
    }

    func testXPathMeta() {
        let html = """
        <html><head>
        <meta property="og:novel:book_name" content="囚于永夜">
        <meta property="og:novel:author" content="麦香鸡呢">
        </head><body></body></html>
        """
        let root = HTMLParser.parse(html)
        XCTAssertEqual(
            RuleEvaluator.string("//meta[@property='og:novel:author']/@content", in: root, ctx: ctx),
            "麦香鸡呢"
        )
        XCTAssertEqual(
            RuleEvaluator.string("[property$=book_name]@content", in: root, ctx: ctx),
            "囚于永夜"
        )
    }

    func testXPathContent() {
        let html = """
        <div id="content"><div>甲段</div><div>乙段</div></div>
        """
        let root = HTMLParser.parse(html)
        let v = RuleEvaluator.string("//div[@id='content']/div[2]/text()", in: root, ctx: ctx)
        XCTAssertEqual(v, "乙段")
    }

    func testCSSSelector() {
        let html = """
        <div id="pages">
        <a class="gr" href="#next">下页</a>
        <a class="gr" href="#skip">#</a>
        <a class="gr" href="/real">真</a>
        </div>
        """
        let root = HTMLParser.parse(html)
        let v = RuleEvaluator.string("@css:#pages .gr:not([href='#'])@href", in: root, ctx: ctx)
        XCTAssertEqual(v, "#next")
    }

    func testPostProcessReplace() {
        let html = "<span class=\"autor\">作者:张三</span>"
        let root = HTMLParser.parse(html)
        XCTAssertEqual(
            RuleEvaluator.string(".autor@text##作者[:：]", in: root, ctx: ctx),
            "张三"
        )
        XCTAssertEqual(
            RuleEvaluator.string(".autor@text##作者[:：]##", in: root, ctx: ctx),
            "张三"
        )
    }

    func testPostProcessDeleteAll() {
        let html = "<p>正文内容【广告】继续</p>"
        let root = HTMLParser.parse(html)
        XCTAssertEqual(
            RuleEvaluator.string("p@text###【.*?】", in: root, ctx: ctx),
            "正文内容继续"
        )
    }

    func testCombineAndFallback() {
        let html = """
        <div class="tags">标签:<a>玄幻</a></div>
        <div class="date"><span>0</span><span>时间:2024-10-08</span></div>
        """
        let root = HTMLParser.parse(html)
        let v = RuleEvaluator.string(".tags@a@text&&.date@span.1@text##时间[:：]", in: root, ctx: ctx)
        XCTAssertTrue(v.contains("玄幻"))
        XCTAssertTrue(v.contains("2024-10-08"))
        // || 回退:第一个为空取第二个
        XCTAssertEqual(RuleEvaluator.string(".nothing@text||.tags@a@text", in: root, ctx: ctx), "玄幻")
    }

    func testJSReplace() {
        let html = "<a href=\"/read/123.html\">章</a>"
        let root = HTMLParser.parse(html)
        let v = RuleEvaluator.string("a@href@js:result.replace('.html','')", in: root, ctx: ctx)
        XCTAssertEqual(v, "/read/123")
    }

    func testGetPut() {
        let html = "<div id=\"book\"><meta property=\"og:novel:book_name\" content=\"蛊真人\"></div>"
        let root = HTMLParser.parse(html)
        var mutableCtx = ctx
        RuleEvaluator.applyPut(rule: "@put:{\"n\":\"[property$=book_name]@content\"}", node: root, ctx: &mutableCtx)
        XCTAssertEqual(mutableCtx.vars["n"], "蛊真人")
        XCTAssertEqual(RuleEvaluator.string("@get:{n}", in: root, ctx: mutableCtx), "蛊真人")
    }

    func testURLTemplateSplit() {
        let raw = "/e/search/index.php,{\n  \"body\": \"keyboard={{key}}&show=title&classid=0\",\n  \"method\": \"POST\",\n  \"charset\": \"GB2312\"\n}"
        let (url, options) = LegadoContentSource.parseURLOptions(raw)
        XCTAssertEqual(url, "/e/search/index.php")
        XCTAssertEqual(options.method, "POST")
        XCTAssertEqual(options.charset, "GB2312")
        XCTAssertTrue(options.body?.contains("keyboard=") ?? false)

        let expanded = LegadoContentSource.expand(
            options.body ?? "", key: "蛊真人", page: "1", base: "https://x", encoding: .gb18030
        )
        XCTAssertTrue(expanded.hasPrefix("keyboard=%"))
        XCTAssertTrue(expanded.contains("show=title"))
    }

    func testResolveURL() {
        XCTAssertEqual(LegadoContentSource.resolveURL("/book/1/", base: "https://a.com"), "https://a.com/book/1/")
        XCTAssertEqual(LegadoContentSource.resolveURL("book/1/", base: "https://a.com"), "https://a.com/book/1/")
        XCTAssertEqual(LegadoContentSource.resolveURL("https://b.com/x", base: "https://a.com"), "https://b.com/x")
        XCTAssertEqual(LegadoContentSource.resolveURL("//b.com/x", base: "https://a.com"), "https://b.com/x")
    }

    func testNormalizeContent() {
        let html = "<div><p>甲</p><p>乙</p></div>"
        XCTAssertEqual(LegadoContentSource.normalizeContent(html), "甲\n乙")
        XCTAssertEqual(LegadoContentSource.normalizeContent("甲\n\n乙\n"), "甲\n乙")
    }
}
