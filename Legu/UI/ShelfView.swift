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

/// 从书架打开:先加载目录,再进阅读器
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
                    initialIndex: book.lastChapterIndex
                )
            case .failed:
                VStack(spacing: 14) {
                    Text(errorText ?? "加载失败")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            errorText = "找不到对应书源(可能已被删除)\n请回到「搜索」重新找这本书"
            state = .failed
            return
        }
        do {
            let list = try await source.fetchChapterList(book.sourceBookID)
            guard !list.isEmpty else {
                errorText = "目录为空"
                state = .failed
                return
            }
            chapters = list
            state = .ready
        } catch {
            errorText = "目录加载失败:\(error.localizedDescription)"
            state = .failed
        }
    }
}

/// 书籍详情(搜索结果点入)
struct BookDetailView: View {
    let book: SourceBook
    let sourceName: String

    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var sourceStore: SourceStore

    @State private var detail: SourceBook
    @State private var chapters: [SourceChapter] = []
    @State private var loading = true
    @State private var errorText: String?

    init(book: SourceBook, sourceName: String) {
        self.book = book
        self.sourceName = sourceName
        _detail = State(initialValue: book)
    }

    private var onShelf: Bool {
        shelf.isOnShelf(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: detail.cover, title: detail.title, width: 80, height: 108)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.title).font(.headline)
                        Text(detail.author.isEmpty ? "佚名" : detail.author)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(sourceName)
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
                                    book: detail,
                                    sourceName: sourceName,
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
                                _ = shelf.add(detail, sourceName: sourceName)
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

            if let summary = detail.summary, !summary.isEmpty {
                Section("简介") {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                if loading {
                    HStack {
                        ProgressView()
                        Text("加载目录…").font(.subheadline).foregroundColor(.secondary)
                    }
                } else if let e = errorText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(e).font(.subheadline).foregroundColor(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    ForEach(chapters) { ch in
                        NavigationLink {
                            ReaderView(
                                book: detail,
                                sourceName: sourceName,
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
        .task { await load() }
    }

    private func load() async {
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            errorText = "找不到对应书源"
            loading = false
            return
        }
        if let d = try? await source.fetchDetail(book.sourceBookID) {
            detail = d
        }
        do {
            chapters = try await source.fetchChapterList(book.sourceBookID)
        } catch {
            errorText = "目录加载失败:\(error.localizedDescription)"
        }
        loading = false
    }
}
