import SwiftUI

struct SearchView: View {
    @EnvironmentObject var sourceStore: SourceStore

    @State private var query = ""
    @State private var batches: [SourceSearchBatch] = []
    @State private var searching = false
    @State private var doneCount = 0
    @State private var totalCount = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if searching || !batches.isEmpty {
                    Section {
                        HStack {
                            if searching {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(searching ? "搜索中 \(doneCount)/\(totalCount) 个书源…" : "完成:共 \(totalCount) 个书源")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            let found = batches.reduce(0) { $0 + $1.books.count }
                            Text("\(found) 本")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                ForEach(batches) { batch in
                    if !batch.books.isEmpty || batch.error != nil {
                        Section {
                            ForEach(batch.books) { book in
                                NavigationLink(value: book) {
                                    BookResultRow(book: book)
                                }
                            }
                            if let error = batch.error {
                                Text("✗ \(error)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } header: {
                            HStack {
                                Text(batch.sourceName)
                                Spacer()
                                Text(batch.books.isEmpty ? "无结果" : "\(batch.books.count) 本")
                            }
                        }
                    }
                }

                if !searching && batches.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("输入书名或作者,多书源同时搜索")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("当前启用 \(sourceStore.enabledCount) 个书源")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .navigationDestination(for: SourceBook.self) { book in
                BookDetailView(book: book, sourceName: nameFor(book.sourceID))
            }
            .searchable(text: $query, prompt: "书名 / 作者")
            .onSubmit(of: .search) { startSearch() }
            .toolbar {
                if searching {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("停止") { stopSearch() }
                    }
                }
            }
        }
    }

    private func nameFor(_ sourceID: String) -> String {
        sourceStore.record(forBookSourceID: sourceID)?.name ?? sourceID
    }

    private func startSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        batches = []
        doneCount = 0
        let sources = sourceStore.enabledSources
        totalCount = sources.count
        guard !sources.isEmpty else { return }
        searching = true
        searchTask = Task { @MainActor in
            for await batch in SearchService.stream(query: q, sources: sources) {
                if Task.isCancelled { break }
                batches.append(batch)
                doneCount += 1
            }
            searching = false
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        searching = false
    }
}

struct BookResultRow: View {
    let book: SourceBook

    var body: some View {
        HStack(spacing: 12) {
            CoverView(url: book.cover, title: book.title, width: 40, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(book.author.isEmpty ? "佚名" : book.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let summary = book.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 1)
    }
}
