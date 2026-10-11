import SwiftUI
import UIKit

/// 点击区域
enum PageTapZone {
    case left, center, right
}

/// 单页数据
struct PageItem {
    let chapterIndex: Int
    let pageIndex: Int
    let pageCount: Int
    let chapterTitle: String
    let range: NSRange
    let attributed: NSAttributedString
}

/// 分页阅读模型:分页、缓存、跨章窗口、进度
@MainActor
final class PageReaderModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var pages: [PageItem] = []
    @Published private(set) var anchorIndex: Int = 0
    @Published private(set) var revision: Int = 0
    @Published private(set) var status: Status = .idle
    @Published private(set) var currentChapter: Int = 0
    @Published private(set) var currentOffset: Int = 0

    /// 跨章回调(供阅读器同步顶部栏/进度)
    var onChapterChanged: ((Int) -> Void)?
    var onProgress: ((Int, Int) -> Void)?

    private var book: SourceBook?
    private var chapters: [SourceChapter] = []
    private weak var sourceStore: SourceStore?
    private var typo = ReaderTypography()
    private var textSize: CGSize = .zero

    private var baseChapter = 0
    private var chapterItems: [PageItem] = []
    private var prefetchedChapter: Int?
    private var nextItems: [PageItem] = []
    private var paginationTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var paginationToken: CancellationToken?
    private var prefetchToken: CancellationToken?

    // MARK: - 配置

    func configure(
        book: SourceBook,
        chapters: [SourceChapter],
        sourceStore: SourceStore,
        typo: ReaderTypography,
        textSize: CGSize,
        startChapter: Int,
        startOffset: Int
    ) {
        let sameBook = self.book?.id == book.id
        self.book = book
        self.chapters = chapters
        self.sourceStore = sourceStore
        self.typo = typo
        self.textSize = textSize

        if !sameBook {
            baseChapter = clampChapter(startChapter)
            currentChapter = baseChapter
            currentOffset = max(0, startOffset)
            anchorIndex = 0
            repaginate(anchorOffset: currentOffset)
        } else {
            // 排版/尺寸变化:按当前偏移重新分页并锚定
            repaginate(anchorOffset: currentOffset)
        }
    }

    func jumpTo(chapter: Int, offset: Int) {
        let clamped = clampChapter(chapter)
        baseChapter = clamped
        currentChapter = clamped
        repaginate(anchorOffset: max(0, offset))
    }

    func retry() {
        repaginate(anchorOffset: currentOffset)
    }

    /// 翻到某页后调用(手势/点击/程序切换)
    func pageDidSettle(index: Int) {
        guard index >= 0, index < pages.count else { return }
        let item = pages[index]
        currentChapter = item.chapterIndex
        currentOffset = item.range.location
        if item.chapterIndex != baseChapter {
            // 跨章:重基窗口(当前章 + 预取的下一章)
            baseChapter = item.chapterIndex
            chapterItems = pages.filter { $0.chapterIndex == baseChapter }
            let keepNext = pages.filter { $0.chapterIndex == baseChapter + 1 }
            nextItems = keepNext
            prefetchedChapter = keepNext.isEmpty ? nil : baseChapter + 1
            pages = chapterItems + keepNext
            anchorIndex = min(item.pageIndex, max(0, chapterItems.count - 1))
            revision += 1
            prefetchNext()
        } else {
            anchorIndex = index
        }
        onChapterChanged?(item.chapterIndex)
        onProgress?(item.chapterIndex, item.range.location)
    }

    // MARK: - 分页

    private func repaginate(anchorOffset: Int) {
        paginationTask?.cancel()
        paginationToken?.cancel()
        prefetchTask?.cancel()
        prefetchToken?.cancel()
        let token = CancellationToken()
        paginationToken = token

        guard let book, let sourceStore, baseChapter >= 0, baseChapter < chapters.count else {
            status = .failed("章节数据缺失")
            return
        }
        let chapter = chapters[baseChapter]
        let chapterIndex = baseChapter
        let typo = self.typo
        let size = self.textSize
        status = .loading

        paginationTask = Task { @MainActor [weak self] in
            // 防抖:连续拖动排版滑块时只执行最后一次
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled, !token.isCancelled else { return }
            do {
                let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
                guard !token.isCancelled, chapterIndex == self.baseChapter else { return }

                let key = PaginationCache.key(
                    sourceID: book.sourceID,
                    bookID: book.sourceBookID,
                    chapterID: chapter.id,
                    layoutKey: typo.layoutKey,
                    size: size
                )
                let ranges: [NSRange]
                if let cached = PaginationCache.shared.get(key) {
                    ranges = cached
                } else {
                    let attributed = ReaderTextRenderer.attributedString(
                        text, typo: typo,
                        font: FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
                    )
                    let computed = await Task.detached(priority: .userInitiated) {
                        Paginator.paginate(attributed, size: size, shouldCancel: { token.isCancelled })
                    }.value
                    guard !token.isCancelled else { return }
                    ranges = computed
                    if !ranges.isEmpty {
                        PaginationCache.shared.set(key, ranges)
                    }
                }
                guard !token.isCancelled, chapterIndex == self.baseChapter else { return }

                let attributed = ReaderTextRenderer.attributedString(
                    text, typo: typo,
                    font: FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
                )
                let items = Self.buildItems(
                    ranges: ranges, attributed: attributed,
                    chapterIndex: chapterIndex, title: chapter.title
                )
                self.chapterItems = items
                self.prefetchedChapter = nil
                self.nextItems = []
                self.pages = items
                self.anchorIndex = Paginator.pageIndex(forOffset: anchorOffset, in: ranges)
                self.currentChapter = chapterIndex
                self.currentOffset = items.isEmpty ? 0 : items[self.anchorIndex].range.location
                self.revision += 1
                self.status = .ready
                self.onProgress?(chapterIndex, self.currentOffset)
                self.prefetchNext()
            } catch {
                guard !token.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// 后台预取下一章分页(到达章尾时翻页无缝)
    private func prefetchNext() {
        prefetchTask?.cancel()
        prefetchToken?.cancel()
        let next = baseChapter + 1
        guard next < chapters.count, let book, let sourceStore else { return }
        if prefetchedChapter == next { return }
        let chapter = chapters[next]
        let typo = self.typo
        let size = self.textSize
        let token = CancellationToken()
        prefetchToken = token

        prefetchTask = Task { @MainActor [weak self] in
            do {
                let text = try await ChapterLoader.load(sourceStore: sourceStore, book: book, chapter: chapter)
                guard let self, !token.isCancelled, self.baseChapter + 1 == next else { return }
                let key = PaginationCache.key(
                    sourceID: book.sourceID,
                    bookID: book.sourceBookID,
                    chapterID: chapter.id,
                    layoutKey: typo.layoutKey,
                    size: size
                )
                let ranges: [NSRange]
                if let cached = PaginationCache.shared.get(key) {
                    ranges = cached
                } else {
                    let attributed = ReaderTextRenderer.attributedString(
                        text, typo: typo,
                        font: FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
                    )
                    let computed = await Task.detached(priority: .utility) {
                        Paginator.paginate(attributed, size: size, shouldCancel: { token.isCancelled })
                    }.value
                    guard !token.isCancelled else { return }
                    ranges = computed
                    if !ranges.isEmpty {
                        PaginationCache.shared.set(key, ranges)
                    }
                }
                guard !token.isCancelled, self.baseChapter + 1 == next else { return }
                let attributed = ReaderTextRenderer.attributedString(
                    text, typo: typo,
                    font: FontRegistry.shared.resolve(typo.fontID, bold: typo.bold)
                )
                let items = Self.buildItems(
                    ranges: ranges, attributed: attributed,
                    chapterIndex: next, title: chapter.title
                )
                self.prefetchedChapter = next
                self.nextItems = items
                self.pages = self.chapterItems + items
            } catch {
                // 预取失败静默,用户翻到时再走正常加载
            }
        }
    }

    private static func buildItems(
        ranges: [NSRange],
        attributed: NSAttributedString,
        chapterIndex: Int,
        title: String
    ) -> [PageItem] {
        let count = ranges.count
        return ranges.enumerated().map { index, range in
            PageItem(
                chapterIndex: chapterIndex,
                pageIndex: index,
                pageCount: count,
                chapterTitle: title,
                range: range,
                attributed: attributed.attributedSubstring(from: range)
            )
        }
    }

    private func clampChapter(_ index: Int) -> Int {
        guard !chapters.isEmpty else { return 0 }
        return max(0, min(index, chapters.count - 1))
    }
}

// MARK: - UIPageViewController 容器

struct ReaderPageView: UIViewControllerRepresentable {
    @ObservedObject var model: PageReaderModel
    let transitionStyle: UIPageViewController.TransitionStyle
    let palette: ReaderTypography.Palette
    let onCenterTap: () -> Void
    let onBoundaryPrev: () -> Void
    let onBoundaryNext: () -> Void

    /// 页脚高度(分页尺寸计算需保持一致)
    static let footerHeight: CGFloat = 24

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        context.coordinator.pageViewController = pvc
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.revision != model.revision {
            coordinator.revision = model.revision
            coordinator.reload(animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ReaderPageView
        weak var pageViewController: UIPageViewController?
        var revision: Int = -1

        init(parent: ReaderPageView) {
            self.parent = parent
        }

        // MARK: 页面构建

        func makeController(at index: Int) -> PageContentController? {
            let pages = parent.model.pages
            guard index >= 0, index < pages.count else { return nil }
            let controller = PageContentController(
                item: pages[index],
                palette: parent.palette,
                footerHeight: ReaderPageView.footerHeight
            )
            controller.onTapZone = { [weak self] tappedIndex, zone in
                self?.handleTap(index: tappedIndex, zone: zone)
            }
            return controller
        }

        func reload(animated: Bool) {
            guard let pvc = pageViewController else { return }
            let count = parent.model.pages.count
            guard count > 0 else {
                pvc.setViewControllers([], direction: .forward, animated: false)
                return
            }
            let index = max(0, min(parent.model.anchorIndex, count - 1))
            guard let controller = makeController(at: index) else { return }
            pvc.setViewControllers([controller], direction: .forward, animated: animated)
        }

        // MARK: 点击分区

        func handleTap(index: Int, zone: PageTapZone) {
            switch zone {
            case .center:
                parent.onCenterTap()
            case .left:
                if index > 0, let pvc = pageViewController, let controller = makeController(at: index - 1) {
                    pvc.setViewControllers([controller], direction: .reverse, animated: true)
                    parent.model.pageDidSettle(index: index - 1)
                } else if index == 0 {
                    parent.onBoundaryPrev()
                }
            case .right:
                let count = parent.model.pages.count
                if index < count - 1, let pvc = pageViewController, let controller = makeController(at: index + 1) {
                    pvc.setViewControllers([controller], direction: .forward, animated: true)
                    parent.model.pageDidSettle(index: index + 1)
                } else if index >= count - 1 {
                    parent.onBoundaryNext()
                }
            }
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? PageContentController, current.pageIndex > 0 else {
                return nil
            }
            return makeController(at: current.pageIndex - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? PageContentController,
                  current.pageIndex < parent.model.pages.count - 1 else {
                return nil
            }
            return makeController(at: current.pageIndex + 1)
        }

        // MARK: UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let current = pageViewController.viewControllers?.first as? PageContentController else {
                return
            }
            parent.model.pageDidSettle(index: current.pageIndex)
        }
    }
}

// MARK: - 单页视图控制器

final class PageContentController: UIViewController {
    let pageIndex: Int
    var onTapZone: ((Int, PageTapZone) -> Void)?

    private let item: PageItem
    private let palette: ReaderTypography.Palette
    private let footerHeight: CGFloat
    private let textView = UITextView()
    private let footerLabel = UILabel()

    init(item: PageItem, palette: ReaderTypography.Palette, footerHeight: CGFloat) {
        self.item = item
        self.palette = palette
        self.footerHeight = footerHeight
        self.pageIndex = item.pageIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = item.attributed
        view.addSubview(textView)

        footerLabel.text = "\(item.chapterTitle)   \(item.pageIndex + 1)/\(item.pageCount)"
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = UIColor(hex: palette.secondary).withAlphaComponent(0.75)
        footerLabel.textAlignment = .center
        footerLabel.lineBreakMode = .byTruncatingMiddle
        view.addSubview(footerLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let height = view.bounds.height
        textView.frame = CGRect(x: 0, y: 0, width: width, height: max(0, height - footerHeight))
        footerLabel.frame = CGRect(x: 0, y: height - footerHeight, width: width, height: footerHeight)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x
        let width = view.bounds.width
        let zone: PageTapZone
        if x < width / 3 {
            zone = .left
        } else if x > width * 2 / 3 {
            zone = .right
        } else {
            zone = .center
        }
        onTapZone?(pageIndex, zone)
    }
}
