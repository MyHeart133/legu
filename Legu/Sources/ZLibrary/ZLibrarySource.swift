import Foundation

/// Z-Library 书源:搜索 / 详情走 EAPI;章节读本地(下载解析后离线阅读)
/// 未下载时给出明确引导,不参与在线阅读
@MainActor
final class ZLibrarySource: ContentSource {
    static let identifier = "zlib"

    let identifier = ZLibrarySource.identifier
    let displayName = "Z-Library"
    let capabilities = SourceCapabilities(
        search: true,
        metadata: true,
        onlineReading: false,
        requiresAccount: true,
        allowsOffline: true
    )

    func search(_ query: String) async throws -> [SourceBook] {
        let session = ZLibSession.shared
        guard session.isLoggedIn else {
            throw SourceError.unsupported("未登录 —— 设置 → Z-Library 账号")
        }
        return try await ZLibraryClient.shared.search(
            domain: session.domain,
            cookies: session.currentCookies,
            query: query
        )
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        let session = ZLibSession.shared
        guard session.isLoggedIn else {
            throw SourceError.unsupported("未登录 —— 设置 → Z-Library 账号")
        }
        return try await ZLibraryClient.shared.detail(
            domain: session.domain,
            cookies: session.currentCookies,
            bookID: bookID
        )
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        let key = OfflineStore.bookKey(sourceID: identifier, sourceBookID: bookID)
        if let toc = OfflineStore.loadTOC(key), !toc.isEmpty {
            return toc
        }
        throw SourceError.unsupported("本书还没下载 —— 在详情页点「下载并阅读」")
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        let key = OfflineStore.bookKey(sourceID: identifier, sourceBookID: bookID)
        if let text = OfflineStore.readChapter(bookKey: key, chapterID: chapterID) {
            return text
        }
        throw SourceError.unsupported("本书还没下载 —— 在详情页点「下载并阅读」")
    }
}
