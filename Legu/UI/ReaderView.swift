import SwiftUI
import UIKit

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
    @State private var window: [ReaderWindowChapter] = []
    @State private var windowLoading = false
    @State private var windowError: String?
    @State private var navToken = 0
    @State private var scrollBox = ReaderScrollBox()
    @State private var renderCache = ReaderRenderCache()
    @State private var hasScrolledDown = false
    @State private var didRestorePosition = false
    @State private var lastRestoreApplied: CGFloat = -1
    @State private var lastSavedChapter = -1
    @State private var lastSavedOffset = -1
    @State private var lastSaveTime = Date.distantPast
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

    /// 渲染签名(章节内容哈希 + 排版 + 该章高亮;变化时才重建 attributed)
    private static func renderKey(baseHash: Int, typo: ReaderTypography, highlight: NSRange?) -> Int {
        var hasher = Hasher()
        hasher.combine(baseHash)
        hasher.combine(typo)
        hasher.combine(highlight?.location ?? -1)
        hasher.combine(highlight?.length ?? -1)
        return hasher.finalize()
    }

    /// 显示用文本:基准排版(缓存)+ 按需增量叠加跟读高亮(缓存)
    private func displayText(for wc: ReaderWindowChapter) -> (key: Int, attributed: NSAttributedString) {
        let highlight = wc.index == index ? followRendered : nil
        let baseKey = Self.renderKey(baseHash: wc.baseHash, typo: typo, highlight: nil)
        let base = renderCache.attributed(index: wc.index, key: baseKey) {
            ReaderTextRenderer.attributedString(wc.text, typo: typo, font: resolvedFont)
        }
        guard let highlight else { return (baseKey, base) }
        let hlKey = Self.renderKey(baseHash: wc.baseHash, typo: typo, highlight: highlight)
        let display = renderCache.attributed(index: wc.index, key: hlKey) {
            ReaderTextRenderer.applyingHighlight(to: base, highlight: highlight, palette: typo.palette)
        }
        return (hlKey, display)
    }

    /// 后台构建(幂等):章节文本 → attributed + 高度 + 行表;已备好的直接复用
    private func prepareChapter(index chapterIndex: Int, text: String) async -> (baseHash: Int, height: CGFloat) {
        var hasher = Hasher()
        hasher.combine(text)
        let baseHash = hasher.finalize()
        let typo = self.typo
        let key = Self.renderKey(baseHash: baseHash, typo: typo, highlight: nil)
        if let cached = renderCache.preparedInfo(index: chapterIndex, key: key) {
            return (baseHash, cached.sectionHeight)
        }
        let font = resolvedFont
        let width = max(120, (scrollBox.scrollView?.bounds.width ?? UIScreen.main.bounds.width) - typo.horizontalPadding * 2)
        let result = await Task.detached(priority: .userInitiated) {
            let attributed = ReaderTextRenderer.attributedString(text, typo: typo, font: font)
            let layout = ReaderTextRenderer.measureLayout(attributed, width: width)
            return (attributed, layout.height, layout.lines)
        }.value
        guard !Task.isCancelled else { return (baseHash, 0) }
        renderCache.prime(index: chapterIndex, key: key, attributed: result.0)
        let sectionHeight = result.1 + ceil(typo.fontSize * 0.85 * 1.3) + 18 + 24
        renderCache.storePrepared(index: chapterIndex, ReaderRenderCache.Prepared(
            key: key,
            sectionHeight: sectionHeight,
            lines: result.2
        ))
        return (baseHash, sectionHeight)
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
        .task(id: "\(navToken)-\(typo.readerMode)") { await loadContent() }
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
            scrollBox.onOffsetChange = { y, sv in
                handleOffsetChange(y, sv)
            }
            syncFollow()
        }
        .onChange(of: tts.nowReading) { _, _ in
            syncFollow()
        }
        .onChange(of: index) { _, _ in
            syncFollow()
        }
        .onDisappear {
            savePositionNow()
        }
    }

    // MARK: - 正文

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ReaderScrollBridge { sv in
                    scrollBox.attach(sv)
                }
                .frame(height: 0)

                if window.isEmpty {
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
                    }
                } else {
                    ForEach(window) { wc in
                        let display = displayText(for: wc)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(wc.title)
                                .font(swiftUIFont(size: typo.fontSize * 0.85))
                                .foregroundColor(Color(hex: palette.secondary))
                                .padding(.bottom, 18)
                            ReaderTextView(
                                attributed: display.attributed,
                                revision: display.key,
                                onTap: { toggleControls() },
                                scrollTarget: wc.index == index ? followRendered : nil,
                                scrollToken: followScrollToken
                            )
                        }
                        .padding(.top, 24)
                    }

                    if windowLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.top, 16)
                    }

                    if let windowError {
                        HStack(spacing: 10) {
                            Text(windowError)
                                .font(.caption)
                                .foregroundColor(Color(hex: palette.secondary))
                            Button("重试") {
                                loadNextIntoWindow()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                        .padding(.top, 20)
                    }
                }
            }
            .padding(.horizontal, typo.horizontalPadding)
            .padding(.top, typo.verticalPadding)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        navToken += 1
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
                guard window.contains(where: { $0.index == nr.chapterIndex }) else { return }
                if followRendered != range {
                    followRendered = range
                    followScrollToken += 1
                }
            } else {
                pageModel.setFollowHighlight(chapter: nr.chapterIndex, range: range)
            }
        } else if following {
            // 自动翻到朗读章(滚动模式重置窗口;翻页模式直接跳)
            if typo.readerMode != "scroll" {
                pageModel.setFollowHighlight(chapter: nr.chapterIndex, range: range)
            }
            index = max(0, min(nr.chapterIndex, chapters.count - 1))
            if typo.readerMode != "scroll" {
                pageModel.jumpTo(chapter: index, offset: nr.offset)
            } else {
                navToken += 1
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
        loading = true
        errorText = nil
        windowError = nil
        do {
            let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
            guard !Task.isCancelled else { return }
            renderCache.clear()
            let prepared = await prepareChapter(index: index, text: text)
            guard !Task.isCancelled else { return }
            window = [ReaderWindowChapter(index: index, title: chapter.title, text: text, baseHash: prepared.baseHash, height: prepared.height)]
            hasScrolledDown = false
            loading = false
            saveProgress(chapter)
            prefetchNext()
            if index == initialIndex, (initialOffset ?? 0) > 0, !didRestorePosition {
                restoreReadingPositionIfNeeded()
            } else {
                scrollToTop()
            }
            syncFollow()
            // 短章自动续接:内容不足一屏时继续加载下一章
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                checkWindowLoad()
            }
        } catch {
            errorText = "正文加载失败:\(error.localizedDescription)"
            loading = false
        }
    }

    // MARK: - 连续滚动(章节窗口)

    /// 向下续接一章
    private func loadNextIntoWindow() {
        guard typo.readerMode == "scroll", !windowLoading else { return }
        let next = (window.last?.index ?? index) + 1
        guard next < chapters.count, !window.contains(where: { $0.index == next }) else { return }
        windowLoading = true
        Task {
            defer { windowLoading = false }
            let chapter = chapters[next]
            do {
                let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
                guard typo.readerMode == "scroll", !Task.isCancelled else { return }
                guard !window.contains(where: { $0.index == next }) else { return }
                let prepared = await prepareChapter(index: next, text: text)
                guard typo.readerMode == "scroll", !Task.isCancelled else { return }
                guard !window.contains(where: { $0.index == next }) else { return }
                window.append(ReaderWindowChapter(index: next, title: chapter.title, text: text, baseHash: prepared.baseHash, height: prepared.height))
                windowError = nil
                trimWindow(keepAround: index)
                prefetch(from: next, count: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    checkWindowLoad()
                }
            } catch {
                windowError = "下一章加载失败,点「重试」继续"
            }
        }
    }

    /// 向上衔接一章(保持视觉位置:补偿插入高度)
    private func loadPrevIntoWindow() {
        guard typo.readerMode == "scroll", !windowLoading else { return }
        let prev = (window.first?.index ?? index) - 1
        guard prev >= 0, !window.contains(where: { $0.index == prev }) else { return }
        windowLoading = true
        Task {
            defer { windowLoading = false }
            let chapter = chapters[prev]
            do {
                let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
                guard typo.readerMode == "scroll", !Task.isCancelled else { return }
                guard !window.contains(where: { $0.index == prev }) else { return }
                let prepared = await prepareChapter(index: prev, text: text)
                guard typo.readerMode == "scroll", !Task.isCancelled else { return }
                guard !window.contains(where: { $0.index == prev }) else { return }
                let sv = scrollBox.scrollView
                window.insert(ReaderWindowChapter(index: prev, title: chapter.title, text: text, baseHash: prepared.baseHash, height: prepared.height), at: 0)
                trimWindow(keepAround: index)
                if let sv {
                    // 在调整时刻用当前偏移 + 插入高度(用户若在期间滚动也能保持视觉位置)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        sv.setContentOffset(CGPoint(x: 0, y: max(0, sv.contentOffset.y + prepared.height)), animated: false)
                    }
                }
            } catch {
                // 上一章加载失败:静默,继续滚顶可重试
            }
        }
    }

    /// 根据滚动状态判断是否需要续接 / 衔接
    private func checkWindowLoad() {
        guard typo.readerMode == "scroll", !window.isEmpty, !loading else { return }
        guard let sv = scrollBox.scrollView else { return }
        let y = sv.contentOffset.y
        let visibleBottom = y + sv.bounds.height
        let contentBottom = sv.contentSize.height - sv.adjustedContentInset.bottom
        if sv.contentSize.height <= sv.bounds.height + 1 || visibleBottom > contentBottom - 700 {
            loadNextIntoWindow()
        }
        if hasScrolledDown, y < 80, (window.first?.index ?? 0) > 0 {
            loadPrevIntoWindow()
        }
    }

    /// 滚动事件:更新当前章(进度 / 跟随语义)+ 保存进度 + 触发续接
    private func handleOffsetChange(_ y: CGFloat, _ sv: UIScrollView) {
        guard typo.readerMode == "scroll", !window.isEmpty else { return }
        if y > 300 { hasScrolledDown = true }
        let chapterChanged = updateCurrentChapter(y, sv)
        saveReadingPositionIfNeeded(y: y, sv: sv, chapterChangedHint: chapterChanged)
        checkWindowLoad()
    }

    @discardableResult
    private func updateCurrentChapter(_ y: CGFloat, _ sv: UIScrollView) -> Bool {
        guard !window.isEmpty else { return false }
        let probe = y + sv.adjustedContentInset.top + 120
        var acc: CGFloat = typo.verticalPadding
        var found = window.first?.index ?? index
        for wc in window {
            let next = acc + wc.height
            if probe < next {
                found = wc.index
                break
            }
            acc = next
            found = wc.index
        }
        guard found != index else { return false }
        index = found
        // 手动滚离朗读章 → 暂停跟随;滚回朗读章由 syncFollow 自动恢复
        if let nr = ttsHighlight, nr.chapterIndex != found {
            following = false
        }
        if found >= 0, found < chapters.count {
            saveProgress(chapters[found])
        }
        return true
    }

    // MARK: - 阅读进度(章内位置保存 / 恢复)

    /// 当前阅读位置(章索引 + 章内字符偏移;基于行表,精确到行)
    private func readingPosition(y: CGFloat, sv: UIScrollView) -> (chapter: Int, offset: Int)? {
        let probe = y + sv.adjustedContentInset.top + 120
        var acc: CGFloat = typo.verticalPadding
        let titleBlock = 24 + ceil(typo.fontSize * 0.85 * 1.3) + 18
        for wc in window {
            let next = acc + wc.height
            if probe < next {
                let yInText = probe - acc - titleBlock
                let key = Self.renderKey(baseHash: wc.baseHash, typo: typo, highlight: nil)
                guard let info = renderCache.preparedInfo(index: wc.index, key: key), !info.lines.isEmpty else {
                    return nil
                }
                var offset = 0
                for line in info.lines {
                    if line.top <= yInText {
                        offset = line.offset
                    } else {
                        break
                    }
                }
                return (wc.index, offset)
            }
            acc = next
        }
        return nil
    }

    /// 保存进度:换章立即存;同章每 2 秒且移动超过 120 字存一次(节流防频繁计算 / 写盘)
    private func saveReadingPositionIfNeeded(y: CGFloat, sv: UIScrollView, chapterChangedHint: Bool, force: Bool = false) {
        let now = Date()
        if !force, !chapterChangedHint, now.timeIntervalSince(lastSaveTime) < 2 { return }
        guard let pos = readingPosition(y: y, sv: sv) else { return }
        guard pos.chapter >= 0, pos.chapter < chapters.count else { return }
        let chapterChanged = chapterChangedHint || pos.chapter != lastSavedChapter
        let moved = abs(pos.offset - lastSavedOffset) >= 120
        guard force || chapterChanged || moved else { return }
        lastSavedChapter = pos.chapter
        lastSavedOffset = pos.offset
        lastSaveTime = now
        shelf.updateProgress(
            sourceID: book.sourceID,
            sourceBookID: book.sourceBookID,
            chapterIndex: pos.chapter,
            chapterTitle: chapters[pos.chapter].title,
            offset: pos.offset
        )
    }

    /// 退出阅读器时立即保存当前位置
    private func savePositionNow() {
        guard typo.readerMode == "scroll", !window.isEmpty, let sv = scrollBox.scrollView else { return }
        saveReadingPositionIfNeeded(y: sv.contentOffset.y, sv: sv, chapterChangedHint: false, force: true)
    }

    /// 首次打开且书架有章内偏移时,恢复到上次位置
    private func restoreReadingPositionIfNeeded() {
        guard !didRestorePosition else { return }
        guard let target = initialOffset, target > 0, index == initialIndex else { return }
        didRestorePosition = true
        guard let wc = window.first(where: { $0.index == index }) else { return }
        let key = Self.renderKey(baseHash: wc.baseHash, typo: typo, highlight: nil)
        guard let info = renderCache.preparedInfo(index: wc.index, key: key), !info.lines.isEmpty else { return }
        var lineTop: CGFloat = 0
        for line in info.lines {
            if line.offset <= target {
                lineTop = line.top
            } else {
                break
            }
        }
        let titleBlock = 24 + ceil(typo.fontSize * 0.85 * 1.3) + 18
        let targetY = max(0, typo.verticalPadding + titleBlock + lineTop - 36)
        // 布局展开前 contentSize 不足会钳制偏移:稍后开始,多次校正直到到位(用户中途自己滚动则放弃)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            restoreScrollOffset(targetY, attempt: 0)
        }
    }

    /// 把滚动偏移设置到目标位置;内容尚未布局完时重试(防止被钳制在章首)
    private func restoreScrollOffset(_ targetY: CGFloat, attempt: Int) {
        guard let sv = scrollBox.scrollView else { return }
        if attempt > 0, lastRestoreApplied >= 0, abs(sv.contentOffset.y - lastRestoreApplied) > 80 {
            return // 用户已自行滚动,放弃校正
        }
        let maxY = max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let clamped = min(targetY, maxY)
        sv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
        lastRestoreApplied = clamped
        if clamped < targetY - 1, attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                restoreScrollOffset(targetY, attempt: attempt + 1)
            }
        }
    }

    /// 窗口裁剪:超过上限时丢弃离当前章更远的一侧(丢顶部时补偿滚动位移)
    private func trimWindow(keepAround center: Int) {
        let maxCount = 12
        while window.count > maxCount {
            let firstIdx = window.first?.index ?? center
            let lastIdx = window.last?.index ?? center
            if center - firstIdx >= lastIdx - center {
                let removed = window.removeFirst()
                if let sv = scrollBox.scrollView {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        sv.setContentOffset(CGPoint(x: 0, y: max(0, sv.contentOffset.y - removed.height)), animated: false)
                    }
                }
            } else {
                _ = window.removeLast()
            }
        }
        renderCache.trim(to: Set(window.map { $0.index }))
    }

    private func scrollToTop() {
        guard let sv = scrollBox.scrollView else { return }
        DispatchQueue.main.async {
            sv.setContentOffset(CGPoint(x: 0, y: -sv.adjustedContentInset.top), animated: false)
        }
    }

    private func prefetchNext() {
        prefetch(from: index, count: 2)
    }

    /// 预取后续章节正文(连续滚动衔接更顺滑;在线书也提前拉好)
    private func prefetch(from start: Int, count: Int) {
        for delta in 1...max(1, count) {
            let next = start + delta
            guard next < chapters.count else { continue }
            let chapter = chapters[next]
            let key = BookCache.chapterKey(
                sourceID: book.sourceID,
                bookID: book.sourceBookID,
                chapterID: chapter.id
            )
            guard !BookCache.shared.hasChapter(key) else { continue }
            Task {
                if let text = try? await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter) {
                    // 预热:排版 + 高度 + 行表提前备好,衔接时零等待
                    _ = await prepareChapter(index: next, text: text)
                }
            }
        }
    }
}

// MARK: - 连续滚动支持

/// 滚动窗口中的一章
struct ReaderWindowChapter: Identifiable {
    let index: Int
    let title: String
    let text: String
    /// 正文哈希(渲染缓存键的一部分)
    let baseHash: Int
    /// 实测整段高度(标题 + 间距 + 正文)
    let height: CGFloat

    var id: Int { index }
}

/// 滚动桥:拿到外层 UIScrollView 并观察 contentOffset
final class ReaderScrollBox: NSObject {
    weak var scrollView: UIScrollView?
    var onOffsetChange: (@MainActor (CGFloat, UIScrollView) -> Void)?
    private var observation: NSKeyValueObservation?

    func attach(_ sv: UIScrollView) {
        guard scrollView !== sv else { return }
        scrollView = sv
        observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            guard let handler = self?.onOffsetChange else { return }
            let y = scroll.contentOffset.y
            // KVO 只在主线程回调;内联执行,避免每帧一个 Task 的开销(耗电优化)
            MainActor.assumeIsolated {
                handler(y, scroll)
            }
        }
    }
}

/// 零高辅助视图:向上找外层 UIScrollView 并交给滚动桥
private struct ReaderScrollBridge: UIViewRepresentable {
    let onReady: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            var current = view.superview
            while let v = current {
                if let sv = v as? UIScrollView {
                    onReady(sv)
                    break
                }
                current = v.superview
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 章节渲染缓存:按签名复用 attributed,避免每次界面刷新都重建全文(耗电 / 卡顿优化)
@MainActor
final class ReaderRenderCache {
    struct Prepared {
        let key: Int
        let sectionHeight: CGFloat
        /// 行表:行顶 Y(相对正文顶部)与起始字符偏移
        let lines: [(top: CGFloat, offset: Int)]
    }

    private var store: [Int: (key: Int, attributed: NSAttributedString)] = [:]
    private var prepared: [Int: Prepared] = [:]

    func prime(index: Int, key: Int, attributed: NSAttributedString) {
        store[index] = (key, attributed)
    }

    func storePrepared(index: Int, _ value: Prepared) {
        prepared[index] = value
    }

    func preparedInfo(index: Int, key: Int) -> Prepared? {
        guard let p = prepared[index], p.key == key else { return nil }
        return p
    }

    func attributed(index: Int, key: Int, build: () -> NSAttributedString) -> NSAttributedString {
        if let hit = store[index], hit.key == key {
            return hit.attributed
        }
        let value = build()
        store[index] = (key, value)
        return value
    }

    func trim(to indices: Set<Int>) {
        store = store.filter { indices.contains($0.key) }
        prepared = prepared.filter { indices.contains($0.key) }
    }

    func clear() {
        store.removeAll()
        prepared.removeAll()
    }
}
