import SwiftUI
import UIKit

/// 正文显示视图(UIViewRepresentable 包装 UITextView)
///
/// - 非编辑、不可选、自身不滚动(由外层 SwiftUI ScrollView 承担滚动)
/// - 通过 sizeThatFits 精确测量高度(SwiftUI 布局依赖)
/// - 单击回调用于呼出/收起阅读控制层
struct ReaderTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    /// 内容 + 排版参数签名;变化时才重建 attributedText
    let revision: Int
    let onTap: () -> Void
    /// 自动跟读:滚动到该范围(渲染坐标);scrollToken 变化时执行一次
    var scrollTarget: NSRange? = nil
    var scrollToken: Int = 0

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = true
        tv.addGestureRecognizer(tap)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            tv.attributedText = attributed
        }
        if context.coordinator.scrollToken != scrollToken {
            context.coordinator.scrollToken = scrollToken
            if let target = scrollTarget {
                context.coordinator.scrollTo(target, in: tv)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        // 同宽同内容直接复用上次测量(避免每次布局都整篇重排)
        let coordinator = context.coordinator
        if coordinator.measuredWidth == width,
           coordinator.measuredRevision == revision,
           let cached = coordinator.measuredSize {
            return cached
        }
        // 先同步宽度再测量(测量依赖容器宽度)
        let oldFrame = uiView.frame
        uiView.frame = CGRect(x: 0, y: 0, width: width, height: oldFrame.height)
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        uiView.frame = oldFrame
        var height = measured.height
        if height < 1 {
            // 兜底:走 layoutManager 实测
            uiView.layoutManager.ensureLayout(for: uiView.textContainer)
            let used = uiView.layoutManager.usedRect(for: uiView.textContainer).height
            height = used + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        }
        let result = CGSize(width: width, height: max(1, ceil(height)))
        coordinator.measuredWidth = width
        coordinator.measuredRevision = revision
        coordinator.measuredSize = result
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        var revision: Int = -1
        var scrollToken: Int = -1
        var measuredWidth: CGFloat = -1
        var measuredRevision: Int = Int.min
        var measuredSize: CGSize?

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap() {
            onTap()
        }

        /// 向上找外层滚动视图(UITextView 自身是 UIScrollView,需从 superview 开始找)
        static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var current = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    return scroll
                }
                current = v.superview
            }
            return nil
        }

        /// 把目标范围滚动到可视区(句子已在舒适区内则不动,避免逐句抖动)
        func scrollTo(_ range: NSRange, in tv: UITextView, retry: Bool = true) {
            let textLength = tv.attributedText.length
            guard range.location >= 0, range.location < textLength else { return }
            let safe = NSRange(
                location: range.location,
                length: max(0, min(range.length, textLength - range.location))
            )
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            let glyphRange = tv.layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            var rect = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            rect.origin.x += tv.textContainerInset.left
            rect.origin.y += tv.textContainerInset.top
            guard let scroll = Self.enclosingScrollView(of: tv) else { return }
            let rectInScroll = tv.convert(rect, to: scroll)
            let inset = scroll.adjustedContentInset
            let visibleTop = scroll.contentOffset.y + inset.top
            let visibleBottom = visibleTop + scroll.bounds.height
            let inComfortZone = rectInScroll.minY >= visibleTop + 24
                && rectInScroll.maxY <= visibleBottom - 90
            if inComfortZone {
                return
            }
            var targetY = rectInScroll.minY - scroll.bounds.height * 0.30
            let minY = -inset.top
            let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
            targetY = max(minY, min(targetY, maxY))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: targetY), animated: true)
            if retry {
                // 布局可能尚未完成,稍后校正一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak tv] in
                    guard let tv else { return }
                    self.scrollTo(range, in: tv, retry: false)
                }
            }
        }
    }
}
