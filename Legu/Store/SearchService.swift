import Foundation

/// 聚合搜索:多源并发(限流)、流式产出(先返回先展示)
enum SearchService {
    /// 单源超时(超过即跳过,不再拖慢整体)
    static let perSourceTimeout: Double = 12
    /// 同时进行的最大请求数(数百书源时防止连接风暴)
    static let maxConcurrent = 32

    static func stream(
        query: String,
        sources: [(id: String, name: String, source: ContentSource)]
    ) -> AsyncStream<SourceSearchBatch> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceSearchBatch.self) { group in
                    var iterator = sources.makeIterator()
                    var running = 0

                    func seed(_ item: (id: String, name: String, source: ContentSource)) {
                        group.addTask {
                            await run(item, query: query)
                        }
                    }

                    while running < maxConcurrent, let item = iterator.next() {
                        seed(item)
                        running += 1
                    }
                    while let batch = await group.next() {
                        continuation.yield(batch)
                        if let item = iterator.next() {
                            seed(item)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        _ item: (id: String, name: String, source: ContentSource),
        query: String
    ) async -> SourceSearchBatch {
        do {
            let books = try await withTimeout(seconds: perSourceTimeout) {
                try await item.source.search(query)
            }
            return SourceSearchBatch(sourceID: item.id, sourceName: item.name, books: books, error: nil)
        } catch {
            return SourceSearchBatch(
                sourceID: item.id,
                sourceName: item.name,
                books: [],
                error: error.localizedDescription
            )
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
