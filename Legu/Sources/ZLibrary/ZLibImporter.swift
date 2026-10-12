import Foundation

/// Z-Library 书籍导入:下载 EPUB → 解析 → 落盘(OfflineStore)→ 登记下载管理
@MainActor
final class ZLibImporter: ObservableObject {
    static let shared = ZLibImporter()

    enum Phase: Equatable {
        case idle
        case fetchingLink
        case downloading
        case parsing
        case done
        case failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .fetchingLink: return "获取下载链接…"
            case .downloading: return "下载中…"
            case .parsing: return "解析中…"
            case .done: return "完成"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var activeBookKey: String?
    @Published private(set) var phase: Phase = .idle

    /// 下载并解析一本书(可重复调用:已下载的会覆盖刷新);返回章节列表
    @discardableResult
    func importBook(_ book: SourceBook) async throws -> [SourceChapter] {
        let session = ZLibSession.shared
        guard session.isLoggedIn else {
            throw SourceError.unsupported("未登录 Z-Library(设置 → Z-Library 账号)")
        }
        let key = OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
        activeBookKey = key
        defer { activeBookKey = nil }

        do {
            phase = .fetchingLink
            let link = try await ZLibraryClient.shared.downloadLink(
                domain: session.domain,
                cookies: session.currentCookies,
                bookID: book.sourceBookID
            )

            phase = .downloading
            let data = try await ZLibraryClient.shared.download(from: link)

            phase = .parsing
            let parsed: EPUBParser.ParsedBook
            if data.prefix(2) == Data([0x50, 0x4B]) {
                parsed = try EPUBParser.parse(data)
            } else {
                parsed = parsePlainText(data, fallbackTitle: book.title)
            }
            guard !parsed.chapters.isEmpty else {
                throw SourceError.decode("解析后没有可读内容")
            }

            // 落盘(复用离线存储:阅读 / 听书 / 下载管理全部天然打通)
            let chapters = parsed.chapters.enumerated().map { i, ch in
                SourceChapter(id: "epub:\(i)", index: i + 1, title: ch.title)
            }
            guard OfflineStore.saveTOC(chapters, for: key) else {
                throw SourceError.decode("写入目录失败")
            }
            for (i, ch) in parsed.chapters.enumerated() {
                guard OfflineStore.saveChapter(ch.text, bookKey: key, chapterID: "epub:\(i)") else {
                    throw SourceError.decode("写入章节失败")
                }
            }

            // 登记到下载管理(体积统计 / 可删除)
            DownloadManager.shared.registerImported(
                book: book,
                sourceName: "Z-Library",
                chapterCount: chapters.count,
                bytes: OfflineStore.bookSize(key)
            )
            await session.refreshProfile()
            phase = .done
            return chapters
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 纯文本兜底(少数条目标为 epub 实为 txt):按「第X章/节/回」切章
    private func parsePlainText(_ data: Data, fallbackTitle: String) -> EPUBParser.ParsedBook {
        let text = HTTP.decode(data, encoding: HTTP.sniffEncoding(data) ?? .utf8)
        let cleaned = HTMLText.normalizeLines(text)
        guard !cleaned.isEmpty else {
            return EPUBParser.ParsedBook(title: fallbackTitle, author: "", chapters: [])
        }
        let chapterPattern = "^第[0-9零一二三四五六七八九十百千两]{1,6}[章节回卷].{0,30}$"
        var chapters: [(title: String, text: String)] = []
        var currentTitle: String?
        var buffer: [String] = []

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                chapters.append((currentTitle ?? "第 \(chapters.count + 1) 节", body))
            }
            buffer = []
        }

        for line in cleaned.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 40, HTMLText.matches(chapterPattern, in: trimmed) {
                flush()
                currentTitle = trimmed
            } else {
                buffer.append(line)
            }
        }
        flush()

        if chapters.count <= 1 {
            return EPUBParser.ParsedBook(
                title: fallbackTitle, author: "",
                chapters: [(fallbackTitle, cleaned)]
            )
        }
        return EPUBParser.ParsedBook(title: fallbackTitle, author: "", chapters: chapters)
    }
}
