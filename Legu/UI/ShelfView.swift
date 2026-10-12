import SwiftUI

struct ShelfView: View {
    @EnvironmentObject var shelf: ShelfStore

    var body: some View {
        NavigationStack {
            Group {
                if shelf.books.isEmpty {
                    ContentUnavailableView(
                        "书架是空的",
                        systemImage: "books.vertical",
                        description: Text("去「搜索」找一本书,或到「书源」导入更多书源")
                    )
                } else {
                    List {
                        ForEach(shelf.books) { book in
                            NavigationLink(value: book) {
                                ShelfRow(book: book)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                shelf.remove(id: shelf.books[i].id)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("书架")
            .navigationDestination(for: ShelfBook.self) { book in
                ShelfBookOpenerView(book: book)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
            }
        }
    }
}

struct ShelfRow: View {
    let book: ShelfBook

    var body: some View {
        HStack(spacing: 12) {
            CoverView(url: book.cover, title: book.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.body)
                    .lineLimit(1)
                Text(book.author.isEmpty ? "佚名" : book.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(book.sourceName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if !book.lastChapterTitle.isEmpty {
                        Text("读到:\(book.lastChapterTitle)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 从书架打开:先取目录(缓存优先),再进阅读器
struct ShelfBookOpenerView: View {
    let book: ShelfBook

    @EnvironmentObject var sourceStore: SourceStore
    @State private var chapters: [SourceChapter] = []
    @State private var state: LoadState = .loading
    @State private var errorText: String?

    enum LoadState {
        case loading, ready, failed
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("加载目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                ReaderView(
                    book: book.asSourceBook,
                    sourceName: book.sourceName,
                    chapters: chapters,
                    initialIndex: book.lastChapterIndex,
                    initialOffset: book.lastOffset
                )
            case .failed:
                VStack(spacing: 14) {
                    Text(errorText ?? "加载失败")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load(useCache: false) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load(useCache: true) }
    }

    private func load(useCache: Bool) async {
        state = .loading
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            // 书源被删了,但下载过的话还能离线读
            if let offline = OfflineStore.loadTOC(offlineKey), !offline.isEmpty {
                chapters = offline
                state = .ready
                return
            }
            errorText = "找不到对应书源(可能已被删除)\n请回到「搜索」重新找这本书"
            state = .failed
            return
        }
        let key = BookCache.tocKey(sourceID: book.sourceID, bookID: book.sourceBookID)
        if useCache, let cached = BookCache.shared.toc(for: key), !cached.isEmpty {
            chapters = cached
            state = .ready
            return
        }
        if useCache, let offline = OfflineStore.loadTOC(offlineKey), !offline.isEmpty {
            chapters = offline
            state = .ready
            return
        }
        do {
            let list = try await HTTP.retrying {
                try await source.fetchChapterList(book.sourceBookID)
            }
            guard !list.isEmpty else {
                errorText = "目录为空"
                state = .failed
                return
            }
            BookCache.shared.setToc(list, for: key)
            chapters = list
            state = .ready
        } catch {
            if let offline = OfflineStore.loadTOC(offlineKey), !offline.isEmpty {
                chapters = offline
                state = .ready
            } else {
                errorText = "目录加载失败:\(error.localizedDescription)"
                state = .failed
            }
        }
    }

    private var offlineKey: String {
        OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
    }
}

/// 书籍详情(搜索结果点入;支持多来源切换)
struct BookDetailView: View {
    let alternatives: [BookAlternative]

    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var sourceStore: SourceStore
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var zlibImporter = ZLibImporter.shared

    @State private var current: BookAlternative
    @State private var detail: SourceBook
    @State private var chapters: [SourceChapter] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var zlibImporting = false
    @State private var zlibError: String?

    init(book: SourceBook, sourceName: String, alternatives: [BookAlternative] = []) {
        var alts = alternatives
        let primary = BookAlternative(sourceID: book.sourceID, sourceName: sourceName, book: book)
        if alts.isEmpty {
            alts = [primary]
        } else if alts[0].book != book {
            alts.insert(primary, at: 0)
        }
        self.alternatives = alts
        _current = State(initialValue: alts[0])
        _detail = State(initialValue: alts[0].book)
    }

    private var onShelf: Bool {
        shelf.isOnShelf(sourceID: current.book.sourceID, sourceBookID: current.book.sourceBookID)
    }

    var body: some View {
        List {
            Section {
                header
            }

            if alternatives.count > 1 {
                Section("来源(\(alternatives.count))") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(alternatives) { alt in
                                Button {
                                    switchTo(alt)
                                } label: {
                                    Text(alt.sourceName)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            alt.id == current.id
                                                ? Color.accentColor.opacity(0.16)
                                                : Color.gray.opacity(0.12)
                                        )
                                        .foregroundColor(alt.id == current.id ? .accentColor : .primary)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().stroke(
                                                alt.id == current.id
                                                    ? Color.accentColor
                                                    : Color.gray.opacity(0.25),
                                                lineWidth: alt.id == current.id ? 1.5 : 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let summary = detail.summary, !summary.isEmpty {
                Section("简介") {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Section("离线下载") {
                downloadRow
            }

            Section {
                if loading {
                    HStack {
                        ProgressView()
                        Text("加载目录…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if let e = errorText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(e)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("重试") { Task { await load(useCache: false) } }
                    }
                } else {
                    ForEach(chapters) { ch in
                        NavigationLink {
                            ReaderView(
                                book: current.book,
                                sourceName: current.sourceName,
                                chapters: chapters,
                                initialIndex: max(0, ch.index - 1)
                            )
                        } label: {
                            Text(ch.title)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("目录(\(chapters.count))")
            }
        }
        .navigationTitle(detail.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: current.id) { await load(useCache: true) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(url: detail.cover, title: detail.title, width: 80, height: 108)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title)
                    .font(.headline)
                Text(detail.author.isEmpty ? "佚名" : detail.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(current.sourceName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if !detail.subjects.isEmpty {
                    Text(detail.subjects.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    NavigationLink {
                        ReaderView(
                            book: current.book,
                            sourceName: current.sourceName,
                            chapters: chapters,
                            initialIndex: 0
                        )
                    } label: {
                        Text("开始阅读")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chapters.isEmpty)

                    Button {
                        _ = shelf.add(current.book, sourceName: current.sourceName)
                    } label: {
                        Text(onShelf ? "已在书架" : "加入书架")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(onShelf)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 离线下载

    private var offlineKey: String {
        OfflineStore.bookKey(sourceID: current.book.sourceID, sourceBookID: current.book.sourceBookID)
    }

    @ViewBuilder
    private var downloadRow: some View {
        if current.sourceID == ZLibrarySource.identifier {
            zlibImportRow
        } else {
            standardDownloadRow
        }
    }

    /// Z-Library:整本下载 + 解析(下载后离线阅读、听书)
    @ViewBuilder
    private var zlibImportRow: some View {
        let key = offlineKey
        if OfflineStore.loadTOC(key) != nil {
            HStack {
                Label("已下载 · 离线可读可听", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
                Spacer()
                if zlibImporting {
                    ProgressView()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(zlibImporting ? zlibImporter.phase.text : "下载整本后离线阅读(排版 / 听书照常)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if zlibImporting {
                        ProgressView()
                    } else {
                        Button("下载并阅读") {
                            Task { await startZlibImport() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let zlibError {
                    Text(zlibError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var standardDownloadRow: some View {
        let key = offlineKey
        if let rec = downloads.record(for: key) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(rec.statusText)
                        .font(.subheadline)
                    Spacer()
                    downloadActionButton(rec, key: key)
                }
                if rec.status == .downloading || rec.status == .queued {
                    ProgressView(value: rec.progress)
                }
                Text("\(rec.doneCount)/\(rec.totalChapters) 章 · \(rec.sizeText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            HStack {
                Text("下载全本,离线也能读")
                    .font(.subheadline)
                Spacer()
                Button("下载") {
                    downloads.enqueue(book: current.book, sourceName: current.sourceName, chapters: chapters)
                }
                .buttonStyle(.bordered)
                .disabled(chapters.isEmpty)
            }
        }
    }

    private func startZlibImport() async {
        zlibImporting = true
        zlibError = nil
        defer { zlibImporting = false }
        do {
            _ = try await ZLibImporter.shared.importBook(current.book)
            _ = shelf.add(current.book, sourceName: current.sourceName)
            await load(useCache: false)
        } catch {
            zlibError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func downloadActionButton(_ rec: DownloadRecord, key: String) -> some View {
        switch rec.status {
        case .downloading, .queued:
            Button("暂停") { downloads.pause(id: key) }
                .buttonStyle(.bordered)
        case .paused:
            Button("继续") { downloads.resume(id: key) }
                .buttonStyle(.borderedProminent)
                .disabled(rec.doneCount >= rec.totalChapters)
        case .completed:
            Label("已下载", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(.green)
        }
    }

    private func switchTo(_ alt: BookAlternative) {
        guard alt.id != current.id else { return }
        current = alt
        detail = alt.book
    }

    private func load(useCache: Bool) async {
        loading = true
        errorText = nil
        chapters = []
        guard let source = sourceStore.source(forBookSourceID: current.sourceID) else {
            errorText = "找不到对应书源"
            loading = false
            return
        }
        let key = BookCache.tocKey(sourceID: current.sourceID, bookID: current.book.sourceBookID)
        let offlineKey = OfflineStore.bookKey(sourceID: current.sourceID, sourceBookID: current.book.sourceBookID)
        // Z-Library:目录 = 本地解析结果;未下载时显示下载引导(不报错)
        if current.sourceID == ZLibrarySource.identifier {
            if let toc = OfflineStore.loadTOC(offlineKey), !toc.isEmpty {
                chapters = toc
            }
            loading = false
            if let d = try? await source.fetchDetail(current.book.sourceBookID) {
                detail = d
            }
            return
        }
        if useCache, let cached = BookCache.shared.toc(for: key), !cached.isEmpty {
            chapters = cached
            loading = false
            if let d = try? await source.fetchDetail(current.book.sourceBookID) {
                detail = d
            }
            return
        }
        if useCache, let offline = OfflineStore.loadTOC(offlineKey), !offline.isEmpty {
            chapters = offline
            loading = false
            if let d = try? await source.fetchDetail(current.book.sourceBookID) {
                detail = d
            }
            return
        }
        if let d = try? await source.fetchDetail(current.book.sourceBookID) {
            detail = d
        }
        do {
            let list = try await HTTP.retrying {
                try await source.fetchChapterList(current.book.sourceBookID)
            }
            BookCache.shared.setToc(list, for: key)
            chapters = list
        } catch {
            if let offline = OfflineStore.loadTOC(offlineKey), !offline.isEmpty {
                chapters = offline
            } else {
                errorText = "目录加载失败:\(error.localizedDescription)"
            }
        }
        loading = false
    }
}
