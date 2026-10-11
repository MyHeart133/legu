import Foundation

/// 章节正文统一加载:离线下载 → 内存缓存 → 抓取(带重试)→ 写缓存
@MainActor
enum ChapterLoader {

    static func load(sourceStore: SourceStore, book: SourceBook, chapter: SourceChapter) async throws -> String {
        let key = BookCache.chapterKey(
            sourceID: book.sourceID,
            bookID: book.sourceBookID,
            chapterID: chapter.id
        )
        // 1. 离线下载的副本(最稳,断网也能读)
        let offlineKey = OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
        if let offline = OfflineStore.readChapter(bookKey: offlineKey, chapterID: chapter.id) {
            BookCache.shared.setChapter(offline, for: key)
            return offline
        }
        // 2. 内存缓存
        if let cached = BookCache.shared.chapter(for: key) {
            return cached
        }
        // 3. 在线抓取
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
