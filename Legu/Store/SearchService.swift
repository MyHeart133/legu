import Foundation

/// 聚合搜索:多源并发、流式产出(先返回先展示)
enum SearchService {
    static let perSourceTimeout: Double = 15

    static func stream(
        query: String,
        sources: [(id: String, name: String, source: ContentSource)]
    ) -> AsyncStream<SourceSearchBatch> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceSearchBatch.self) { group in
                    for item in sources {
                        group.addTask {
                            do {
                                let books = try await withTimeout(seconds: perSourceTimeout) {
                                    try await item.source.search(query)
                                }
                                return SourceSearchBatch(
                                    sourceID: item.id,
                                    sourceName: item.name,
                                    books: books,
                                    error: nil
                                )
                            } catch {
                                return SourceSearchBatch(
                                    sourceID: item.id,
                                    sourceName: item.name,
                                    books: [],
                                    error: error.localizedDescription
                                )
                            }
                        }
                    }
                    for await batch in group {
                        continuation.yield(batch)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw SourceError.network("搜索超时")
            }
            guard let result = try await group.next() else {
                throw SourceError.network("搜索超时")
            }
            group.cancelAll()
            return result
        }
    }
}
