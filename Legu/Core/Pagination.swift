import CoreText
import Foundation

/// 分页器:基于 Core Text 的真实排版分页
///
/// - 输入:与渲染完全相同的 NSAttributedString + 正文区域尺寸
/// - 输出:连续的字符区间数组(不重叠、不遗漏、不丢字)
/// - 支持取消(shouldCancel 回调,循环内检查)与页数上限保护
enum Paginator {

    /// 对整段文本分页。返回的 NSRange 数组按顺序连续覆盖全文
    static func paginate(
        _ attributed: NSAttributedString,
        size: CGSize,
        maxPages: Int = 5000,
        shouldCancel: () -> Bool = { false }
    ) -> [NSRange] {
        let length = attributed.length
        guard length > 0, size.width > 10, size.height > 10 else { return [] }

        var pages: [NSRange] = []
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0

        while start < length && pages.count < maxPages {
            if shouldCancel() { break }
            let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: start, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }  // 防死循环:无法再容纳任何字符
            pages.append(NSRange(location: start, length: visible.length))
            start += visible.length
        }
        return pages
    }

    /// 字符偏移 → 页码(找不到时收敛到最近的合法页)
    static func pageIndex(forOffset offset: Int, in ranges: [NSRange]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let clamped = max(0, offset)
        for (i, r) in ranges.enumerated() {
            if clamped < r.location + r.length { return i }
        }
        return ranges.count - 1
    }
}

/// 分页结果缓存(内存,LRU 淘汰)
@MainActor
final class PaginationCache {
    static let shared = PaginationCache()

    private var store: [String: [NSRange]] = [:]
    private var order: [String] = []
    private let limit = 200

    private init() {}

    func get(_ key: String) -> [NSRange]? {
        store[key]
    }

    func set(_ key: String, _ ranges: [NSRange]) {
        if store[key] == nil {
            order.append(key)
            if order.count > limit {
                let old = order.removeFirst()
                store.removeValue(forKey: old)
            }
        }
        store[key] = ranges
    }

    /// 缓存键:来源+书籍+章节+排版布局签名+正文尺寸(纯函数,任意线程可用)
    nonisolated static func key(
        sourceID: String,
        bookID: String,
        chapterID: String,
        layoutKey: String,
        size: CGSize
    ) -> String {
        "\(sourceID)|\(bookID)|\(chapterID)|\(layoutKey)|\(Int(size.width))x\(Int(size.height))"
    }
}

/// 线程安全的取消标记(跨 Task / 后台线程)
final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
