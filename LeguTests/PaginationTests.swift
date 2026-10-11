import CoreText
import UIKit
import XCTest
@testable import Legu

/// 分页器:连续性 / 覆盖率 / 确定性 / 取消 / 偏移映射 / 缓存键
final class PaginationTests: XCTestCase {

    private func makeAttributed(_ text: String) -> NSAttributedString {
        ReaderTextRenderer.attributedString(
            text,
            typo: ReaderTypography(),
            font: FontRegistry.shared.resolve("system")
        )
    }

    func testContiguousCoverage() {
        let text = String(repeating: "这是一段用于分页测试的中文文本,包含标点符号与数字123。", count: 120)
        let attributed = makeAttributed(text)
        let pages = Paginator.paginate(attributed, size: CGSize(width: 320, height: 480))
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(pages.first?.location, 0)
        var expected = 0
        for range in pages {
            XCTAssertEqual(range.location, expected, "页区间必须连续")
            XCTAssertGreaterThan(range.length, 0, "不得出现空页")
            expected += range.length
        }
        XCTAssertEqual(expected, attributed.length, "分页必须完整覆盖全文,不丢字")
    }

    func testSmallerHeightMorePages() {
        let text = String(repeating: "分页密度测试文本。", count: 200)
        let attributed = makeAttributed(text)
        let tall = Paginator.paginate(attributed, size: CGSize(width: 320, height: 600))
        let short = Paginator.paginate(attributed, size: CGSize(width: 320, height: 300))
        XCTAssertGreaterThan(short.count, tall.count)
    }

    func testSmallerWidthMorePages() {
        let text = String(repeating: "宽度测试文本。", count: 200)
        let attributed = makeAttributed(text)
        let wide = Paginator.paginate(attributed, size: CGSize(width: 375, height: 500))
        let narrow = Paginator.paginate(attributed, size: CGSize(width: 240, height: 500))
        XCTAssertGreaterThan(narrow.count, wide.count)
    }

    func testDeterministic() {
        let attributed = makeAttributed(String(repeating: "确定性测试。", count: 100))
        let first = Paginator.paginate(attributed, size: CGSize(width: 320, height: 400))
        let second = Paginator.paginate(attributed, size: CGSize(width: 320, height: 400))
        XCTAssertEqual(first, second)
    }

    func testEmptyAndTinyInput() {
        XCTAssertTrue(Paginator.paginate(NSAttributedString(string: ""), size: CGSize(width: 320, height: 480)).isEmpty)
        let attributed = makeAttributed("短")
        let pages = Paginator.paginate(attributed, size: CGSize(width: 320, height: 480))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].length, attributed.length)
        XCTAssertTrue(Paginator.paginate(attributed, size: CGSize(width: 5, height: 5)).isEmpty, "过小尺寸应安全返回")
    }

    func testCancellationStopsEarly() {
        let text = String(repeating: "取消测试。", count: 600)
        let attributed = makeAttributed(text)
        var checks = 0
        let pages = Paginator.paginate(attributed, size: CGSize(width: 320, height: 200), shouldCancel: {
            checks += 1
            return checks > 2
        })
        XCTAssertLessThan(pages.count, 12, "取消后应尽早停止")
    }

    func testPageIndexForOffset() {
        let ranges = [
            NSRange(location: 0, length: 100),
            NSRange(location: 100, length: 100),
            NSRange(location: 200, length: 50),
        ]
        XCTAssertEqual(Paginator.pageIndex(forOffset: 0, in: ranges), 0)
        XCTAssertEqual(Paginator.pageIndex(forOffset: 99, in: ranges), 0)
        XCTAssertEqual(Paginator.pageIndex(forOffset: 100, in: ranges), 1)
        XCTAssertEqual(Paginator.pageIndex(forOffset: 249, in: ranges), 2)
        XCTAssertEqual(Paginator.pageIndex(forOffset: 9999, in: ranges), 2, "越界偏移应收敛到最后一页")
        XCTAssertEqual(Paginator.pageIndex(forOffset: -5, in: ranges), 0)
        XCTAssertEqual(Paginator.pageIndex(forOffset: 0, in: []), 0)
    }

    func testPaginationCacheKeyVariesWithLayout() {
        let t1 = ReaderTypography()
        var t2 = ReaderTypography()
        t2.fontSize = 24
        let k1 = PaginationCache.key(sourceID: "s", bookID: "b", chapterID: "c", layoutKey: t1.layoutKey, size: CGSize(width: 320, height: 480))
        let k2 = PaginationCache.key(sourceID: "s", bookID: "b", chapterID: "c", layoutKey: t2.layoutKey, size: CGSize(width: 320, height: 480))
        let k3 = PaginationCache.key(sourceID: "s", bookID: "b", chapterID: "c", layoutKey: t1.layoutKey, size: CGSize(width: 375, height: 480))
        let k1b = PaginationCache.key(sourceID: "s", bookID: "b", chapterID: "c", layoutKey: t1.layoutKey, size: CGSize(width: 320, height: 480))
        XCTAssertNotEqual(k1, k2, "字号变化必须产生新缓存键")
        XCTAssertNotEqual(k1, k3, "尺寸变化必须产生新缓存键")
        XCTAssertEqual(k1, k1b)
    }

    @MainActor
    func testCacheStoreAndEvict() {
        let cache = PaginationCache.shared
        let key = "test|\(UUID().uuidString)"
        XCTAssertNil(cache.get(key))
        cache.set(key, [NSRange(location: 0, length: 10)])
        XCTAssertEqual(cache.get(key)?.count, 1)
    }

    func testLayoutKeyIncludesCompression() {
        var t1 = ReaderTypography()
        t1.punctuationCompression = true
        var t2 = ReaderTypography()
        t2.punctuationCompression = false
        XCTAssertNotEqual(t1.layoutKey, t2.layoutKey)
    }
}
