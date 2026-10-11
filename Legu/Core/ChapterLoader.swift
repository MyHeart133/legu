import Foundation

/// 章节正文统一加载:缓存优先 → 抓取(带重试)→ 写缓存
@MainActor
enum ChapterLoader {

    static func load(sourceStore: SourceStore, book: SourceBook, chapter: SourceChapter) async throws -> String {
        let key = BookCache.chapterKey(
            sourceID: book.sourceID,
            bookID: book.sourceBookID,
            chapterID: chapter.id
        )
        if let cached = BookCache.shared.chapter(for: key) {
            return cached
        }
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            throw SourceError.network("找不到书源(可能已被删除)")
        }
        let text = try await HTTP.retrying {
            try await source.fetchChapterContent(book.sourceBookID, chapterID: chapter.id)
        }
        BookCache.shared.setChapter(text, for: key)
        return text
    }
}
