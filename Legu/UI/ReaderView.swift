import SwiftUI

/// 阅读器:全屏沉浸式,点正文呼出控制层;
/// 正文由 TextKit 渲染(精确行距/段距/首行缩进/字距),排版面板内嵌
struct ReaderView: View {
    let book: SourceBook
    let sourceName: String
    let chapters: [SourceChapter]
    let initialIndex: Int
    let initialOffset: Int?

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
    @StateObject private var pageModel = PageReaderModel()

    init(book: SourceBook, sourceName: String, chapters: [SourceChapter], initialIndex: Int, initialOffset: Int? = nil) {
        self.book = book
        self.sourceName = sourceName
        self.chapters = chapters
        self.initialIndex = initialIndex
        self.initialOffset = initialOffset
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

            if typo.readerMode == "scroll" {
                scrollBody
            } else {
                pageBody
            }

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
        .task(id: "\(index)-\(typo.readerMode)") { await loadContent() }
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

    // MARK: - 翻页模式

    private var pageBody: some View {
        GeometryReader { geo in
            let textSize = CGSize(
                width: max(120, geo.size.width - typo.horizontalPadding * 2),
                height: max(120, geo.size.height - typo.verticalPadding * 2 - ReaderPageView.footerHeight - 2)
            )
            ZStack {
                ReaderPageView(
                    model: pageModel,
                    transitionStyle: typo.readerMode == "curl" ? .pageCurl : .scroll,
                    palette: palette,
                    onCenterTap: { toggleControls() },
                    onBoundaryPrev: {
                        if index > 0 { goToChapter(index - 1) }
                    },
                    onBoundaryNext: {
                        if index < chapters.count - 1 { goToChapter(index + 1) }
                    }
                )
                .id(typo.readerMode)

                pageStatusOverlay
            }
            .padding(.horizontal, typo.horizontalPadding)
            .padding(.vertical, typo.verticalPadding)
            .task(id: "\(book.id)|\(chapters.count)|\(typo.hashValue)|\(Int(textSize.width))x\(Int(textSize.height))") {
                pageModel.configure(
                    book: book,
                    chapters: chapters,
                    sourceStore: sourceStore,
                    typo: typo,
                    textSize: textSize,
                    startChapter: index,
                    startOffset: initialOffset ?? 0
                )
            }
        }
        .onAppear {
            pageModel.onChapterChanged = { newChapter in
                if newChapter != index {
                    index = newChapter
                }
            }
            pageModel.onProgress = { chapter, offset in
                guard chapter >= 0, chapter < chapters.count else { return }
                shelf.updateProgress(
                    sourceID: book.sourceID,
                    sourceBookID: book.sourceBookID,
                    chapterIndex: chapter,
                    chapterTitle: chapters[chapter].title,
                    offset: offset
                )
            }
        }
    }

    @ViewBuilder
    private var pageStatusOverlay: some View {
        switch pageModel.status {
        case .loading where pageModel.pages.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(Color(hex: palette.secondary))
                    .multilineTextAlignment(.center)
                Button("重试") {
                    pageModel.retry()
                }
                .buttonStyle(.borderedProminent)
                Text("也可以切换到上下滚动模式阅读")
                    .font(.caption2)
                    .foregroundColor(Color(hex: palette.secondary))
            }
            .padding(24)
        default:
            EmptyView()
        }
    }

    private var nextChapterButton: some View {
        Button {
            goToChapter(index + 1)
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
                barButton("上一章", "chevron.left") { goToChapter(index - 1) }
                    .disabled(index <= 0)
                barButton("目录", "list.bullet") { showCatalog = true }
                barButton("排版", "textformat.size") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showTypoPanel.toggle()
                    }
                }
                barButton("下一章", "chevron.right") { goToChapter(index + 1) }
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
                        goToChapter(ch.index - 1)
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

    private func goToChapter(_ newIndex: Int) {
        let clamped = max(0, min(newIndex, chapters.count - 1))
        index = clamped
        if typo.readerMode != "scroll" {
            pageModel.jumpTo(chapter: clamped, offset: 0)
        }
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
        guard typo.readerMode == "scroll" else { return }
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
        do {
            let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
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
        Task {
            _ = try? await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
        }
    }
}
