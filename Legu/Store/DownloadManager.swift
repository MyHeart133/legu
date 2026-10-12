import Foundation

/// 下载状态
enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
}

/// 单本书的下载记录(持久化到 Documents/legu.downloads.json)
struct DownloadRecord: Codable, Identifiable, Equatable {
    var id: String
    var sourceID: String
    var sourceBookID: String
    var title: String
    var author: String
    var cover: String?
    var sourceName: String
    var totalChapters: Int
    var doneCount: Int
    var failedCount: Int
    var bytes: Int64
    var status: DownloadStatus
    var createdAt: Date
    var updatedAt: Date

    var progress: Double {
        totalChapters > 0 ? min(1, Double(doneCount) / Double(totalChapters)) : 0
    }
}

extension DownloadRecord {
    var statusText: String {
        switch status {
        case .queued: return "等待中"
        case .downloading: return "下载中…"
        case .paused: return failedCount > 0 ? "已暂停(\(failedCount) 章失败,继续可重试)" : "已暂停"
        case .completed: return "已完成"
        }
    }

    var sizeText: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: max(0, bytes))
    }
}

/// 下载管理器:整本下载、断点续传(以章节文件存在为准)、暂停/继续/删除
/// 同时只下载一本书;单本内 3 章并发抓取
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var activeID: String?

    private weak var sourceStore: SourceStore?
    private var worker: Task<Void, Never>?
    private var workerToken: UUID?
    private let manifestURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        manifestURL = dir.appendingPathComponent("legu.downloads.json")
        load()
    }

    // MARK: - 配置 / 持久化

    func configure(sourceStore: SourceStore) {
        self.sourceStore = sourceStore
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = list.map { rec in
            var r = rec
            // 上次运行中断的下载 → 标记暂停;完成度以磁盘文件为准
            if r.status == .downloading || r.status == .queued { r.status = .paused }
            let actual = OfflineStore.downloadedCount(r.id)
            r.doneCount = actual
            if r.totalChapters > 0 && actual >= r.totalChapters {
                r.status = .completed
            } else if r.status == .completed {
                r.status = .paused
            }
            return r
        }
        records.sort { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func touch(_ id: String, _ mutate: (inout DownloadRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[idx])
        records[idx].updatedAt = Date()
        save()
    }

    // MARK: - 查询

    func record(for bookKey: String) -> DownloadRecord? {
        records.first { $0.id == bookKey }
    }

    var totalBytes: Int64 {
        records.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - 操作

    /// 下载整本(已有记录则补齐缺失章节并刷新目录)
    func enqueue(book: SourceBook, sourceName: String, chapters: [SourceChapter]) {
        guard !chapters.isEmpty else { return }
        let key = OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
        OfflineStore.saveTOC(chapters, for: key)

        if let idx = records.firstIndex(where: { $0.id == key }) {
            records[idx].totalChapters = chapters.count
            records[idx].doneCount = OfflineStore.downloadedCount(key)
            records[idx].bytes = OfflineStore.bookSize(key)
            records[idx].updatedAt = Date()
            if records[idx].doneCount >= chapters.count {
                records[idx].status = .completed
                save()
                return
            }
            if records[idx].status != .downloading {
                records[idx].status = .queued
            }
        } else {
            let rec = DownloadRecord(
                id: key,
                sourceID: book.sourceID,
                sourceBookID: book.sourceBookID,
                title: book.title,
                author: book.author,
                cover: book.cover,
                sourceName: sourceName,
                totalChapters: chapters.count,
                doneCount: OfflineStore.downloadedCount(key),
                failedCount: 0,
                bytes: OfflineStore.bookSize(key),
                status: .queued,
                createdAt: Date(),
                updatedAt: Date()
            )
            records.insert(rec, at: 0)
        }
        save()
        pump()
    }

    func pause(id: String) {
        if activeID == id {
            worker?.cancel()
            worker = nil
            workerToken = nil
            activeID = nil
        }
        touch(id) { rec in
            if rec.status == .downloading || rec.status == .queued {
                rec.status = .paused
            }
        }
        pump()
    }

    func resume(id: String) {
        guard let rec = record(for: id), rec.doneCount < rec.totalChapters else { return }
        touch(id) { $0.status = .queued }
        pump()
    }

    func remove(id: String) {
        if activeID == id {
            worker?.cancel()
            worker = nil
            workerToken = nil
            activeID = nil
        }
        OfflineStore.deleteBook(id)
        records.removeAll { $0.id == id }
        save()
        pump()
    }

    /// 以磁盘为准刷新计数与体积
    func refreshSizes() {
        for i in records.indices {
            records[i].doneCount = OfflineStore.downloadedCount(records[i].id)
            records[i].bytes = OfflineStore.bookSize(records[i].id)
            if records[i].totalChapters > 0, records[i].doneCount >= records[i].totalChapters {
                records[i].status = .completed
            }
        }
        save()
    }

    /// 登记整本导入的书(Z-Library 等):已完成状态,供「下载管理」统计与删除
    func registerImported(book: SourceBook, sourceName: String, chapterCount: Int, bytes: Int64) {
        let key = OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
        if let idx = records.firstIndex(where: { $0.id == key }) {
            records[idx].totalChapters = chapterCount
            records[idx].doneCount = chapterCount
            records[idx].bytes = bytes
            records[idx].failedCount = 0
            records[idx].status = .completed
            records[idx].updatedAt = Date()
        } else {
            records.insert(DownloadRecord(
                id: key,
                sourceID: book.sourceID,
                sourceBookID: book.sourceBookID,
                title: book.title,
                author: book.author,
                cover: book.cover,
                sourceName: sourceName,
                totalChapters: chapterCount,
                doneCount: chapterCount,
                failedCount: 0,
                bytes: bytes,
                status: .completed,
                createdAt: Date(),
                updatedAt: Date()
            ), at: 0)
        }
        save()
    }

    // MARK: - 下载执行

    private func pump() {
        guard worker == nil else { return }
        guard let next = records.first(where: { $0.status == .queued }) else { return }
        let token = UUID()
        workerToken = token
        activeID = next.id
        touch(next.id) { rec in
            rec.status = .downloading
            rec.failedCount = 0
        }
        worker = Task { @MainActor [weak self] in
            await self?.runDownload(id: next.id)
            guard let self, self.workerToken == token else { return }
            self.worker = nil
            self.workerToken = nil
            self.activeID = nil
            self.pump()
        }
    }

    private func runDownload(id: String) async {
        guard let sourceStore else {
            touch(id) { $0.status = .paused }
            return
        }
        guard let rec = record(for: id) else { return }
        guard let source = sourceStore.source(forBookSourceID: rec.sourceID) else {
            touch(id) { $0.status = .paused }
            return
        }
        let sourceBookID = rec.sourceBookID
        let chapters = OfflineStore.loadTOC(id) ?? []
        let pending = chapters.filter { !OfflineStore.hasChapter(bookKey: id, chapterID: $0.id) }
        guard !pending.isEmpty else {
            touch(id) { rec in
                rec.doneCount = OfflineStore.downloadedCount(id)
                rec.bytes = OfflineStore.bookSize(id)
                rec.status = .completed
            }
            return
        }

        var failed = 0
        let batchSize = 3
        var idx = 0
        while idx < pending.count {
            if Task.isCancelled { return }
            let slice = Array(pending[idx..<min(idx + batchSize, pending.count)])
            await withTaskGroup(of: (Int, Bool).self) { group in
                for ch in slice {
                    group.addTask {
                        // 轻微错峰,别把书源打急
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        do {
                            let text = try await HTTP.retrying {
                                try await source.fetchChapterContent(sourceBookID, chapterID: ch.id)
                            }
                            guard !text.isEmpty else { return (0, false) }
                            let ok = OfflineStore.saveChapter(text, bookKey: id, chapterID: ch.id)
                            return (ok ? text.utf8.count : 0, ok)
                        } catch {
                            return (0, false)
                        }
                    }
                }
                for await (size, ok) in group {
                    if ok {
                        touch(id) { rec in
                            rec.doneCount += 1
                            rec.bytes += Int64(size)
                        }
                    } else {
                        failed += 1
                    }
                }
            }
            idx += batchSize
        }

        if Task.isCancelled { return }
        touch(id) { rec in
            let actual = OfflineStore.downloadedCount(id)
            rec.failedCount = failed
            rec.doneCount = actual
            rec.bytes = OfflineStore.bookSize(id)
            rec.status = (rec.totalChapters > 0 && actual >= rec.totalChapters) ? .completed : .paused
        }
    }
}
