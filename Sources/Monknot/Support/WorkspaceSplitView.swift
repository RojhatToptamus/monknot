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
            isSidebarPresented: isSidebarPresented
        )
    }
}

enum WorkspaceSplitMetrics {
    static let sidebarMinimumWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 440
    static let detailMinimumWidth: CGFloat = 480
    static let autosaveName = "Monknot.WorkspaceSplit"
}

@MainActor
final class WorkspaceSplitViewController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHostingController: NSHostingController<Sidebar>
    let detailHostingController: NSHostingController<Detail>
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    private var isSidebarPresented: Bool

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

        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarItem.minimumThickness = WorkspaceSplitMetrics.sidebarMinimumWidth
        sidebarItem.maximumThickness = WorkspaceSplitMetrics.sidebarMaximumWidth
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
        reconcileSidebarPresentation()
    }

    func update(sidebar: Sidebar, detail: Detail, isSidebarPresented: Bool) {
        sidebarHostingController.rootView = sidebar
        detailHostingController.rootView = detail
        self.isSidebarPresented = isSidebarPresented
        reconcileSidebarPresentation()
    }

    private func reconcileSidebarPresentation() {
        let shouldCollapse = !isSidebarPresented
        if sidebarItem.isCollapsed != shouldCollapse {
            sidebarItem.isCollapsed = shouldCollapse
        }
    }
}
