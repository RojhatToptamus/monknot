import AppKit
import SwiftUI

/// Native ownership for Monknot's persistent workspace sidebar and detail pane.
///
/// `NSSplitViewController` is responsible for divider interaction, accessibility,
/// window-resize behavior, full-screen transitions, and divider persistence. The
/// SwiftUI layer only declares whether the sidebar is presented; it does not
/// inspect AppKit's private view hierarchy or monitor mouse events.
struct WorkspaceSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let isSidebarPresented: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeNSViewController(context: Context) -> WorkspaceSplitViewController<Sidebar, Detail> {
        WorkspaceSplitViewController(
            sidebar: sidebar(),
            detail: detail(),
            isSidebarPresented: isSidebarPresented
        )
    }

    func updateNSViewController(
        _ controller: WorkspaceSplitViewController<Sidebar, Detail>,
        context: Context
    ) {
        controller.update(
            sidebar: sidebar(),
            detail: detail(),
            isSidebarPresented: isSidebarPresented,
            animated: context.transaction.animation != nil && !context.transaction.disablesAnimations
        )
    }
}

enum WorkspaceSplitMetrics {
    static let sidebarMinimumWidth: CGFloat = 248
    static let sidebarMaximumWidth: CGFloat = 440
    static let detailMinimumWidth: CGFloat = 480
    /// The visible divider stays one point wide. Its drag target extends into
    /// the detail pane so it does not compete with the sidebar scrollbar.
    static let sidebarResizeHitWidth: CGFloat = 16
    static let autosaveName = "Monknot.WorkspaceSplit"
}

@MainActor
final class WorkspaceSplitViewController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHostingController: NSHostingController<Sidebar>
    let detailHostingController: NSHostingController<Detail>
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    private var isSidebarPresented: Bool
    private var shouldApplyReferenceSidebarWidth: Bool
    private var isAnimatingSidebarPresentation = false

    init(
        sidebar: Sidebar,
        detail: Detail,
        isSidebarPresented: Bool,
        autosaveName: String = WorkspaceSplitMetrics.autosaveName
    ) {
        sidebarHostingController = NSHostingController(rootView: sidebar)
        detailHostingController = NSHostingController(rootView: detail)
        sidebarItem = NSSplitViewItem(viewController: sidebarHostingController)
        detailItem = NSSplitViewItem(viewController: detailHostingController)
        self.isSidebarPresented = isSidebarPresented
        let autosaveKey = "NSSplitView Subview Frames \(autosaveName)"
        shouldApplyReferenceSidebarWidth = UserDefaults.standard.object(forKey: autosaveKey) == nil

        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarItem.minimumThickness = WorkspaceSplitMetrics.sidebarMinimumWidth
        sidebarItem.maximumThickness = WorkspaceSplitMetrics.sidebarMaximumWidth
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = .defaultHigh
        // ContentView is the single owner of sidebar presentation. Permitting
        // AppKit to collapse this item independently would desynchronize the
        // visible toggle and persisted preference from the native split state.
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.isCollapsed = !isSidebarPresented

        detailItem.minimumThickness = WorkspaceSplitMetrics.detailMinimumWidth
        detailItem.canCollapse = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)

        // Assign after the items exist so AppKit can restore the saved divider
        // configuration against the complete split hierarchy.
        splitView.autosaveName = autosaveName
        // NSSplitView autosave includes collapse state as well as divider
        // position. SceneStorage is Monknot's visibility owner, so reassert
        // that value after AppKit restores the user's saved width.
        sidebarItem.isCollapsed = !isSidebarPresented
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reconcileSidebarPresentation(animated: false)
        applyReferenceSidebarWidthIfNeeded()
    }

    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        let systemRect = super.splitView(
            splitView,
            additionalEffectiveRectOfDividerAt: dividerIndex
        )
        guard dividerIndex == 0,
              splitView.isVertical,
              let sidebarView = splitView.arrangedSubviews.first else {
            return systemRect
        }

        let extraWidth = max(
            0,
            WorkspaceSplitMetrics.sidebarResizeHitWidth - splitView.dividerThickness
        )
        let detailSideRect = NSRect(
            x: sidebarView.frame.maxX + splitView.dividerThickness,
            y: splitView.bounds.minY,
            width: extraWidth,
            height: splitView.bounds.height
        )
        return systemRect.isEmpty ? detailSideRect : systemRect.union(detailSideRect)
    }

    func update(
        sidebar: Sidebar,
        detail: Detail,
        isSidebarPresented: Bool,
        animated: Bool = false
    ) {
        sidebarHostingController.rootView = sidebar
        detailHostingController.rootView = detail
        self.isSidebarPresented = isSidebarPresented
        reconcileSidebarPresentation(animated: animated)
    }

    private func reconcileSidebarPresentation(animated: Bool) {
        let shouldCollapse = !isSidebarPresented
        guard sidebarItem.isCollapsed != shouldCollapse,
              !isAnimatingSidebarPresentation else {
            return
        }

        guard animated, view.window != nil else {
            sidebarItem.isCollapsed = shouldCollapse
            return
        }

        isAnimatingSidebarPresentation = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotMotion.sidebarTransitionDuration
            sidebarItem.animator().isCollapsed = shouldCollapse
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isAnimatingSidebarPresentation = false
                reconcileSidebarPresentation(animated: false)
            }
        }
    }

    private func applyReferenceSidebarWidthIfNeeded() {
        guard shouldApplyReferenceSidebarWidth,
              isSidebarPresented,
              splitView.bounds.width > WorkspaceSplitMetrics.sidebarMinimumWidth else {
            return
        }

        shouldApplyReferenceSidebarWidth = false
        splitView.setPosition(WorkspaceSplitMetrics.sidebarMinimumWidth, ofDividerAt: 0)
    }
}
