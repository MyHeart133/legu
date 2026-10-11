import XCTest
@testable import Legu

/// 离线下载存储层
final class OfflineStoreTests: XCTestCase {

    private let key = "test|book-\(UUID().uuidString)"

    override func tearDown() {
        OfflineStore.deleteBook(key)
        super.tearDown()
    }

    func testChapterRoundtrip() {
        let text = "第一章正文\n第二段内容"
        XCTAssertTrue(OfflineStore.saveChapter(text, bookKey: key, chapterID: "c1"))
        XCTAssertEqual(OfflineStore.readChapter(bookKey: key, chapterID: "c1"), text)
        XCTAssertTrue(OfflineStore.hasChapter(bookKey: key, chapterID: "c1"))
    }

    func testMissingChapterReturnsNil() {
        XCTAssertNil(OfflineStore.readChapter(bookKey: key, chapterID: "nope"))
        XCTAssertFalse(OfflineStore.hasChapter(bookKey: key, chapterID: "nope"))
    }

    func testTOCCodableRoundtrip() {
        let chapters = [
            SourceChapter(id: "a", index: 1, title: "第一章 起点"),
            SourceChapter(id: "b", index: 2, title: "第二章 转折", isFree: false),
        ]
        XCTAssertTrue(OfflineStore.saveTOC(chapters, for: key))
        let loaded = OfflineStore.loadTOC(key)
        XCTAssertEqual(loaded, chapters)
    }

    func testStableFileNames() {
        let n1 = OfflineStore.chapterFileName("第1章/奇怪的 id?")
        let n2 = OfflineStore.chapterFileName("第1章/奇怪的 id?")
        let n3 = OfflineStore.chapterFileName("第2章/奇怪的 id?")
        XCTAssertEqual(n1, n2, "同一章节 ID 必须映射到同一文件名")
        XCTAssertNotEqual(n1, n3)
        XCTAssertFalse(n1.contains("/"))
        XCTAssertFalse(n1.contains("?"))
        XCTAssertTrue(n1.hasPrefix("c_"))
        XCTAssertTrue(n1.hasSuffix(".txt"))
    }

    func testDownloadedFilesAndCount() {
        OfflineStore.saveChapter("x", bookKey: key, chapterID: "a")
        OfflineStore.saveChapter("y", bookKey: key, chapterID: "b")
        XCTAssertEqual(OfflineStore.downloadedCount(key), 2)
        XCTAssertTrue(OfflineStore.downloadedFileNames(key).contains(OfflineStore.chapterFileName("a")))
        XCTAssertTrue(OfflineStore.downloadedFileNames(key).contains(OfflineStore.chapterFileName("b")))
    }

    func testDeleteBookRemovesEverything() {
        OfflineStore.saveChapter("x", bookKey: key, chapterID: "a")
        OfflineStore.saveTOC([SourceChapter(id: "a", index: 1, title: "一")], for: key)
        XCTAssertGreaterThan(OfflineStore.bookSize(key), 0)
        OfflineStore.deleteBook(key)
        XCTAssertNil(OfflineStore.readChapter(bookKey: key, chapterID: "a"))
        XCTAssertNil(OfflineStore.loadTOC(key))
        XCTAssertEqual(OfflineStore.bookSize(key), 0)
        XCTAssertEqual(OfflineStore.downloadedCount(key), 0)
    }

    func testStableHashDeterministic() {
        XCTAssertEqual(StableHash.hex("abc"), StableHash.hex("abc"))
        XCTAssertNotEqual(StableHash.hex("abc"), StableHash.hex("abd"))
        XCTAssertFalse(StableHash.hex("abc").isEmpty)
    }

    func testBookKeyFormat() {
        XCTAssertEqual(OfflineStore.bookKey(sourceID: "s1", sourceBookID: "b1"), "s1|b1")
    }
}
