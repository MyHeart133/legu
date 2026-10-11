import Foundation

/// 同书多来源选项(换源用)
struct BookAlternative: Identifiable, Hashable {
    var id: String { "\(sourceID)|\(book.sourceBookID)" }
    let sourceID: String
    let sourceName: String
    let book: SourceBook
}

/// 聚合后的书籍(同书合并多来源,按精准度排序)
struct MergedBook: Identifiable {
    var id: String
    var title: String
    var author: String
    var cover: String?
    var score: Int
    var alternatives: [BookAlternative]

    var primary: BookAlternative { alternatives[0] }
    var sourceCount: Int { alternatives.count }
}

/// 搜索精准度排序与多源合并
enum SearchRanking {

    /// 相关度评分:标题精确 > 前缀 > 包含 > 作者匹配
    static func score(title: String, author: String, query: String) -> Int {
        let q = HTMLText.normalizedKey(query)
        guard !q.isEmpty else { return 0 }
        let t = HTMLText.normalizedKey(title)
        let a = HTMLText.normalizedKey(author)

        var s = 0
        if !t.isEmpty {
            if t == q {
                s += 1000
            } else if t.hasPrefix(q) {
                s += 800
            } else if t.contains(q) {
                s += 600
            } else if q.contains(t) {
                s += 300
            }
        }
        if !a.isEmpty {
            if a == q {
                s += 500
            } else if a.contains(q) {
                s += 250
            }
        }
        // 冗长标题轻微降权(非精确匹配时)
        if s > 0 && s < 1000 {
            s -= min(t.count, 20)
        }
        return s
    }

    /// 合并所有来源的结果:同书合并、按精准度排序、附带全部来源
    static func merge(_ batches: [SourceSearchBatch], query: String) -> [MergedBook] {
        struct Group {
            var title: String
            var author: String
            var cover: String?
            var score: Int
            var alts: [BookAlternative]
        }
        var groups: [String: Group] = [:]
        var order: [String] = []

        for batch in batches {
            for book in batch.books {
                let s = score(title: book.title, author: book.author, query: query)
                let key = HTMLText.normalizedKey(book.title) + "|" + HTMLText.normalizedKey(book.author)
                let alt = BookAlternative(sourceID: batch.sourceID, sourceName: batch.sourceName, book: book)
                if var g = groups[key] {
                    g.alts.append(alt)
                    if s > g.score {
                        g.score = s
                        g.cover = book.cover
                        g.title = book.title
                        g.author = book.author
                    }
                    groups[key] = g
                } else {
                    groups[key] = Group(
                        title: book.title,
                        author: book.author,
                        cover: book.cover,
                        score: s,
                        alts: [alt]
                    )
                    order.append(key)
                }
            }
        }

        var result: [MergedBook] = order.compactMap { key in
            guard let g = groups[key] else { return nil }
            let sorted = g.alts.sorted {
                score(title: $0.book.title, author: $0.book.author, query: query)
                    > score(title: $1.book.title, author: $1.book.author, query: query)
            }
            return MergedBook(
                id: key,
                title: g.title,
                author: g.author,
                cover: g.cover,
                score: g.score,
                alternatives: sorted
            )
        }

        // 有相关结果时过滤纯噪音;全无相关时保留全部
        let positive = result.filter { $0.score > 0 }
        if !positive.isEmpty {
            result = positive
        }

        result.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.title.count != b.title.count { return a.title.count < b.title.count }
            return a.title < b.title
        }
        return result
    }
}
