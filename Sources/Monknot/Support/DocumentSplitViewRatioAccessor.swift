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
        context.coordinator.updateConfiguration(
            sourcePaneRatio: $sourcePaneRatio,
            minPaneWidth: minPaneWidth,
            onCommit: onCommit
        )
        context.coordinator.attachIfNeeded(from: nsView)
    }

    final class Coordinator: NSObject {
        var sourcePaneRatio: Binding<Double>
        var minPaneWidth: CGFloat
        var onCommit: (Double) -> Void
        private weak var splitView: NSSplitView?
        private var isApplyingRatio = false
        private var targetRatio: Double
        private var hasAppliedTargetRatio = false
        private var resizeObserver: NSObjectProtocol?

        init(sourcePaneRatio: Binding<Double>, minPaneWidth: CGFloat, onCommit: @escaping (Double) -> Void) {
            self.sourcePaneRatio = sourcePaneRatio
            self.minPaneWidth = minPaneWidth
            self.onCommit = onCommit
            targetRatio = DocumentSplitViewPersistence.clampedSourcePaneRatio(sourcePaneRatio.wrappedValue)
        }

        func updateConfiguration(
            sourcePaneRatio: Binding<Double>,
            minPaneWidth: CGFloat,
            onCommit: @escaping (Double) -> Void
        ) {
            let requestedRatio = DocumentSplitViewPersistence.clampedSourcePaneRatio(
                sourcePaneRatio.wrappedValue
            )
            let targetChanged = abs(requestedRatio - targetRatio) > 0.005

            self.sourcePaneRatio = sourcePaneRatio
            self.minPaneWidth = minPaneWidth
            self.onCommit = onCommit

            guard targetChanged else { return }
            targetRatio = requestedRatio
            hasAppliedTargetRatio = false
            applyRatioIfNeeded()
        }

        func attachIfNeeded(from view: NSView) {
            guard splitView == nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let splitView = view.enclosingSplitView else { return }
                self.attach(to: splitView)
            }
        }

        func attach(to splitView: NSSplitView) {
            guard self.splitView !== splitView else { return }
            self.splitView = splitView
            observeResizeEvents(from: splitView)
            applyRatioIfNeeded()
        }

        func applyRatioIfNeeded() {
            guard let splitView, splitView.arrangedSubviews.count >= 2 else { return }
            let availableWidth = paneWidth(in: splitView)
            guard availableWidth > minPaneWidth * 2 else { return }

            isApplyingRatio = true
            hasAppliedTargetRatio = true
            defer { isApplyingRatio = false }

            let position = targetRatio * availableWidth
            let clampedPosition = min(
                max(minPaneWidth, position),
                availableWidth - minPaneWidth
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
                guard let self, !self.isApplyingRatio else { return }
                if self.hasAppliedTargetRatio {
                    self.recordCurrentRatio()
                } else {
                    self.applyRatioIfNeeded()
                }
            }
        }

        private func recordCurrentRatio() {
            guard !isApplyingRatio, let splitView else { return }
            guard splitView.arrangedSubviews.count >= 2 else { return }

            let availableWidth = paneWidth(in: splitView)
            guard availableWidth > 0 else { return }

            let sourceWidth = splitView.arrangedSubviews[0].frame.width
            let ratio = DocumentSplitViewPersistence.clampedSourcePaneRatio(sourceWidth / availableWidth)
            guard abs(ratio - targetRatio) > 0.005 else { return }

            targetRatio = ratio
            sourcePaneRatio.wrappedValue = ratio
            onCommit(ratio)
        }

        private func paneWidth(in splitView: NSSplitView) -> CGFloat {
            splitView.frame.width
                - splitView.dividerThickness * CGFloat(max(0, splitView.arrangedSubviews.count - 1))
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
