import Foundation
import XCTest
@testable import Legu

/// Legado 书源模型 / 导入 / 标识
final class LegadoSourceTests: XCTestCase {

    private let dmxswJSON = """
    [{
      "bookSourceName": "耽美小说🎃",
      "bookSourceGroup": "6666666666666666",
      "bookSourceUrl": "https://m.dmxsw.org#🎃",
      "enabled": true,
      "header": "{\\n  \\"User-Agent\\": \\"Mozilla/5.0\\"\\n}",
      "ruleBookInfo": {"name": "h1text"},
      "ruleContent": {"content": ".read_article@p@html"},
      "ruleSearch": {
        "author": ".autor@text##作者:",
        "bookList": ".bk@a",
        "bookUrl": "a@href",
        "kind": ".date@text",
        "name": "a@text"
      },
      "ruleToc": {"chapterList": ".clearfix@li", "chapterName": "a@text", "chapterUrl": "a@href"},
      "searchUrl": "/e/search/index.php,{\\n  \\"body\\": \\"keyboard={{key}}&show=title&classid=0\\",\\n  \\"method\\": \\"POST\\",\\n  \\"charset\\": \\"GB2312\\"\\n}"
    }]
    """

    func testDecodeList() {
        let models = LegadoSource.decodeList(dmxswJSON)
        XCTAssertEqual(models.count, 1)
        let m = models[0]
        XCTAssertEqual(m.bookSourceName, "耽美小说🎃")
        XCTAssertEqual(m.cleanBaseURL, "https://m.dmxsw.org")
        XCTAssertEqual(m.ruleSearch?.bookList, ".bk@a")
        XCTAssertEqual(m.ruleContent?.content, ".read_article@p@html")
        XCTAssertTrue(m.parsedHeaders["User-Agent"]?.contains("Mozilla") ?? false)
    }

    func testDecodeSingleObject() {
        let single = "{\"bookSourceName\":\"单源\",\"bookSourceUrl\":\"https://x.com\"}"
        let models = LegadoSource.decodeList(single)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].displayTitle, "单源")
    }

    func testDecodeWithBOM() {
        let bom = "\u{FEFF}[{\"bookSourceName\":\"BOM源\",\"bookSourceUrl\":\"https://b.com\"}]"
        let models = LegadoSource.decodeList(bom)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].displayTitle, "BOM源")
    }

    func testDecodeInvalid() {
        XCTAssertTrue(LegadoSource.decodeList("not json at all").isEmpty)
    }

    func testStableID() {
        let a = LegadoContentSource.stableID("https://a.com|x")
        let b = LegadoContentSource.stableID("https://a.com|x")
        let c = LegadoContentSource.stableID("https://a.com|y")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 16)
    }

    func testLegadoSourceInit() {
        let models = LegadoSource.decodeList(dmxswJSON)
        let source = LegadoContentSource(model: models[0])
        XCTAssertNotNil(source)
        XCTAssertEqual(source?.displayName, "耽美小说🎃")
        XCTAssertEqual(source?.baseURL, "https://m.dmxsw.org")
        XCTAssertTrue(source?.capabilities.search ?? false)
        XCTAssertTrue(source?.identifier.hasPrefix("legado:") ?? false)
    }

    @MainActor
    func testSourceStoreImport() {
        let store = SourceStore()
        // 用唯一 URL 保证本次一定新增
        let unique = dmxswJSON.replacingOccurrences(
            of: "https://m.dmxsw.org#🎃",
            with: "https://m.dmxsw.org-\(UUID().uuidString).test#🎃"
        )
        let before = store.records.count
        let summary = store.importSources(jsonText: unique)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(store.records.count, before + 1)
        // 重复导入 → 跳过
        let again = store.importSources(jsonText: unique)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.skipped, 1)
        // 清理
        if let rec = store.records.last, rec.url.contains(".test") {
            store.remove(ids: [rec.id])
        }
    }

    @MainActor
    func testSourceStoreSeedsNatives() {
        let store = SourceStore()
        XCTAssertGreaterThanOrEqual(store.records.filter { $0.isNative }.count, 10)
        let ids = store.records.map { $0.id }
        XCTAssertTrue(ids.contains("qimao"))
        XCTAssertTrue(ids.contains("dmxsw"))
        XCTAssertTrue(ids.contains("shuku52"))
        // 内置源可实例化
        XCTAssertNotNil(NativeSources.make("qimao"))
        XCTAssertNotNil(NativeSources.make("202xs"))
        XCTAssertNotNil(NativeSources.make("hetushu"))
        XCTAssertNotNil(NativeSources.make("shuku52"))
    }
}
