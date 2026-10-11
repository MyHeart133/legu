import SwiftUI

/// 搜索:多源聚合 → 同书合并、按精准度排序(真实书在前)
struct SearchView: View {
    @EnvironmentObject var sourceStore: SourceStore

    @State private var query = ""
    @State private var batches: [SourceSearchBatch] = []
    @State private var merged: [MergedBook] = []
    @State private var searching = false
    @State private var doneCount = 0
    @State private var totalCount = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if searching || !merged.isEmpty {
                    Section {
                        progressRow
                    }
                }

                ForEach(merged) { item in
                    NavigationLink {
                        BookDetailView(
                            book: item.primary.book,
                            sourceName: item.primary.sourceName,
                            alternatives: item.alternatives
                        )
                    } label: {
                        MergedBookRow(item: item)
                    }
                }

                if !searching && merged.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("输入书名或作者,\(sourceStore.enabledCount) 个书源同时搜索")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Text("结果按书名匹配度排序,点进可切换来源")
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

    private var progressRow: some View {
        HStack {
            if searching {
                ProgressView()
                    .controlSize(.small)
            }
            Text(searching ? "搜索中 \(doneCount)/\(totalCount) · 已找到 \(merged.count) 本" : "完成:\(totalCount) 个书源 · \(merged.count) 本")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if searching && totalCount > 120 {
                Text("源多可稍等")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func startSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        batches = []
        merged = []
        doneCount = 0
        let sources = sourceStore.enabledSources
        totalCount = sources.count
        guard !sources.isEmpty else { return }
        searching = true
        searchTask = Task { @MainActor in
            var lastMerge = Date.distantPast
            for await batch in SearchService.stream(query: q, sources: sources) {
                if Task.isCancelled { break }
                batches.append(batch)
                doneCount += 1
                let now = Date()
                if !batch.books.isEmpty && now.timeIntervalSince(lastMerge) > 0.4 {
                    lastMerge = now
                    merged = SearchRanking.merge(batches, query: q)
                }
            }
            merged = SearchRanking.merge(batches, query: q)
            searching = false
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        searching = false
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            merged = SearchRanking.merge(batches, query: q)
        }
    }
}

/// 合并结果行:书名 + 来源
struct MergedBookRow: View {
    let item: MergedBook

    var body: some View {
        HStack(spacing: 12) {
            CoverView(url: item.cover, title: item.title, width: 40, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.author.isEmpty ? "佚名" : item.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.primary.sourceName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if item.sourceCount > 1 {
                        Text("+\(item.sourceCount - 1) 个来源")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}
