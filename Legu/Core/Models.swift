import Foundation

/// 来源能力声明:UI 只依据真实能力展示入口
struct SourceCapabilities: Equatable, Codable {
    var search: Bool
    var metadata: Bool
    var onlineReading: Bool
    var requiresAccount: Bool
    var allowsOffline: Bool

    static let webNovel = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    static let detailOnly = SourceCapabilities(
        search: false, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )
}

/// 统一书籍模型(跨来源)
struct SourceBook: Identifiable, Equatable, Hashable {
    var sourceID: String
    var sourceBookID: String
    var title: String
    var author: String
    var cover: String?
    var language: String?
    var summary: String?
    var subjects: [String]

    var id: String { "\(sourceID):\(sourceBookID)" }
}

struct SourceChapter: Identifiable, Equatable, Codable {
    var id: String
    var index: Int
    var title: String
    var isFree: Bool = true
}

enum SourceError: LocalizedError {
    case network(String)
    case decode(String)
    case notFound
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .network(let m): return "网络错误:\(m)"
        case .decode(let m): return "解析失败:\(m)"
        case .notFound: return "未找到该内容"
        case .unsupported(let m): return m
        }
    }
}

/// 统一内容源接口。不支持的能力必须在 capabilities 中声明为 false,
/// 对应方法可以继续使用默认实现(抛出 unsupported)。
protocol ContentSource: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }
    func search(_ query: String) async throws -> [SourceBook]
    func fetchDetail(_ bookID: String) async throws -> SourceBook
    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter]
    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String
}

extension ContentSource {
    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        throw SourceError.unsupported("\(displayName) 暂不支持详情接口")
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        throw SourceError.unsupported("\(displayName) 暂不支持逐章列表")
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        throw SourceError.unsupported("\(displayName) 暂不支持逐章读取")
    }
}

/// 单个书源的一批搜索结果(流式聚合用)
struct SourceSearchBatch: Sendable, Identifiable {
    var id: String { sourceID }
    let sourceID: String
    let sourceName: String
    let books: [SourceBook]
    let error: String?
}
