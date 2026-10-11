import XCTest
@testable import Legu

/// 原生书源解析(用真实页面结构片段)
final class NativeParserTests: XCTestCase {

    // MARK: - Template202(202xs 新版模板)

    func testTemplate202SearchNew() {
        let html = """
        <div class="article"><h2 class="title"><span>搜索《蛊真人》的小说</span></h2>
        <div class="block"><ul>
        <li><a href="/book/598/">蛊真人</a><span>蛊真人</span></li>
        <li><a href="/book/30872/">蛊真人之邪淫魔尊</a><span>千面兰</span></li>
        </ul></div></div>
        """
        let books = Template202Source.parseSearch(html, sourceID: "202xs", base: "https://202xs.com")
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].sourceBookID, "598")
        XCTAssertEqual(books[0].title, "蛊真人")
        XCTAssertEqual(books[0].author, "蛊真人")
    }

    func testTemplate202SearchOld() {
        let html = """
        <span class="s2"><a href="/book/123/">旧模板书</a></span><span class="s5">某作者</span>
        """
        let books = Template202Source.parseSearch(html, sourceID: "202xs", base: "https://202xs.com")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "旧模板书")
    }

    func testTemplate202ChapterPageNew() {
        let html = """
        <h2>第一章 纵身亡魔心仍不悔(第1/5页)</h2>
        <div id="novelcontent" class="novelcontent">
        <p>　　“方源,乖乖地交出春秋蝉。”</p><p>　　群敌环伺,早已经没有了生路。</p>
        <p>本章未完,点击下一页继续阅读。</p>
        </div>
        """
        let page = Template202Source.parseChapterPage(html)
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.pageNumber, 1)
        XCTAssertTrue(page?.text.contains("方源") ?? false)
        XCTAssertFalse(page?.text.contains("本章未完") ?? true)
    }

    func testTemplate202CatalogSortedUnique() {
        let chapters = [
            SourceChapter(id: "98136", index: 0, title: "第二十一章"),
            SourceChapter(id: "97942", index: 0, title: "第一章"),
            SourceChapter(id: "98136", index: 0, title: "第二十一章"),
        ]
        let sorted = Template202Source.sortedUnique(chapters)
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].id, "97942")
        XCTAssertEqual(sorted[0].index, 1)
        XCTAssertEqual(sorted[1].index, 2)
    }

    // MARK: - 和图书

    func testHetushuSearch() {
        let html = """
        <dl>
        <dd><a href="/book/7640/index.html"><img src="/book/cover.pic/cover_7640.jpg" /></a><div class="state continue"></div><h4 style=""><a href="/book/7640/index.html">蛊真人</a><span>/ 蛊真人 /</span></h4><div class="intro"><p>人是万物之灵,蛊是天地真精。</p></div><div><a href="/book/7640/index.html" class="button">免费阅读</a></div></dd>
        </dl>
        """
        let books = HetushuSource.parseSearch(html)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].sourceBookID, "7640")
        XCTAssertEqual(books[0].title, "蛊真人")
        XCTAssertEqual(books[0].author, "蛊真人")
        XCTAssertTrue(books[0].summary?.contains("蛊是天地真精") ?? false)
    }

    func testHetushuCatalog() {
        let html = """
        <dl><dd><a href="/book/7640/1.html">第一章 纵身亡魔心仍不悔</a></dd>
        <dd><a href="/book/7640/2.html">第二章 蛊是天地真精</a></dd></dl>
        """
        let chapters = HetushuSource.parseCatalog(html, bookID: "7640")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].id, "1")
        XCTAssertEqual(chapters[1].index, 2)
    }

    // MARK: - 耽美小说(dmxsw)

    func testDmxswSearch() {
        let html = """
        <div class="books m-cols">
        <div class="bk">
        <a href="/xhly/15871.html">
        <div class="infos">
        <h3>囚于永夜</h3>
        <div class="booknews"><label class="autor">size:</label><label class="date">2024-10-08</label></div>
        <p>　　《囚于永夜》作者:麦香鸡呢<br />文案:</p>
        </div>
        </a>
        </div>
        </div>
        """
        let books = DmxswSource.parseSearch(html)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "囚于永夜")
        XCTAssertEqual(books[0].author, "麦香鸡呢")
        XCTAssertEqual(books[0].sourceBookID, "https://m.dmxsw.org/xhly/15871.html")
    }

    func testDmxswCatalogAndChapter() {
        let bookHTML = """
        <div class="book_list book_list_wp clearfix"><ul class="clearfix">
        <li><a href="/view/7-15871-1.html"> 第1章</a></li><li><a href="/view/7-15871-2.html"> 第2章</a></li>
        </ul></div>
        """
        let chapters = DmxswSource.parseCatalog(bookHTML)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].id, "https://m.dmxsw.org/view/7-15871-1.html")
        XCTAssertEqual(chapters[1].title, "第2章")

        let chapterHTML = """
        <div class="read_article">
        <p>　　温然是beta。</p><p>　　七岁,温家从福利院将温然领养回家。</p>
        </div>
        <div class="page_chapter"><ul><li><a href="/view/7-15871-2.html">下一章</a></li></ul></div>
        """
        let text = DmxswSource.parseChapter(chapterHTML)
        XCTAssertTrue(text.contains("温然是beta"))
        XCTAssertFalse(text.contains("下一章"))
    }

    // MARK: - 52书库

    func testShuku52TitleClean() {
        let (t1, a1) = Shuku52Source.cleanTitle("1. <em>囚于</em><em>永夜</em>_麦香鸡呢【完结】")
        XCTAssertEqual(t1, "囚于永夜")
        XCTAssertEqual(a1, "麦香鸡呢")
        let (t2, _) = Shuku52Source.cleanTitle("蛊真人_蛊真人")
        XCTAssertEqual(t2, "蛊真人")
    }

    func testShuku52Search() {
        let html = """
        <div class="content">
        <article class="excerpt">
        <header><h2><a href="https://www.52shuku.net/jiakong/06_b/bjVwT.html"><h4>1. <em>囚于</em><em>永夜</em>_麦香鸡呢【完结】</h4></a></h2></header>
        <span class="note">　　《囚于永夜》作者:麦香鸡呢【CP完结】文案:97.5%</span>
        </article>
        </div>
        """
        let books = Shuku52Source.parseSearch(html)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "囚于永夜")
        XCTAssertEqual(books[0].author, "麦香鸡呢")
        XCTAssertEqual(books[0].sourceBookID, "https://www.52shuku.net/jiakong/06_b/bjVwT.html")
    }

    func testShuku52Catalog() {
        let html = """
        <ul class="list clearfix">
        <li class="mulu"><a href="https://www.52shuku.net/jiakong/06_b/bjVwT_2.html">第1页</a></li>
        <li class="mulu"><a href="https://www.52shuku.net/jiakong/06_b/bjVwT_3.html">第2页</a></li>
        </ul>
        """
        let chapters = Shuku52Source.parseCatalog(html)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第1页")
    }

    func testShuku52Chapter() {
        let html = """
        <article class="article-content" >
        <p>温然是beta。</p>
        <p>七岁,温家从福利院将温然领养回家。</p>
        </article>
        """
        let text = Shuku52Source.parseChapter(html)
        XCTAssertTrue(text.contains("温然是beta"))
    }

    // MARK: - 飘天文学

    func testPiaotiaSearch() {
        let html = """
        <table><tr>
        <td class="odd"><a href="https://www.piaotia.com/bookinfo/1/1131.html">蛊真人</a></td>
        <td class="odd">蛊真人</td>
        <td class="even">更新时间:2024-01-01</td>
        <td class="even">已完成</td>
        </tr></table>
        """
        let books = PiaotiaSource.parseSearch(html)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].sourceBookID, "1/1131")
        XCTAssertEqual(books[0].title, "蛊真人")
    }
}
