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
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
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
        return CGSize(width: width, height: max(1, ceil(height)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        var revision: Int = -1

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap() {
            onTap()
        }
    }
}
