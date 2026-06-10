import AppKit
import MonknotCore
import SwiftUI

struct DocumentSplitViewRatioAccessor: NSViewRepresentable {
    @Binding var sourcePaneRatio: Double
    let minPaneWidth: CGFloat
    let onCommit: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sourcePaneRatio: $sourcePaneRatio,
            minPaneWidth: minPaneWidth,
            onCommit: onCommit
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.attachIfNeeded(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sourcePaneRatio = $sourcePaneRatio
        context.coordinator.minPaneWidth = minPaneWidth
        context.coordinator.onCommit = onCommit
        context.coordinator.attachIfNeeded(from: nsView)
        context.coordinator.applyRatioIfNeeded()
    }

    final class Coordinator: NSObject {
        var sourcePaneRatio: Binding<Double>
        var minPaneWidth: CGFloat
        var onCommit: (Double) -> Void
        private weak var splitView: NSSplitView?
        private var isApplyingRatio = false
        private var resizeObserver: NSObjectProtocol?

        init(sourcePaneRatio: Binding<Double>, minPaneWidth: CGFloat, onCommit: @escaping (Double) -> Void) {
            self.sourcePaneRatio = sourcePaneRatio
            self.minPaneWidth = minPaneWidth
            self.onCommit = onCommit
        }

        func attachIfNeeded(from view: NSView) {
            guard splitView == nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let splitView = view.enclosingSplitView else { return }
                self.splitView = splitView
                self.observeResizeEvents(from: splitView)
                self.applyRatioIfNeeded()
            }
        }

        func applyRatioIfNeeded() {
            guard let splitView, splitView.arrangedSubviews.count >= 2 else { return }
            let width = splitView.frame.width
            guard width > minPaneWidth * 2 else { return }

            isApplyingRatio = true
            defer { isApplyingRatio = false }

            let position = DocumentSplitViewPersistence.clampedSourcePaneRatio(sourcePaneRatio.wrappedValue) * width
            let clampedPosition = min(
                max(minPaneWidth, position),
                width - minPaneWidth
            )
            splitView.setPosition(clampedPosition, ofDividerAt: 0)
        }

        private func observeResizeEvents(from splitView: NSSplitView) {
            resizeObserver.map(NotificationCenter.default.removeObserver)
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak self] _ in
                self?.recordCurrentRatio()
            }
        }

        private func recordCurrentRatio() {
            guard !isApplyingRatio, let splitView else { return }
            guard splitView.arrangedSubviews.count >= 2 else { return }

            let width = splitView.frame.width
            guard width > 0 else { return }

            let sourceWidth = splitView.arrangedSubviews[0].frame.width
            let ratio = DocumentSplitViewPersistence.clampedSourcePaneRatio(sourceWidth / width)
            guard abs(ratio - sourcePaneRatio.wrappedValue) > 0.005 else { return }

            sourcePaneRatio.wrappedValue = ratio
            onCommit(ratio)
        }

        deinit {
            resizeObserver.map(NotificationCenter.default.removeObserver)
        }
    }
}

private extension NSView {
    var enclosingSplitView: NSSplitView? {
        sequence(first: superview, next: { $0?.superview })
            .compactMap { $0 as? NSSplitView }
            .first
    }
}
