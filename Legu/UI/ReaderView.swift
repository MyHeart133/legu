import SwiftUI

/// 阅读器:逐章在线阅读 + 排版设置 + 目录跳转 + 进度记录
struct ReaderView: View {
    let book: SourceBook
    let sourceName: String
    let chapters: [SourceChapter]
    let initialIndex: Int

    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var sourceStore: SourceStore
    @EnvironmentObject var settings: SettingsStore

    @State private var index: Int
    @State private var content = ""
    @State private var loading = false
    @State private var errorText: String?
    @State private var showCatalog = false
    @State private var showSettings = false

    init(book: SourceBook, sourceName: String, chapters: [SourceChapter], initialIndex: Int) {
        self.book = book
        self.sourceName = sourceName
        self.chapters = chapters
        self.initialIndex = initialIndex
        let clamped = max(0, min(initialIndex, max(0, chapters.count - 1)))
        _index = State(initialValue: clamped)
    }

    private var typo: ReaderTypography { settings.typography }

    private var currentChapter: SourceChapter? {
        (index >= 0 && index < chapters.count) ? chapters[index] : nil
    }

    var body: some View {
        ZStack {
            Color(hex: typo.theme.background).ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let ch = currentChapter {
                            Text(ch.title)
                                .font(.system(size: typo.fontSize * 0.8))
                                .foregroundColor(Color(hex: typo.theme.secondary))
                                .padding(.bottom, 18)
                        }
                        if loading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.top, 60)
                        } else if let e = errorText {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(e)
                                    .font(.subheadline)
                                    .foregroundColor(Color(hex: typo.theme.secondary))
                                Button("重试") {
                                    Task { await loadContent() }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 40)
                        } else {
                            contentView
                            nextChapterButton
                                .padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                bottomInfoLine
                bottomBar
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCatalog = true
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .task(id: index) { await loadContent() }
        .onAppear {
            _ = shelf.add(book, sourceName: sourceName)
        }
    }

    // MARK: - 子视图

    private var contentView: some View {
        let paragraphs = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: typo.paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.system(size: typo.fontSize))
                    .lineSpacing(typo.fontSize * (typo.lineSpacing - 1))
                    .foregroundColor(Color(hex: typo.theme.foreground))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nextChapterButton: some View {
        Button {
            nextChapter()
        } label: {
            Text(index >= chapters.count - 1 ? "已是最后一章" : "下一章 →")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .disabled(index >= chapters.count - 1)
    }

    private var bottomInfoLine: some View {
        HStack {
            Text(currentChapter?.title ?? "")
                .font(.caption2)
                .foregroundColor(Color(hex: typo.theme.secondary))
                .lineLimit(1)
            Spacer()
            Text("\(index + 1)/\(chapters.count)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Color(hex: typo.theme.secondary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    prevChapter()
                } label: {
                    Label("上一章", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                .disabled(index <= 0)

                Button {
                    showCatalog = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    showSettings = true
                } label: {
                    Label("排版", systemImage: "textformat.size")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    nextChapter()
                } label: {
                    Label("下一章", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                .disabled(index >= chapters.count - 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .background(Color(hex: typo.theme.background))
    }

    private var catalogSheet: some View {
        NavigationStack {
            List {
                ForEach(chapters) { ch in
                    Button {
                        index = max(0, ch.index - 1)
                        showCatalog = false
                    } label: {
                        HStack {
                            Text(ch.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                            Spacer()
                            if ch.index - 1 == index {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录(\(chapters.count) 章)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("排版") {
                    TypographyControls()
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 行为

    private func prevChapter() {
        if index > 0 { index -= 1 }
    }

    private func nextChapter() {
        if index < chapters.count - 1 { index += 1 }
    }

    private func loadContent() async {
        guard index >= 0, index < chapters.count else { return }
        let chapter = chapters[index]
        loading = true
        errorText = nil
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            errorText = "找不到书源(可能已被删除)"
            loading = false
            return
        }
        do {
            let text = try await source.fetchChapterContent(book.sourceBookID, chapterID: chapter.id)
            content = text
            shelf.updateProgress(
                sourceID: book.sourceID,
                sourceBookID: book.sourceBookID,
                chapterIndex: index,
                chapterTitle: chapter.title
            )
        } catch {
            errorText = "正文加载失败:\(error.localizedDescription)"
        }
        loading = false
    }
}
