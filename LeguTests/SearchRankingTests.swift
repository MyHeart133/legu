import Foundation
import XCTest
@testable import Legu

/// 搜索精准度排序与多源合并
final class SearchRankingTests: XCTestCase {

    private func book(_ id: String, _ title: String, _ author: String, source: String = "s1") -> SourceBook {
        SourceBook(
            sourceID: source,
            sourceBookID: id,
            title: title,
            author: author,
            cover: nil,
            language: "zh",
            summary: nil,
            subjects: []
        )
    }

    func testScoreOrdering() {
        let exact = SearchRanking.score(title: "囚于永夜", author: "", query: "囚于永夜")
        let prefix = SearchRanking.score(title: "囚于永夜之番外", author: "", query: "囚于永夜")
        let contains = SearchRanking.score(title: "我在囚于永夜等你", author: "", query: "囚于永夜")
        let authorOnly = SearchRanking.score(title: "无关书", author: "麦香鸡呢", query: "麦香鸡呢")
        let noise = SearchRanking.score(title: "大造化剑主", author: "某人", query: "蛊真人")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, contains)
        XCTAssertGreaterThan(contains, 0)
        XCTAssertGreaterThan(authorOnly, 0)
        XCTAssertEqual(noise, 0)
    }

    func testMergeRanksExactFirst() {
        let batches = [
            SourceSearchBatch(sourceID: "qimao", sourceName: "七猫", books: [
                book("1", "大造化剑主", "夜行月"),
                book("2", "蛊真人之邪淫魔尊", "千面兰"),
            ], error: nil),
            SourceSearchBatch(sourceID: "202xs", sourceName: "202小说网", books: [
                book("598", "蛊真人", "蛊真人", source: "202xs"),
            ], error: nil),
        ]
        let merged = SearchRanking.merge(batches, query: "蛊真人")
        XCTAssertFalse(merged.isEmpty)
        XCTAssertEqual(merged[0].title, "蛊真人")
        XCTAssertEqual(merged[0].primary.sourceName, "202小说网")
        XCTAssertFalse(merged.contains { $0.title == "大造化剑主" })
    }

    func testMergeDedupesAcrossSources() {
        let batches = [
            SourceSearchBatch(sourceID: "dmxsw", sourceName: "耽美小说", books: [
                book("u1", "囚于永夜", "麦香鸡呢", source: "dmxsw"),
            ], error: nil),
            SourceSearchBatch(sourceID: "shuku52", sourceName: "52书库", books: [
                book("u2", "囚于永夜", "麦香鸡呢", source: "shuku52"),
            ], error: nil),
        ]
        let merged = SearchRanking.merge(batches, query: "囚于永夜")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sourceCount, 2)
    }

    func testMergeKeepsAllWhenNoRelevance() {
        let batches = [
            SourceSearchBatch(sourceID: "s", sourceName: "源", books: [
                book("1", "甲乙丙", "丁"),
            ], error: nil),
        ]
        let merged = SearchRanking.merge(batches, query: "完全无关词")
        XCTAssertEqual(merged.count, 1)
    }

    func testBundledSourcesResource() {
        var found: URL? = Bundle(for: SourceStore.self).url(forResource: "BundledSources", withExtension: "json")
        if found == nil {
            found = Bundle.main.url(forResource: "BundledSources", withExtension: "json")
        }
        guard let url = found else {
            XCTFail("BundledSources.json 未打包进 App")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("BundledSources.json 无法读取")
            return
        }
        let models = LegadoSource.decodeList(data)
        XCTAssertGreaterThan(models.count, 250, "打包书源应超过 250 个")
    }
}
