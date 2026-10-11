import SwiftUI

/// 阅读器:全屏沉浸式,点正文呼出控制层;
/// 正文由 TextKit 渲染(精确行距/段距/首行缩进/字距),排版面板内嵌
struct ReaderView: View {
    let book: SourceBook
    let sourceName: String
    let chapters: [SourceChapter]
    let initialIndex: Int

    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var sourceStore: SourceStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var content = ""
    @State private var loading = false
    @State private var errorText: String?
    @State private var showCatalog = false
    @State private var showControls = true
    @State private var showTypoPanel = false

    init(book: SourceBook, sourceName: String, chapters: [SourceChapter], initialIndex: Int) {
        self.book = book
        self.sourceName = sourceName
        self.chapters = chapters
        self.initialIndex = initialIndex
        let clamped = max(0, min(initialIndex, max(0, chapters.count - 1)))
        _index = State(initialValue: clamped)
    }

    private var typo: ReaderTypography { settings.typography }
    private var palette: ReaderTypography.Palette { typo.palette }
    private var resolvedFont: ResolvedFont {
        FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
    }

    private var currentChapter: SourceChapter? {
        (index >= 0 && index < chapters.count) ? chapters[index] : nil
    }

    /// 内容 + 排版签名(变化时重建文本视图)
    private var textRevision: Int {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(typo)
        return hasher.finalize()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: palette.background).ignoresSafeArea()

            scrollBody

            VStack(spacing: 0) {
                if showControls {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if showControls {
                    bottomPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls && typo.hideStatusBar)
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .task(id: index) { await loadContent() }
        .onAppear {
            _ = shelf.add(book, sourceName: sourceName)
        }
    }

    // MARK: - 正文

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let ch = currentChapter {
                    Text(ch.title)
                        .font(swiftUIFont(size: typo.fontSize * 0.85))
                        .foregroundColor(Color(hex: palette.secondary))
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
                            .foregroundColor(Color(hex: palette.secondary))
                        Button("重试") {
                            Task { await loadContent() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 40)
                } else {
                    ReaderTextView(
                        attributed: ReaderTextRenderer.attributedString(content, typo: typo, font: resolvedFont),
                        revision: textRevision,
                        onTap: { toggleControls() }
                    )
                    nextChapterButton
                        .padding(.top, 30)
                }
            }
            .padding(.horizontal, typo.horizontalPadding)
            .padding(.top, typo.verticalPadding)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(index)
    }

    private func swiftUIFont(size: CGFloat) -> Font {
        if let name = resolvedFont.postScriptName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: typo.bold ? .semibold : .regular)
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

    // MARK: - 控制层

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(book.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text("\(index + 1)/\(chapters.count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.65)
            }
            Spacer()
            Button {
                showCatalog = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body)
                    .frame(width: 36, height: 36)
            }
        }
        .foregroundColor(Color(hex: palette.foreground))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if showTypoPanel {
                ReaderTypographyPanel()
            }
            Divider()
            HStack {
                barButton("上一章", "chevron.left") { prevChapter() }
                    .disabled(index <= 0)
                barButton("目录", "list.bullet") { showCatalog = true }
                barButton("排版", "textformat.size") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showTypoPanel.toggle()
                    }
                }
                barButton("下一章", "chevron.right") { nextChapter() }
                    .disabled(index >= chapters.count - 1)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func barButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(Color(hex: palette.foreground))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 目录

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

    // MARK: - 行为

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.16)) {
            showControls.toggle()
            if !showControls {
                showTypoPanel = false
            }
        }
    }

    private func prevChapter() {
        if index > 0 { index -= 1 }
    }

    private func nextChapter() {
        if index < chapters.count - 1 { index += 1 }
    }

    private func saveProgress(_ chapter: SourceChapter) {
        shelf.updateProgress(
            sourceID: book.sourceID,
            sourceBookID: book.sourceBookID,
            chapterIndex: index,
            chapterTitle: chapter.title
        )
    }

    private func loadContent() async {
        guard index >= 0, index < chapters.count else { return }
        let chapter = chapters[index]
        let cacheKey = BookCache.chapterKey(
            sourceID: book.sourceID,
            bookID: book.sourceBookID,
            chapterID: chapter.id
        )
        if let cached = BookCache.shared.chapter(for: cacheKey) {
            content = cached
            errorText = nil
            loading = false
            saveProgress(chapter)
            prefetchNext()
            return
        }
        loading = true
        errorText = nil
        content = ""
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else {
            errorText = "找不到书源(可能已被删除)"
            loading = false
            return
        }
        do {
            let text = try await HTTP.retrying {
                try await source.fetchChapterContent(book.sourceBookID, chapterID: chapter.id)
            }
            BookCache.shared.setChapter(text, for: cacheKey)
            content = text
            saveProgress(chapter)
            prefetchNext()
        } catch {
            errorText = "正文加载失败:\(error.localizedDescription)"
        }
        loading = false
    }

    private func prefetchNext() {
        let next = index + 1
        guard next < chapters.count else { return }
        let chapter = chapters[next]
        let key = BookCache.chapterKey(
            sourceID: book.sourceID,
            bookID: book.sourceBookID,
            chapterID: chapter.id
        )
        guard !BookCache.shared.hasChapter(key) else { return }
        guard let source = sourceStore.source(forBookSourceID: book.sourceID) else { return }
        let bookID = book.sourceBookID
        Task {
            if let text = try? await source.fetchChapterContent(bookID, chapterID: chapter.id) {
                BookCache.shared.setChapter(text, for: key)
            }
        }
    }
}
