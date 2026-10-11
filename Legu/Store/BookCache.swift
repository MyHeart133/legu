import Foundation

/// 阅读内存缓存:目录 + 章节正文(加速二次打开与翻章)
@MainActor
final class BookCache {
    static let shared = BookCache()

    private var tocStore: [String: [SourceChapter]] = [:]
    private var tocOrder: [String] = []
    private var chapterStore: [String: String] = [:]
    private var chapterOrder: [String] = []

    private let tocLimit = 80
    private let chapterLimit = 240

    // MARK: - 目录

    func toc(for key: String) -> [SourceChapter]? {
        tocStore[key]
    }

    func setToc(_ list: [SourceChapter], for key: String) {
        if tocStore[key] == nil {
            tocOrder.append(key)
            if tocOrder.count > tocLimit {
                let old = tocOrder.removeFirst()
                tocStore.removeValue(forKey: old)
            }
        }
        tocStore[key] = list
    }

    // MARK: - 章节

    func chapter(for key: String) -> String? {
        chapterStore[key]
    }

    func setChapter(_ text: String, for key: String) {
        if chapterStore[key] == nil {
            chapterOrder.append(key)
            if chapterOrder.count > chapterLimit {
                let old = chapterOrder.removeFirst()
                chapterStore.removeValue(forKey: old)
            }
        }
        chapterStore[key] = text
    }

    func hasChapter(_ key: String) -> Bool {
        chapterStore[key] != nil
    }

    // MARK: - Key

    static func tocKey(sourceID: String, bookID: String) -> String {
        "toc|\(sourceID)|\(bookID)"
    }

    static func chapterKey(sourceID: String, bookID: String, chapterID: String) -> String {
        "ch|\(sourceID)|\(bookID)|\(chapterID)"
    }
}
