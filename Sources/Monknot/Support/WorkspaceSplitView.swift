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
    static let visibleDividerWidth: CGFloat = 1
    static let autosaveName = "Monknot.WorkspaceSplit"
}

/// Transparent AppKit pointer target mounted over the leading edge of the detail
/// pane. It drives `NSSplitView` positioning directly, preserving native pane
/// constraints and autosave behavior without covering the sidebar scrollbar.
final class WorkspaceSidebarResizeProxy {
    weak var splitView: NSSplitView?
    weak var handleView: WorkspaceSidebarResizeHandleView?
    var resizeSidebar: ((CGFloat) -> Void)?
}

struct WorkspaceSidebarResizeHandle: NSViewRepresentable {
    let proxy: WorkspaceSidebarResizeProxy

    func makeNSView(context: Context) -> WorkspaceSidebarResizeHandleView {
        let view = WorkspaceSidebarResizeHandleView()
        view.resizeProxy = proxy
        proxy.handleView = view
        return view
    }

    func updateNSView(_ nsView: WorkspaceSidebarResizeHandleView, context: Context) {
        nsView.resizeProxy = proxy
        proxy.handleView = nsView
    }
}

struct WorkspaceSplitDetail<Content: View>: View {
    let content: Content
    let resizeProxy: WorkspaceSidebarResizeProxy

    var body: some View {
        content
            .overlay(alignment: .leading) {
                WorkspaceSidebarResizeHandle(proxy: resizeProxy)
                    .frame(width: WorkspaceSplitMetrics.sidebarResizeHitWidth)
                    .frame(maxHeight: .infinity)
                    .zIndex(1)
            }
    }
}

final class WorkspaceSidebarResizeHandleView: NSView {
    var resizeProxy: WorkspaceSidebarResizeProxy?
    private var sidebarWidthAtDragStart: CGFloat?
    private var pointerXAtDragStart: CGFloat?
    private var sidebarWidthDuringDrag: CGFloat?
    private var isCursorPushed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize workspace sidebar")
        setAccessibilityHelp("Drag left or right to resize the workspace sidebar.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        pushResizeCursor()
    }

    override func mouseExited(with event: NSEvent) {
        popResizeCursorIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        pushResizeCursor()
        refreshAccessibilityValue()
        sidebarWidthAtDragStart = resizeProxy?.splitView?.arrangedSubviews.first?.frame.width
        pointerXAtDragStart = event.locationInWindow.x
        sidebarWidthDuringDrag = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let splitView = resizeProxy?.splitView,
              let sidebarWidthAtDragStart,
              let pointerXAtDragStart else {
            return
        }

        let proposedPosition = sidebarWidthAtDragStart
            + event.locationInWindow.x
            - pointerXAtDragStart
        let minimum = WorkspaceSplitMetrics.sidebarMinimumWidth
        let maximum = min(
            WorkspaceSplitMetrics.sidebarMaximumWidth,
            max(
                minimum,
                splitView.bounds.width
                    - splitView.dividerThickness
                    - WorkspaceSplitMetrics.detailMinimumWidth
            )
        )
        let clampedPosition = min(maximum, max(minimum, proposedPosition))
        sidebarWidthDuringDrag = clampedPosition
        resizeProxy?.resizeSidebar?(clampedPosition)
        setAccessibilityValue(clampedPosition)
    }

    override func mouseUp(with event: NSEvent) {
        sidebarWidthAtDragStart = nil
        pointerXAtDragStart = nil
        if let sidebarWidthDuringDrag {
            setAccessibilityValue(sidebarWidthDuringDrag)
        } else {
            refreshAccessibilityValue()
        }
        sidebarWidthDuringDrag = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            popResizeCursorIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func refreshAccessibilityValue() {
        guard let width = resizeProxy?.splitView?.arrangedSubviews.first?.frame.width else { return }
        setAccessibilityValue(width)
    }

    private func pushResizeCursor() {
        guard !isCursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        isCursorPushed = true
    }

    private func popResizeCursorIfNeeded() {
        guard isCursorPushed else { return }
        NSCursor.pop()
        isCursorPushed = false
    }
}

@MainActor
final class WorkspaceSplitViewController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHostingController: NSHostingController<Sidebar>
    let detailHostingController: NSHostingController<WorkspaceSplitDetail<Detail>>
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    let sidebarResizeProxy: WorkspaceSidebarResizeProxy
    private var isSidebarPresented: Bool
    private var shouldApplyReferenceSidebarWidth: Bool
    private var isAnimatingSidebarPresentation = false

    init(
        sidebar: Sidebar,
        detail: Detail,
        isSidebarPresented: Bool,
        autosaveName: String = WorkspaceSplitMetrics.autosaveName
    ) {
        let resizeProxy = WorkspaceSidebarResizeProxy()
        sidebarResizeProxy = resizeProxy
        sidebarHostingController = NSHostingController(rootView: sidebar)
        detailHostingController = NSHostingController(
            rootView: WorkspaceSplitDetail(content: detail, resizeProxy: resizeProxy)
        )
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

        resizeProxy.splitView = splitView
        resizeProxy.resizeSidebar = { [weak self] width in
            self?.setSidebarWidth(width)
        }

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
        sidebarResizeProxy.handleView?.refreshAccessibilityValue()
    }

    var sidebarResizeHitRect: NSRect {
        guard let handleView = sidebarResizeProxy.handleView else { return .zero }
        return splitView.convert(handleView.bounds, from: handleView)
    }

    func setSidebarWidth(_ width: CGFloat) {
        shouldApplyReferenceSidebarWidth = false
        let clampedWidth = min(
            WorkspaceSplitMetrics.sidebarMaximumWidth,
            max(WorkspaceSplitMetrics.sidebarMinimumWidth, width)
        )
        if clampedWidth > sidebarItem.maximumThickness {
            sidebarItem.maximumThickness = clampedWidth
            sidebarItem.minimumThickness = clampedWidth
        } else {
            sidebarItem.minimumThickness = clampedWidth
            sidebarItem.maximumThickness = clampedWidth
        }
    }

    func update(
        sidebar: Sidebar,
        detail: Detail,
        isSidebarPresented: Bool,
        animated: Bool = false
    ) {
        sidebarHostingController.rootView = sidebar
        detailHostingController.rootView = WorkspaceSplitDetail(
            content: detail,
            resizeProxy: sidebarResizeProxy
        )
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
        setSidebarWidth(WorkspaceSplitMetrics.sidebarMinimumWidth)
    }
}
