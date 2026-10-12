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
    @State private var showListening = false
    @StateObject private var pageModel = PageReaderModel()
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var downloadedFiles: Set<String> = []
    @ObservedObject private var tts = TTSService.shared
    @State private var followRendered: NSRange?
    @State private var followScrollToken = 0
    @State private var following = true
    @State private var loadedIndex = -1

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

    /// 内容 + 排版 + 跟读高亮签名(变化时重建文本视图)
    private var textRevision: Int {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(typo)
        hasher.combine(followRendered?.location ?? -1)
        hasher.combine(followRendered?.length ?? -1)
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
        .sheet(isPresented: $showListening) {
            ListeningView(
                book: book,
                chapters: chapters,
                startChapter: index,
                startOffset: typo.readerMode == "scroll" ? nil : pageModel.currentOffset
            )
        }
        .task(id: "\(index)-\(typo.readerMode)") { await loadContent() }
        .onAppear {
            _ = shelf.add(book, sourceName: sourceName)
            TTSService.shared.onProgress = { chapter, offset in
                guard chapter >= 0, chapter < chapters.count else { return }
                shelf.updateProgress(
                    sourceID: book.sourceID,
                    sourceBookID: book.sourceBookID,
                    chapterIndex: chapter,
                    chapterTitle: chapters[chapter].title,
                    offset: offset
                )
            }
            syncFollow()
        }
        .onChange(of: tts.nowReading) { _, _ in
            syncFollow()
        }
        .onChange(of: index) { _, _ in
            syncFollow()
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
                        attributed: ReaderTextRenderer.attributedString(
                            content, typo: typo, font: resolvedFont, highlight: followRendered
                        ),
                        revision: textRevision,
                        onTap: { toggleControls() },
                        scrollTarget: followRendered,
                        scrollToken: followScrollToken
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
                if let nr = ttsHighlight, nr.chapterIndex != newChapter {
                    following = false
                }
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
                barButton(ttsHighlight == nil ? "听书" : "听书中", "headphones") { showListening = true }
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
            ScrollViewReader { proxy in
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
                                if downloadedFiles.contains(OfflineStore.chapterFileName(ch.id)) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if ch.index - 1 == index {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .id(ch.id)
                    }
                }
                .listStyle(.plain)
                .task(id: catalogDownloadState) {
                    downloadedFiles = OfflineStore.downloadedFileNames(offlineKey)
                }
                .onAppear {
                    scrollCatalogToCurrent(proxy)
                }
            }
            .navigationTitle("目录(\(chapters.count) 章)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    catalogDownloadButton
                }
            }
        }
    }

    // MARK: - 离线下载

    private var offlineKey: String {
        OfflineStore.bookKey(sourceID: book.sourceID, sourceBookID: book.sourceBookID)
    }

    private var catalogDownloadState: Int {
        downloads.record(for: offlineKey)?.doneCount ?? -1
    }

    @ViewBuilder
    private var catalogDownloadButton: some View {
        if book.sourceID == ZLibrarySource.identifier {
            EmptyView()
        } else if let rec = downloads.record(for: offlineKey) {
            switch rec.status {
            case .downloading, .queued:
                Button("下载中 \(Int(rec.progress * 100))%") {
                    downloads.pause(id: offlineKey)
                }
            case .paused:
                Button(rec.doneCount >= rec.totalChapters ? "已下载" : "继续下载") {
                    downloads.resume(id: offlineKey)
                }
                .disabled(rec.doneCount >= rec.totalChapters)
            case .completed:
                Text("已下载")
                    .foregroundColor(.secondary)
            }
        } else {
            Button("下载全本") {
                downloads.enqueue(book: book, sourceName: sourceName, chapters: chapters)
            }
        }
    }

    /// 打开目录时自动定位到当前章节(列表懒加载,稍等渲染后滚动)
    private func scrollCatalogToCurrent(_ proxy: ScrollViewProxy) {
        guard index >= 0, index < chapters.count else { return }
        let target = chapters[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(target, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            proxy.scrollTo(target, anchor: .center)
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
        // 手动翻章:回到朗读章则恢复跟随,翻去别处则暂停跟随
        if let nr = ttsHighlight {
            following = (nr.chapterIndex == clamped)
        }
    }

    // MARK: - 听读同步(高亮 + 自动跟页)

    /// 当前朗读会话是否属于本书
    private var ttsHighlight: TTSService.NowReading? {
        guard let nr = tts.nowReading, nr.bookKey == offlineKey else { return nil }
        return nr
    }

    /// 把阅读位置同步到朗读进度(高亮当前句;跟随中则自动翻章/翻页)
    private func syncFollow() {
        guard let nr = ttsHighlight else {
            followRendered = nil
            if typo.readerMode != "scroll" {
                pageModel.setFollowHighlight(chapter: index, range: nil)
            }
            return
        }
        let range = NSRange(location: max(0, nr.offset), length: max(1, nr.length))
        if nr.chapterIndex == index {
            following = true
            if typo.readerMode == "scroll" {
                guard loadedIndex == index, !content.isEmpty else { return }
                if followRendered != range {
                    followRendered = range
                    followScrollToken += 1
                }
            } else {
                pageModel.setFollowHighlight(chapter: nr.chapterIndex, range: range)
            }
        } else if following {
            // 自动翻到朗读章(滚动模式等内容加载完成后由 loadContent 再同步)
            if typo.readerMode != "scroll" {
                pageModel.setFollowHighlight(chapter: nr.chapterIndex, range: range)
            }
            index = max(0, min(nr.chapterIndex, chapters.count - 1))
            if typo.readerMode != "scroll" {
                pageModel.jumpTo(chapter: index, offset: nr.offset)
            }
        } else {
            // 用户翻去别处阅读:不打扰,清掉高亮
            followRendered = nil
            if typo.readerMode != "scroll" {
                pageModel.setFollowHighlight(chapter: index, range: nil)
            }
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
            loadedIndex = index
            saveProgress(chapter)
            prefetchNext()
            syncFollow()
            return
        }
        loading = true
        errorText = nil
        content = ""
        do {
            let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
            content = text
            loadedIndex = index
            saveProgress(chapter)
            prefetchNext()
            syncFollow()
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
