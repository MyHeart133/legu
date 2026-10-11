import Foundation

/// 书架书籍(含阅读进度)
struct ShelfBook: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var sourceID: String
    var sourceBookID: String
    var title: String
    var author: String
    var cover: String?
    var sourceName: String
    var lastChapterIndex: Int
    var lastChapterTitle: String
    /// 章内字符偏移(分页模式恢复位置用;旧数据为 nil)
    var lastOffset: Int? = nil
    var updatedAt: Date

    var asSourceBook: SourceBook {
        SourceBook(
            sourceID: sourceID,
            sourceBookID: sourceBookID,
            title: title,
            author: author,
            cover: cover,
            language: "zh",
            summary: nil,
            subjects: []
        )
    }
}

/// 书架仓库
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var books: [ShelfBook] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent("legu.shelf.json")
        self.fileURL = u
        if let data = try? Data(contentsOf: u),
           let list = try? JSONDecoder().decode([ShelfBook].self, from: data) {
            self.books = list.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: fileURL)
        }
    }

    static func makeID(sourceID: String, sourceBookID: String) -> String {
        "\(sourceID)|\(sourceBookID)"
    }

    func isOnShelf(sourceID: String, sourceBookID: String) -> Bool {
        let id = Self.makeID(sourceID: sourceID, sourceBookID: sourceBookID)
        return books.contains { $0.id == id }
    }

    @discardableResult
    func add(_ book: SourceBook, sourceName: String) -> ShelfBook {
        let id = Self.makeID(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
        if let idx = books.firstIndex(where: { $0.id == id }) {
            var entry = books.remove(at: idx)
            entry.updatedAt = Date()
            books.insert(entry, at: 0)
            save()
            return entry
        }
        let entry = ShelfBook(
            id: id,
            sourceID: book.sourceID,
            sourceBookID: book.sourceBookID,
            title: book.title,
            author: book.author,
            cover: book.cover,
            sourceName: sourceName,
            lastChapterIndex: 0,
            lastChapterTitle: "",
            updatedAt: Date()
        )
        books.insert(entry, at: 0)
        save()
        return entry
    }

    func remove(id: String) {
        books.removeAll { $0.id == id }
        save()
    }

    func updateProgress(sourceID: String, sourceBookID: String, chapterIndex: Int, chapterTitle: String, offset: Int? = nil) {
        let id = Self.makeID(sourceID: sourceID, sourceBookID: sourceBookID)
        guard let idx = books.firstIndex(where: { $0.id == id }) else { return }
        books[idx].lastChapterIndex = chapterIndex
        books[idx].lastChapterTitle = chapterTitle
        if let offset {
            books[idx].lastOffset = offset
        }
        books[idx].updatedAt = Date()
        save()
    }
}
