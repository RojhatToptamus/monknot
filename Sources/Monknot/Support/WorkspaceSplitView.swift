import AppKit
import QuartzCore
import SwiftUI

/// The native owner of Monknot's sidebar, document area, and terminal layout.
///
/// AppKit owns pane geometry, divider dragging, collapse state, and persisted
/// divider positions. The SwiftUI layer supplies only preferred visibility;
/// callbacks report the effective visibility when window pressure differs.
struct WorkspaceSplitView<Sidebar: View, Detail: View, Terminal: View>: NSViewControllerRepresentable {
    let isSidebarPresented: Bool
    let isTerminalPresented: Bool
    let isTerminalFullscreen: Bool
    let layoutScale: CGFloat
    let separatorColor: NSColor
    let accentColor: NSColor
    // Monotonic command tokens distinguish an explicit Show action from a
    // preferred-visible pane that AppKit temporarily hid under pressure.
    let sidebarRevealRequest: UInt
    let terminalRevealRequest: UInt
    let onSidebarPresentationChange: (_ isPresented: Bool, _ userInitiated: Bool) -> Void
    let onTerminalPresentationChange: (_ isPresented: Bool, _ userInitiated: Bool) -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let terminal: () -> Terminal

    init(
        isSidebarPresented: Bool,
        isTerminalPresented: Bool,
        isTerminalFullscreen: Bool = false,
        layoutScale: CGFloat,
        separatorColor: NSColor,
        accentColor: NSColor,
        sidebarRevealRequest: UInt = 0,
        terminalRevealRequest: UInt = 0,
        onSidebarPresentationChange: @escaping (_ isPresented: Bool, _ userInitiated: Bool) -> Void,
        onTerminalPresentationChange: @escaping (_ isPresented: Bool, _ userInitiated: Bool) -> Void,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder terminal: @escaping () -> Terminal
    ) {
        self.isSidebarPresented = isSidebarPresented
        self.isTerminalPresented = isTerminalPresented
        self.isTerminalFullscreen = isTerminalFullscreen
        self.layoutScale = layoutScale
        self.separatorColor = separatorColor
        self.accentColor = accentColor
        self.sidebarRevealRequest = sidebarRevealRequest
        self.terminalRevealRequest = terminalRevealRequest
        self.onSidebarPresentationChange = onSidebarPresentationChange
        self.onTerminalPresentationChange = onTerminalPresentationChange
        self.sidebar = sidebar
        self.detail = detail
        self.terminal = terminal
    }

    func makeNSViewController(
        context: Context
    ) -> WorkspaceSplitViewController<Sidebar, Detail, Terminal> {
        WorkspaceSplitViewController(
            sidebar: sidebar(),
            detail: detail(),
            terminal: terminal(),
            isSidebarPresented: isSidebarPresented,
            isTerminalPresented: isTerminalPresented,
            isTerminalFullscreen: isTerminalFullscreen,
            layoutScale: layoutScale,
            separatorColor: separatorColor,
            accentColor: accentColor,
            sidebarRevealRequest: sidebarRevealRequest,
            terminalRevealRequest: terminalRevealRequest,
            onSidebarPresentationChange: onSidebarPresentationChange,
            onTerminalPresentationChange: onTerminalPresentationChange
        )
    }

    func updateNSViewController(
        _ controller: WorkspaceSplitViewController<Sidebar, Detail, Terminal>,
        context: Context
    ) {
        controller.update(
            sidebar: sidebar(),
            detail: detail(),
            terminal: terminal(),
            isSidebarPresented: isSidebarPresented,
            isTerminalPresented: isTerminalPresented,
            isTerminalFullscreen: isTerminalFullscreen,
            layoutScale: layoutScale,
            separatorColor: separatorColor,
            accentColor: accentColor,
            sidebarRevealRequest: sidebarRevealRequest,
            terminalRevealRequest: terminalRevealRequest,
            onSidebarPresentationChange: onSidebarPresentationChange,
            onTerminalPresentationChange: onTerminalPresentationChange,
            animated: context.transaction.animation != nil && !context.transaction.disablesAnimations
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController _: WorkspaceSplitViewController<Sidebar, Detail, Terminal>,
        context _: Context
    ) -> CGSize? {
        // Echo a complete parent allocation, but never derive an ideal size
        // from the view being measured. Partial proposals use SwiftUI's default
        // sizing algorithm so AppKit and SwiftUI cannot measure each other in a
        // layout-feedback loop.
        guard let width = proposal.width,
              let height = proposal.height,
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

enum WorkspaceSplitMetrics {
    static let sidebarMinimumWidth: CGFloat = 248
    static let sidebarMaximumWidth: CGFloat = 440
    static let detailMinimumWidth: CGFloat = 360
    static let terminalMinimumWidth: CGFloat = 320
    static let terminalMaximumWidth: CGFloat = 640
    static let dividerHitWidth: CGFloat = 12
    static let dividerThickness: CGFloat = 3
    static let snapThresholdFraction: CGFloat = 0.5
    /// The smallest window that fits the sidebar, document and terminal at 100% zoom.
    static let minimumWindowWidth = sidebarMinimumWidth + detailMinimumWidth + terminalMinimumWidth
        + 2 * dividerThickness
    static let minimumWindowHeight: CGFloat = 620
    static let autosaveName = "Monknot.WorkspaceSplit.ThreePane"
    static let legacyAutosaveName = "Monknot.WorkspaceSplit"
    static let legacyTerminalWidthKey = "Monknot.terminalDrawerWidth"
    static let migrationMarkerKey = "Monknot.WorkspaceSplit.ThreePane.didMigrate"

    // NSSplitView treats 490 as the priority at which a split item may no
    // longer move during divider tracking. Keep every item below that boundary.
    // The detail pane absorbs window growth and ordinary contraction, while its
    // minimum thickness protects usable document space. Peripherals therefore
    // retain user-set widths across maximize and full-screen transitions.
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(rawValue: 300)
    static let detailHoldingPriority = NSLayoutConstraint.Priority(rawValue: 298)
    static let terminalHoldingPriority = NSLayoutConstraint.Priority(rawValue: 299)

    static func normalizedScale(_ scale: CGFloat) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(Double(scale)))
    }
}

/// A normal NSSplitView with transient divider presentation only. It never
/// calculates or stores pane widths; native divider tracking remains the sole
/// geometry writer.
final class WorkspaceNativeSplitView: NSSplitView {
    var separatorColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    var dividerHitWidth: CGFloat = WorkspaceSplitMetrics.dividerHitWidth {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    var disabledDividerIndices: Set<Int> = [] {
        didSet {
            if let hoveredDividerIndex, disabledDividerIndices.contains(hoveredDividerIndex) {
                setHoveredDivider(nil)
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var isTerminalFullscreen = false {
        didSet {
            guard oldValue != isTerminalFullscreen else { return }
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    // The final value is the pointer-requested divider position before any
    // native minimum-width clamp, not a second pane-width owner.
    var didFinishDraggingDivider: ((Int, CGFloat?, CGFloat?) -> Void)?

    private(set) var hoveredDividerIndex: Int?
    private(set) var activeDividerIndex: Int?
    private var pointerTrackingArea: NSTrackingArea?
    private var lastLayoutHitRects: [NSRect] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override var dividerThickness: CGFloat {
        isTerminalFullscreen
            ? WorkspaceSplitMetrics.dividerThickness / 2
            : WorkspaceSplitMetrics.dividerThickness
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if dividerIndex(containing: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override func drawDivider(in rect: NSRect) {
        let index = dividerIndex(nearest: rect.midX)
        if isTerminalFullscreen {
            guard index == 0,
                  arrangedSubviews.indices.contains(0),
                  arrangedSubviews.indices.contains(2) else {
                return
            }
            let sidebarEdge = arrangedSubviews[0].frame.maxX
            let terminalEdge = arrangedSubviews[2].frame.minX
            separatorColor.setFill()
            NSRect(
                x: (sidebarEdge + terminalEdge) / 2 - 0.5,
                y: rect.minY,
                width: 1,
                height: rect.height
            ).fill()
            return
        }
        let isActive = index == activeDividerIndex
        let isHovered = index == hoveredDividerIndex
        let lineWidth: CGFloat = isActive ? rect.width : (isHovered ? min(2, rect.width) : 1)
        let lineRect = NSRect(
            x: rect.midX - lineWidth / 2,
            y: rect.minY,
            width: lineWidth,
            height: rect.height
        )
        let color = isActive
            ? accentColor
            : (isHovered ? accentColor.withAlphaComponent(0.72) : separatorColor)
        color.setFill()
        lineRect.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredDivider(nil)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for index in dividerIndices where !disabledDividerIndices.contains(index) {
            addCursorRect(hitRect(forDividerAt: index), cursor: horizontalResizeCursor)
        }
    }

    override func layout() {
        super.layout()
        let hitRects = dividerIndices.map { hitRect(forDividerAt: $0) }
        if hitRects != lastLayoutHitRects {
            lastLayoutHitRects = hitRects
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let dividerIndex = dividerIndex(containing: point) else {
            super.mouseDown(with: event)
            return
        }

        activeDividerIndex = dividerIndex
        setHoveredDivider(dividerIndex)
        needsDisplay = true
        let outerPaneIndex = dividerIndex == 0 ? 0 : dividerIndex + 1
        let leadingView = arrangedSubviews[dividerIndex]
        let trailingView = arrangedSubviews[dividerIndex + 1]
        let dividerPosition = leadingView.isHidden
            ? trailingView.frame.minX
            : leadingView.frame.maxX
        let pointerOffsetFromDivider = point.x - dividerPosition
        let widthBeforeDrag: CGFloat?
        if arrangedSubviews.indices.contains(outerPaneIndex),
           !arrangedSubviews[outerPaneIndex].isHidden {
            widthBeforeDrag = arrangedSubviews[outerPaneIndex].frame.width
        } else {
            widthBeforeDrag = nil
        }
        defer {
            activeDividerIndex = nil
            let finalRequestedPosition: CGFloat?
            if let window {
                let pointer: NSPoint
                if let currentEvent = NSApp.currentEvent,
                   currentEvent.type == .leftMouseUp,
                   currentEvent.windowNumber == window.windowNumber {
                    pointer = convert(currentEvent.locationInWindow, from: nil)
                } else {
                    pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                }
                setHoveredDivider(self.dividerIndex(containing: pointer))
                finalRequestedPosition = pointer.x - pointerOffsetFromDivider
            } else {
                setHoveredDivider(nil)
                finalRequestedPosition = nil
            }
            needsDisplay = true
            didFinishDraggingDivider?(
                dividerIndex,
                widthBeforeDrag,
                finalRequestedPosition
            )
        }
        super.mouseDown(with: event)
    }

    /// Both drag targets grow to the right of their divider. Every pane keeps its vertical scroll bar
    /// against its trailing edge, so growing right never covers one: the sidebar divider extends into
    /// the document's leading margin, and the terminal divider extends into the terminal instead of
    /// over the document's scroll bar. With the terminal collapsed, its divider sits at the window
    /// edge and the extra width falls outside the window.
    func hitRect(forDividerAt index: Int) -> NSRect {
        guard dividerIndices.contains(index) else { return .zero }
        let drawnRect = dividerRect(at: index)
        let extraWidth = max(0, dividerHitWidth - drawnRect.width)
        return NSRect(
            x: drawnRect.minX,
            y: bounds.minY,
            width: drawnRect.width + extraWidth,
            height: bounds.height
        )
    }

    private var dividerIndices: Range<Int> {
        0..<max(0, arrangedSubviews.count - 1)
    }

    private var horizontalResizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    private func dividerRect(at index: Int) -> NSRect {
        let leadingView = arrangedSubviews[index]
        let trailingView = arrangedSubviews[index + 1]
        let dividerX: CGFloat
        if leadingView.isHidden {
            dividerX = trailingView.frame.minX
        } else if trailingView.isHidden {
            dividerX = leadingView.frame.maxX - dividerThickness
        } else {
            dividerX = leadingView.frame.maxX
        }
        return NSRect(
            x: dividerX,
            y: bounds.minY,
            width: dividerThickness,
            height: bounds.height
        )
    }

    private func dividerIndex(containing point: NSPoint) -> Int? {
        dividerIndices.first {
            !disabledDividerIndices.contains($0)
                && hitRect(forDividerAt: $0).contains(point)
        }
    }

    private func dividerIndex(nearest x: CGFloat) -> Int? {
        dividerIndices.min { lhs, rhs in
            abs(dividerRect(at: lhs).midX - x) < abs(dividerRect(at: rhs).midX - x)
        }
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredDivider(dividerIndex(containing: point))
    }

    private func setHoveredDivider(_ dividerIndex: Int?) {
        guard hoveredDividerIndex != dividerIndex else { return }
        hoveredDividerIndex = dividerIndex
        needsDisplay = true
    }
}

/// Holds a side pane's content. At rest the content fills the pane. While the pane opens or closes,
/// the content keeps its open width and slides under the window edge, so rows never squeeze and a
/// terminal is not resized on every animation frame.
final class WorkspaceSidePaneController: NSViewController {
    enum Edge {
        case leading
        case trailing
    }

    private let content: NSViewController
    private let edge: Edge

    init(content: NSViewController, edge: Edge) {
        self.content = content
        self.edge = edge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let paneView = PaneView(edge: edge)
        addChild(content)
        paneView.addSubview(content.view)
        view = paneView
    }

    private var transitionGeneration: UInt = 0

    /// Holds the content at the width it last had at rest until the matching `endTransition`. A
    /// newer transition, such as reopening a pane while it is still closing, takes over the hold.
    /// `fallbackWidth` covers a pane that has never been open.
    func beginTransition(fallbackWidth: CGFloat) -> UInt {
        transitionGeneration &+= 1
        (view as? PaneView)?.beginHold(fallbackWidth: fallbackWidth)
        return transitionGeneration
    }

    func endTransition(_ generation: UInt) {
        guard generation == transitionGeneration else { return }
        (view as? PaneView)?.endHold()
    }

    private final class PaneView: NSView {
        private let edge: Edge
        private var restingWidth: CGFloat?
        private var heldWidth: CGFloat?

        init(edge: Edge) {
            self.edge = edge
            super.init(frame: .zero)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func beginHold(fallbackWidth: CGFloat) {
            heldWidth = restingWidth ?? fallbackWidth
            layoutContent()
        }

        func endHold() {
            heldWidth = nil
            layoutContent()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            layoutContent()
        }

        override func layout() {
            super.layout()
            layoutContent()
        }

        private func layoutContent() {
            guard let content = subviews.first else { return }
            if heldWidth == nil, bounds.width > 0 {
                restingWidth = bounds.width
            }
            let width = max(bounds.width, heldWidth ?? 0)
            let frame = NSRect(
                x: edge == .leading ? bounds.width - width : 0,
                y: 0,
                width: width,
                height: bounds.height
            )
            if content.frame != frame {
                content.frame = frame
            }
        }
    }
}

@MainActor
final class WorkspaceSplitViewController<Sidebar: View, Detail: View, Terminal: View>: NSSplitViewController {
    private enum PressureCollapseCause {
        case divider
        case container
    }

    private enum SidePane: CaseIterable {
        case sidebar
        case terminal

        var opposite: SidePane {
            self == .sidebar ? .terminal : .sidebar
        }

        /// The divider between this pane and the document.
        var dividerIndex: Int {
            self == .sidebar ? 0 : 1
        }

        var arrangedIndex: Int {
            self == .sidebar ? 0 : 2
        }

        var minimumWidthBase: CGFloat {
            self == .sidebar
                ? WorkspaceSplitMetrics.sidebarMinimumWidth
                : WorkspaceSplitMetrics.terminalMinimumWidth
        }

        var maximumWidthBase: CGFloat {
            self == .sidebar
                ? WorkspaceSplitMetrics.sidebarMaximumWidth
                : WorkspaceSplitMetrics.terminalMaximumWidth
        }
    }

    /// What the controller tracks for one side pane. Visible pane geometry stays owned by NSSplitView.
    private struct SidePaneState {
        /// The visibility SwiftUI asked for. Window pressure can hide a preferred pane.
        var isPreferred: Bool
        /// A monotonic command token that tells an explicit Show from a preferred pane AppKit hid
        /// under pressure.
        var revealRequest: UInt
        var pressureCollapseCause: PressureCollapseCause?
        /// macOS 15 can normalize a hidden arranged view to its minimum width, so the width a pane had
        /// is kept while, and only while, it is collapsed.
        var collapsedWidth: CGFloat?
        var lastReportedPresentation: Bool?
        var needsForcedReport = false
        var onPresentationChange: (_ isPresented: Bool, _ userInitiated: Bool) -> Void
    }

    private struct SidePaneStates {
        var sidebar: SidePaneState
        var terminal: SidePaneState

        subscript(pane: SidePane) -> SidePaneState {
            get { pane == .sidebar ? sidebar : terminal }
            set {
                switch pane {
                case .sidebar: sidebar = newValue
                case .terminal: terminal = newValue
                }
            }
        }
    }

    let sidebarHostingController: NSHostingController<Sidebar>
    let detailHostingController: NSHostingController<Detail>
    let terminalHostingController: NSHostingController<Terminal>
    private let sidebarPane: WorkspaceSidePaneController
    private let terminalPane: WorkspaceSidePaneController
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    let terminalItem: NSSplitViewItem

    private(set) var isTerminalFullscreen: Bool
    private(set) var layoutScale: CGFloat

    private var panes: SidePaneStates
    // When the window cannot fit both side panes, the one shown last stays and the other steps
    // aside until there is room. Until either is shown explicitly, the sidebar stays.
    private var sidePaneKeptUnderPressure: SidePane = .sidebar
    private var isPresentationReportScheduled = false
    private var splitViewResizeObserver: NSObjectProtocol?
    private var collapseObservations: [NSKeyValueObservation] = []
    private var terminalWidthBeforeFullscreen: CGFloat?
    private var suspendedSplitAutosaveName: NSSplitView.AutosaveName?
    private var didSuspendSplitAutosave = false
    private var terminalFullscreenTransitionGeneration: UInt = 0
    private var isReconcilingTerminalFullscreen = false
    private var isReconcilingPresentation = false
    private var isChangingPressureDuringConstraint = false
    private var isRestoringRetainedWidth = false
    private var migratesLegacyLayout: Bool
    private let workspaceSplitView: WorkspaceNativeSplitView

    var preferredSidebarPresentation: Bool {
        panes.sidebar.isPreferred
    }

    var preferredTerminalPresentation: Bool {
        panes.terminal.isPreferred
    }

    init(
        sidebar: Sidebar,
        detail: Detail,
        terminal: Terminal,
        isSidebarPresented: Bool,
        isTerminalPresented: Bool,
        isTerminalFullscreen: Bool = false,
        layoutScale: CGFloat,
        separatorColor: NSColor,
        accentColor: NSColor,
        sidebarRevealRequest: UInt = 0,
        terminalRevealRequest: UInt = 0,
        onSidebarPresentationChange: @escaping (Bool, Bool) -> Void,
        onTerminalPresentationChange: @escaping (Bool, Bool) -> Void,
        autosaveName: String = WorkspaceSplitMetrics.autosaveName,
        migratesLegacyLayout: Bool? = nil
    ) {
        sidebarHostingController = NSHostingController(rootView: sidebar)
        detailHostingController = NSHostingController(rootView: detail)
        terminalHostingController = NSHostingController(rootView: terminal)
        sidebarPane = WorkspaceSidePaneController(content: sidebarHostingController, edge: .leading)
        terminalPane = WorkspaceSidePaneController(content: terminalHostingController, edge: .trailing)
        // Plain items: sidebar and inspector items make the window retile its titlebar on every
        // frame of a pane transition, which moves the traffic lights. configureItems() sets the
        // collapse behavior those items would otherwise provide.
        sidebarItem = NSSplitViewItem(viewController: sidebarPane)
        detailItem = NSSplitViewItem(viewController: detailHostingController)
        terminalItem = NSSplitViewItem(viewController: terminalPane)
        panes = SidePaneStates(
            sidebar: SidePaneState(
                isPreferred: isSidebarPresented,
                revealRequest: sidebarRevealRequest,
                onPresentationChange: onSidebarPresentationChange
            ),
            terminal: SidePaneState(
                isPreferred: isTerminalPresented,
                revealRequest: terminalRevealRequest,
                onPresentationChange: onTerminalPresentationChange
            )
        )
        self.isTerminalFullscreen = isTerminalFullscreen && isTerminalPresented
        self.layoutScale = WorkspaceSplitMetrics.normalizedScale(layoutScale)
        self.migratesLegacyLayout = migratesLegacyLayout
            ?? (autosaveName == WorkspaceSplitMetrics.autosaveName)
        workspaceSplitView = WorkspaceNativeSplitView()

        super.init(nibName: nil, bundle: nil)

        // NSSplitViewItem is the sole owner of each pane frame. Do not let the
        // embedded SwiftUI roots publish competing min, ideal, or max content
        // constraints back into AppKit's split layout.
        sidebarHostingController.sizingOptions = []
        detailHostingController.sizingOptions = []
        terminalHostingController.sizingOptions = []
        sidebarHostingController.view.identifier = .monknotSidebarFocusRegion
        terminalHostingController.view.identifier = .monknotTerminalFocusRegion

        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        workspaceSplitView.separatorColor = separatorColor
        workspaceSplitView.accentColor = accentColor
        splitView = workspaceSplitView

        configureItems()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(terminalItem)

        // Assign only after all three native items exist so AppKit restores a
        // divider configuration against the authoritative hierarchy.
        splitView.autosaveName = autosaveName
        sidebarItem.isCollapsed = !isSidebarPresented
        terminalItem.isCollapsed = !isTerminalPresented

        collapseObservations = SidePane.allCases.map(observeCollapseChanges(of:))

        workspaceSplitView.didFinishDraggingDivider = {
            [weak self] dividerIndex, widthBeforeDrag, finalRequestedPosition in
            self?.dividerDragDidFinish(
                dividerIndex,
                widthBeforeDrag: widthBeforeDrag,
                finalRequestedPosition: finalRequestedPosition
            )
        }
        splitViewResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: workspaceSplitView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.splitViewDidResize()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let splitViewResizeObserver {
            NotificationCenter.default.removeObserver(splitViewResizeObserver)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        migrateLegacyLayoutIfNeeded()
        reconcilePresentation(animated: false)
    }

    /// The allocation supplied by the representable's parent. AppKit can
    /// transiently enlarge the split itself when a constrained collapsed pane
    /// is dragged open; that intrinsic width is not usable onscreen space.
    private var availableLayoutWidth: CGFloat {
        let splitWidth = splitView.bounds.width
        guard isViewLoaded else { return splitWidth }
        let controllerWidth = view.bounds.width
        guard controllerWidth.isFinite, controllerWidth > 0 else { return splitWidth }
        guard splitWidth.isFinite, splitWidth > 0 else { return controllerWidth }
        return min(controllerWidth, splitWidth)
    }

    private var detailMinimumWidth: CGFloat {
        WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
    }

    private func item(for pane: SidePane) -> NSSplitViewItem {
        pane == .sidebar ? sidebarItem : terminalItem
    }

    private func minimumWidth(of pane: SidePane) -> CGFloat {
        pane.minimumWidthBase * layoutScale
    }

    private func maximumWidth(of pane: SidePane) -> CGFloat {
        pane.maximumWidthBase * layoutScale
    }

    /// `width` within the pane's limits at the current zoom.
    private func clampedWidth(_ width: CGFloat, for pane: SidePane) -> CGFloat {
        min(maximumWidth(of: pane), max(minimumWidth(of: pane), width))
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        if workspaceSplitView.disabledDividerIndices.contains(dividerIndex) {
            return .zero
        }
        let systemRect = super.splitView(
            splitView,
            effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect,
            ofDividerAt: dividerIndex
        )
        guard let workspaceSplitView = splitView as? WorkspaceNativeSplitView else {
            return systemRect
        }
        let dividerHitRect = workspaceSplitView.hitRect(forDividerAt: dividerIndex)
        let verticalRect = systemRect.isEmpty ? splitView.bounds : systemRect
        return NSRect(
            x: dividerHitRect.minX,
            y: verticalRect.minY,
            width: dividerHitRect.width,
            height: verticalRect.height
        ).intersection(splitView.bounds)
    }

    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        if workspaceSplitView.disabledDividerIndices.contains(dividerIndex) {
            return .zero
        }
        let systemRect = super.splitView(
            splitView,
            additionalEffectiveRectOfDividerAt: dividerIndex
        )
        guard isCollapsedOuterDivider(dividerIndex),
              let workspaceSplitView = splitView as? WorkspaceNativeSplitView else {
            return systemRect
        }

        // AppKit hides a collapsed outer divider so it occupies exactly zero
        // layout width. Its additive effective rect keeps that native divider
        // reachable at the window edge without reintroducing a visible gutter.
        return workspaceSplitView.hitRect(forDividerAt: dividerIndex)
    }

    override func splitView(
        _ splitView: NSSplitView,
        shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        super.splitView(splitView, shouldHideDividerAt: dividerIndex)
            || isCollapsedOuterDivider(dividerIndex)
    }

    private func isCollapsedOuterDivider(_ dividerIndex: Int) -> Bool {
        SidePane.allCases.contains { $0.dividerIndex == dividerIndex && item(for: $0).isCollapsed }
    }

    override func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        let systemCanCollapse = super.splitView(splitView, canCollapseSubview: subview)
        guard splitView.arrangedSubviews.count == 3 else { return systemCanCollapse }
        return systemCanCollapse
            || (subview === splitView.arrangedSubviews[0] && sidebarItem.canCollapse)
            || (subview === splitView.arrangedSubviews[2] && terminalItem.canCollapse)
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard workspaceSplitView.activeDividerIndex == dividerIndex,
              !isChangingPressureDuringConstraint else {
            return proposedPosition
        }

        let dividerWidth = splitView.dividerThickness
        let sidebarMinimum = minimumWidth(of: .sidebar)
        let detailMinimum = detailMinimumWidth
        let terminalMinimum = minimumWidth(of: .terminal)
        let snapEpsilon = max(1, layoutScale)
        let availableWidth = availableLayoutWidth

        if dividerIndex == 0 {
            if sidebarItem.isCollapsed {
                guard proposedPosition >= sidebarMinimum else { return 0 }
                setCollapsed(false, for: .sidebar, animated: false)
            } else if shouldSnapDraggedPaneClosed(.sidebar, at: proposedPosition) {
                setCollapsed(true, for: .sidebar, animated: false)
                return 0
            }

            let maximumSidebarWithBothPeripherals = availableWidth
                - (2 * dividerWidth)
                - detailMinimum
                - terminalMinimum
            let terminalCollapseThreshold = maximumSidebarWithBothPeripherals
                + terminalMinimum * WorkspaceSplitMetrics.snapThresholdFraction

            if panes.terminal.pressureCollapseCause == .divider,
               terminalItem.isCollapsed,
               proposedPosition < terminalCollapseThreshold - snapEpsilon {
                changePressureCollapse(false, for: .terminal)
                panes.terminal.pressureCollapseCause = nil
            } else if panes.terminal.isPreferred,
                      !terminalItem.isCollapsed,
                      maximumSidebarWithBothPeripherals < maximumWidth(of: .sidebar),
                      proposedPosition > terminalCollapseThreshold {
                panes.terminal.pressureCollapseCause = .divider
                changePressureCollapse(true, for: .terminal)
            }
        } else if dividerIndex == 1 {
            let maximumDividerForTerminalMinimum = availableWidth
                - terminalMinimum
                - dividerWidth
            if terminalItem.isCollapsed {
                guard proposedPosition <= maximumDividerForTerminalMinimum else {
                    return availableWidth - dividerWidth
                }
                setCollapsed(false, for: .terminal, animated: false)
            } else if shouldSnapDraggedPaneClosed(.terminal, at: proposedPosition) {
                setCollapsed(true, for: .terminal, animated: false)
                return availableWidth - dividerWidth
            }

            let minimumRightDividerWithBothPeripherals = sidebarMinimum
                + dividerWidth
                + detailMinimum
            let maximumTerminalWithBothPeripherals = availableWidth
                - minimumRightDividerWithBothPeripherals
                - dividerWidth
            let sidebarCollapseThreshold = minimumRightDividerWithBothPeripherals
                - sidebarMinimum * WorkspaceSplitMetrics.snapThresholdFraction

            if panes.sidebar.pressureCollapseCause == .divider,
               sidebarItem.isCollapsed,
               proposedPosition > sidebarCollapseThreshold + snapEpsilon {
                changePressureCollapse(false, for: .sidebar)
                panes.sidebar.pressureCollapseCause = nil
            } else if panes.sidebar.isPreferred,
                      !sidebarItem.isCollapsed,
                      maximumTerminalWithBothPeripherals < maximumWidth(of: .terminal),
                      proposedPosition < sidebarCollapseThreshold {
                panes.sidebar.pressureCollapseCause = .divider
                changePressureCollapse(true, for: .sidebar)
            }
        }

        // NSSplitViewController's split-item constraints remain authoritative;
        // this delegate only coordinates edge snapping and the nonadjacent
        // peripheral when the document reaches its minimum.
        return proposedPosition
    }

    func update(
        sidebar: Sidebar,
        detail: Detail,
        terminal: Terminal,
        isSidebarPresented: Bool,
        isTerminalPresented: Bool,
        isTerminalFullscreen: Bool = false,
        layoutScale: CGFloat,
        separatorColor: NSColor,
        accentColor: NSColor,
        sidebarRevealRequest: UInt = 0,
        terminalRevealRequest: UInt = 0,
        onSidebarPresentationChange: @escaping (Bool, Bool) -> Void,
        onTerminalPresentationChange: @escaping (Bool, Bool) -> Void,
        animated: Bool = false
    ) {
        sidebarHostingController.rootView = sidebar
        detailHostingController.rootView = detail
        terminalHostingController.rootView = terminal
        var requestedReveals: [SidePane] = []
        if panes.sidebar.revealRequest != sidebarRevealRequest, isSidebarPresented {
            requestedReveals.append(.sidebar)
        }
        if panes.terminal.revealRequest != terminalRevealRequest, isTerminalPresented {
            requestedReveals.append(.terminal)
        }
        let wasTerminalFullscreen = self.isTerminalFullscreen
        panes.sidebar.isPreferred = isSidebarPresented
        panes.sidebar.revealRequest = sidebarRevealRequest
        panes.sidebar.onPresentationChange = onSidebarPresentationChange
        panes.terminal.isPreferred = isTerminalPresented
        panes.terminal.revealRequest = terminalRevealRequest
        panes.terminal.onPresentationChange = onTerminalPresentationChange
        self.isTerminalFullscreen = isTerminalFullscreen && isTerminalPresented
        workspaceSplitView.separatorColor = separatorColor
        workspaceSplitView.accentColor = accentColor

        let normalizedScale = WorkspaceSplitMetrics.normalizedScale(layoutScale)
        if self.layoutScale != normalizedScale {
            let previousScale = self.layoutScale
            let sidebarWidth = restorableWidthIfAvailable(for: .sidebar)
            let terminalWidth = self.isTerminalFullscreen
                ? nil
                : restorableWidthIfAvailable(for: .terminal)
            if self.isTerminalFullscreen, let terminalWidthBeforeFullscreen {
                self.terminalWidthBeforeFullscreen = min(
                    WorkspaceSplitMetrics.terminalMaximumWidth * normalizedScale,
                    max(
                        WorkspaceSplitMetrics.terminalMinimumWidth * normalizedScale,
                        terminalWidthBeforeFullscreen * normalizedScale / previousScale
                    )
                )
            }
            applyLayoutScaleChange(
                to: normalizedScale,
                sidebarWidth: sidebarWidth,
                terminalWidth: terminalWidth,
                ratio: normalizedScale / previousScale,
                availableWidth: availableLayoutWidth
            )
        }
        for pane in SidePane.allCases where !panes[pane].isPreferred {
            panes[pane].pressureCollapseCause = nil
            if workspaceSplitView.activeDividerIndex == nil,
               panes[pane.opposite].pressureCollapseCause == .divider {
                panes[pane.opposite].pressureCollapseCause = nil
            }
        }
        for pane in requestedReveals {
            panes[pane].pressureCollapseCause = nil
            sidePaneKeptUnderPressure = pane
        }
        if wasTerminalFullscreen, !self.isTerminalFullscreen {
            reconcileTerminalFullscreen(animated: animated && isTerminalPresented)
        }
        reconcilePresentation(animated: animated)
        if self.isTerminalFullscreen {
            reconcileTerminalFullscreen(animated: animated)
        }
        // Not even the document and this one pane fit: say so, rather than doing nothing.
        let unmetReveals = requestedReveals.filter { item(for: $0).isCollapsed }
        if !unmetReveals.isEmpty {
            NSSound.beep()
        }
        for pane in unmetReveals {
            reportPresentationChanges(forced: [pane])
        }
    }

    private func configureItems() {
        let scale = layoutScale
        sidebarItem.minimumThickness = WorkspaceSplitMetrics.sidebarMinimumWidth * scale
        sidebarItem.maximumThickness = WorkspaceSplitMetrics.sidebarMaximumWidth * scale
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = WorkspaceSplitMetrics.sidebarHoldingPriority
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        detailItem.minimumThickness = isTerminalFullscreen
            ? 0
            : WorkspaceSplitMetrics.detailMinimumWidth * scale
        detailItem.holdingPriority = WorkspaceSplitMetrics.detailHoldingPriority
        detailItem.canCollapse = isTerminalFullscreen

        terminalItem.minimumThickness = isTerminalFullscreen
            ? 0
            : WorkspaceSplitMetrics.terminalMinimumWidth * scale
        terminalItem.maximumThickness = isTerminalFullscreen
            ? NSSplitViewItem.unspecifiedDimension
            : WorkspaceSplitMetrics.terminalMaximumWidth * scale
        terminalItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        terminalItem.holdingPriority = WorkspaceSplitMetrics.terminalHoldingPriority
        terminalItem.canCollapse = !isTerminalFullscreen
        terminalItem.canCollapseFromWindowResize = !isTerminalFullscreen
        terminalItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        workspaceSplitView.dividerHitWidth = WorkspaceSplitMetrics.dividerHitWidth * scale
    }

    private func applyLayoutScaleChange(
        to scale: CGFloat,
        sidebarWidth: CGFloat?,
        terminalWidth: CGFloat?,
        ratio: CGFloat,
        availableWidth: CGFloat
    ) {
        isReconcilingPresentation = true
        defer { isReconcilingPresentation = false }

        // Decide pressure against the allocation SwiftUI already gave us.
        // Installing larger native minima first can make AppKit grow the split
        // to satisfy all three panes, after which the artificial width would
        // incorrectly look large enough to keep the terminal visible.
        collapsePanesThatAreNotPreferred(animated: false)
        collapsePanesThatCannotFit(at: scale, availableWidth: availableWidth)
        splitView.layoutSubtreeIfNeeded()

        layoutScale = scale
        configureItems()
        applyScaleChangeToNativePaneWidths(
            sidebarWidth: sidebarWidth,
            terminalWidth: terminalWidth,
            ratio: ratio
        )
    }

    private func collapsePanesThatAreNotPreferred(animated: Bool) {
        for pane in SidePane.allCases where !panes[pane].isPreferred {
            panes[pane].pressureCollapseCause = nil
            setCollapsed(true, for: pane, animated: animated)
        }
    }

    private func collapsePanesThatCannotFit(
        at scale: CGFloat,
        availableWidth: CGFloat,
        animated: Bool = false
    ) {
        guard availableWidth > 0, !isTerminalFullscreen else { return }

        let dividerWidth = splitView.dividerThickness
        let sidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * scale
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * scale
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * scale

        func requiredMinimumWidth(sidebar: Bool, terminal: Bool) -> CGFloat {
            detailMinimum
                + (sidebar ? sidebarMinimum + dividerWidth : 0)
                + (terminal ? terminalMinimum + dividerWidth : 0)
        }

        var keepsSidebar = panes.sidebar.isPreferred
            && requiredMinimumWidth(sidebar: true, terminal: false) <= availableWidth
        var keepsTerminal = panes.terminal.isPreferred
            && requiredMinimumWidth(sidebar: false, terminal: true) <= availableWidth
        if keepsSidebar, keepsTerminal,
           requiredMinimumWidth(sidebar: true, terminal: true) > availableWidth {
            switch sidePaneKeptUnderPressure {
            case .sidebar: keepsTerminal = false
            case .terminal: keepsSidebar = false
            }
        }

        if panes.terminal.isPreferred, !keepsTerminal {
            panes.terminal.pressureCollapseCause = .container
            setCollapsed(true, for: .terminal, animated: animated)
        }
        if panes.sidebar.isPreferred, !keepsSidebar {
            panes.sidebar.pressureCollapseCause = .container
            setCollapsed(true, for: .sidebar, animated: animated)
        }
    }

    /// Imports the former two-pane sidebar autosave and the former public
    /// terminal-width preference once. AppKit reads its own legacy autosave;
    /// Monknot does not inspect or copy NSSplitView's private defaults keys.
    private func migrateLegacyLayoutIfNeeded() {
        guard migratesLegacyLayout, availableLayoutWidth > 0 else { return }
        // Checked once: this runs on every layout pass.
        migratesLegacyLayout = false
        guard !UserDefaults.standard.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey) else {
            return
        }

        // Claim the one-time migration before inspecting geometry. MainActor
        // serializes controllers in multi-window launches, and a narrow first
        // window must not leave a deferred migration that can overwrite native
        // divider changes after a later resize.
        let legacyTerminalWidth = (UserDefaults.standard.object(
            forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey
        ) as? NSNumber)?.doubleValue ?? 420
        UserDefaults.standard.set(true, forKey: WorkspaceSplitMetrics.migrationMarkerKey)
        UserDefaults.standard.removeObject(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)

        let availableWidth = availableLayoutWidth
        let dividerWidth = splitView.dividerThickness
        let sidebarWidth = clampedWidth(
            readLegacySidebarWidth(availableWidth: availableWidth),
            for: .sidebar
        )
        let terminalWidth = clampedWidth(CGFloat(legacyTerminalWidth), for: .terminal)
        let stagingWidth = max(
            availableWidth,
            detailMinimumWidth + dividerWidth + max(sidebarWidth, terminalWidth)
        )
        let originalSplitFrame = splitView.frame

        isReconcilingPresentation = true
        // A highly zoomed narrow window can be smaller than one peripheral
        // minimum plus the document minimum. Give the native split a temporary
        // staging capacity, then restore the real frame before presentation is
        // reconciled. A pane that remains collapsed keeps its imported width
        // only for that collapsed lifetime; no persistent width store or
        // deferred migration is needed.
        if stagingWidth > availableWidth {
            splitView.frame = NSRect(
                x: originalSplitFrame.minX,
                y: originalSplitFrame.minY,
                width: stagingWidth,
                height: originalSplitFrame.height
            )
        }
        sidebarItem.isCollapsed = true
        terminalItem.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()

        // Stage each native pane against the document area independently.
        // This preserves both useful widths even when a narrow first window
        // cannot display all three minima at once.
        stageCollapsedPane(.sidebar, atWidth: sidebarWidth)
        stageCollapsedPane(.terminal, atWidth: terminalWidth)

        splitView.frame = originalSplitFrame
        splitView.layoutSubtreeIfNeeded()
        isReconcilingPresentation = false

        reconcilePresentation(animated: false)
    }

    private func readLegacySidebarWidth(availableWidth: CGFloat) -> CGFloat {
        let probeController = NSSplitViewController()
        let sidebarProbe = NSSplitViewItem(viewController: NSViewController())
        let detailProbe = NSSplitViewItem(viewController: NSViewController())
        probeController.splitView.isVertical = true
        probeController.splitView.frame = NSRect(
            x: 0,
            y: 0,
            width: availableWidth,
            height: max(1, splitView.bounds.height)
        )
        sidebarProbe.minimumThickness = WorkspaceSplitMetrics.sidebarMinimumWidth
        sidebarProbe.maximumThickness = WorkspaceSplitMetrics.sidebarMaximumWidth
        sidebarProbe.holdingPriority = WorkspaceSplitMetrics.sidebarHoldingPriority
        detailProbe.minimumThickness = 480
        detailProbe.holdingPriority = WorkspaceSplitMetrics.detailHoldingPriority
        probeController.addSplitViewItem(sidebarProbe)
        probeController.addSplitViewItem(detailProbe)
        _ = probeController.view
        probeController.splitView.setPosition(
            WorkspaceSplitMetrics.sidebarMinimumWidth,
            ofDividerAt: 0
        )
        probeController.splitView.autosaveName = WorkspaceSplitMetrics.legacyAutosaveName
        defer { probeController.splitView.autosaveName = nil }
        probeController.splitView.layoutSubtreeIfNeeded()
        guard probeController.splitView.arrangedSubviews.indices.contains(0) else {
            return WorkspaceSplitMetrics.sidebarMinimumWidth
        }
        let width = probeController.splitView.arrangedSubviews[0].frame.width
        guard width.isFinite, width > 0 else {
            return WorkspaceSplitMetrics.sidebarMinimumWidth
        }
        return width
    }

    private func reconcileTerminalFullscreen(animated: Bool) {
        guard availableLayoutWidth > 0,
              workspaceSplitView.activeDividerIndex == nil,
              !isReconcilingTerminalFullscreen else {
            return
        }

        if isTerminalFullscreen {
            guard panes.terminal.isPreferred, !terminalItem.isCollapsed else { return }
            enterTerminalFullscreen(animated: animated)
        } else if detailItem.isCollapsed
                    || terminalWidthBeforeFullscreen != nil
                    || didSuspendSplitAutosave {
            restoreTerminalFromFullscreen(animated: animated)
        }
    }

    private func enterTerminalFullscreen(animated: Bool) {
        if terminalWidthBeforeFullscreen == nil {
            let width = nativePaneWidth(of: .terminal)
            if width.isFinite, width > 0 {
                terminalWidthBeforeFullscreen = clampedWidth(width, for: .terminal)
            }
        }

        suspendSplitAutosaveForTerminalFullscreen()
        configureItems()
        workspaceSplitView.isTerminalFullscreen = true
        workspaceSplitView.disabledDividerIndices = [0, 1]
        workspaceSplitView.needsDisplay = true

        guard !detailItem.isCollapsed else { return }
        isReconcilingTerminalFullscreen = true
        let generation = beginTerminalFullscreenTransition()

        guard animated, view.window != nil else {
            detailItem.isCollapsed = true
            splitView.layoutSubtreeIfNeeded()
            isReconcilingTerminalFullscreen = false
            return
        }

        animateTerminalFullscreenTransition {
            detailItem.animator().isCollapsed = true
        } completion: { [weak self] in
            guard let self,
                  self.terminalFullscreenTransitionGeneration == generation else {
                return
            }
            self.splitView.layoutSubtreeIfNeeded()
            self.isReconcilingTerminalFullscreen = false
            if !self.isTerminalFullscreen {
                self.reconcileTerminalFullscreen(animated: true)
            }
        }
    }

    private func restoreTerminalFromFullscreen(animated: Bool) {
        let retainedWidth = terminalWidthBeforeFullscreen ?? minimumWidth(of: .terminal)

        isReconcilingTerminalFullscreen = true
        let generation = beginTerminalFullscreenTransition()

        // Keep the document mounted and start it at zero width. Moving the
        // terminal divider then reveals the same document view without a fade,
        // replacement host, or loss of editor state.
        detailItem.minimumThickness = 0
        detailItem.canCollapse = true
        terminalItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        terminalItem.canCollapse = true
        terminalItem.canCollapseFromWindowResize = true
        detailItem.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()

        let targetPosition = dividerPosition(
            forWidth: fittedWidth(retaining: retainedWidth, for: .terminal),
            of: .terminal
        )

        guard animated, view.window != nil else {
            splitView.setPosition(targetPosition, ofDividerAt: 1)
            splitView.layoutSubtreeIfNeeded()
            finishTerminalFullscreenRestore(
                generation: generation,
                retainedWidth: retainedWidth
            )
            return
        }

        animateTerminalFullscreenTransition {
            splitView.animator().setPosition(targetPosition, ofDividerAt: 1)
        } completion: { [weak self] in
            self?.finishTerminalFullscreenRestore(
                generation: generation,
                retainedWidth: retainedWidth
            )
        }
    }

    private func beginTerminalFullscreenTransition() -> UInt {
        terminalFullscreenTransitionGeneration &+= 1
        return terminalFullscreenTransitionGeneration
    }

    /// Runs `changes` as the terminal fullscreen width transition (design.md §11), then `completion`
    /// on the next main-queue turn.
    private func animateTerminalFullscreenTransition(
        _ changes: () -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotMotion.terminalFullscreenTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion()
                }
            }
        }
    }

    private func finishTerminalFullscreenRestore(
        generation: UInt,
        retainedWidth: CGFloat
    ) {
        guard terminalFullscreenTransitionGeneration == generation else { return }
        guard !isTerminalFullscreen else {
            isReconcilingTerminalFullscreen = false
            reconcileTerminalFullscreen(animated: true)
            return
        }

        workspaceSplitView.isTerminalFullscreen = false
        configureItems()
        splitView.layoutSubtreeIfNeeded()
        setTerminalWidth(fittedWidth(retaining: retainedWidth, for: .terminal))
        terminalWidthBeforeFullscreen = nil
        workspaceSplitView.disabledDividerIndices = []
        workspaceSplitView.needsDisplay = true
        restoreSplitAutosaveAfterTerminalFullscreen()
        isReconcilingTerminalFullscreen = false
    }

    private func setTerminalWidth(_ targetWidth: CGFloat) {
        let requestedPosition = dividerPosition(forWidth: targetWidth, of: .terminal)
        splitView.setPosition(requestedPosition, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()

        // A collapsed middle item makes AppKit retain the previous half-divider
        // spacing for the first normal layout pass. Correct that native result
        // once from the measured pane width so restoration is exact.
        let widthDelta = nativePaneWidth(of: .terminal) - targetWidth
        guard abs(widthDelta) > 0.25 else { return }
        splitView.setPosition(requestedPosition + widthDelta, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
    }

    private func suspendSplitAutosaveForTerminalFullscreen() {
        guard !didSuspendSplitAutosave else { return }
        suspendedSplitAutosaveName = splitView.autosaveName
        didSuspendSplitAutosave = true
        splitView.autosaveName = nil
    }

    private func restoreSplitAutosaveAfterTerminalFullscreen() {
        guard didSuspendSplitAutosave else { return }
        let autosaveName = suspendedSplitAutosaveName
        suspendedSplitAutosaveName = nil
        didSuspendSplitAutosave = false
        splitView.autosaveName = autosaveName
    }

    private func reconcilePresentation(animated: Bool) {
        // Native mouse tracking owns geometry until mouse-up. SwiftUI can
        // immediately feed an effective collapse callback back into update();
        // applying that preference mid-drag would cancel an outward restore.
        guard !isReconcilingPresentation,
              availableLayoutWidth > 0,
              workspaceSplitView.activeDividerIndex == nil else {
            return
        }
        isReconcilingPresentation = true
        defer {
            isReconcilingPresentation = false
            reportPresentationChanges()
        }

        collapsePanesThatAreNotPreferred(animated: animated)
        collapsePanesThatCannotFit(
            at: layoutScale,
            availableWidth: availableLayoutWidth,
            animated: animated
        )

        // The pane that stays under pressure gets the first claim on the room.
        restorePaneIfItFits(sidePaneKeptUnderPressure, animated: animated)
        restorePaneIfItFits(sidePaneKeptUnderPressure.opposite, animated: animated)
        reconcileTerminalFullscreen(animated: animated)
    }

    /// Reopens a preferred, collapsed pane once it fits beside the document. A pane the window
    /// squeezed must fit at the width it had; a pane any pressure closed must also leave the other
    /// pane its current width.
    private func restorePaneIfItFits(_ pane: SidePane, animated: Bool) {
        let collapseCause = panes[pane].pressureCollapseCause
        guard panes[pane].isPreferred,
              item(for: pane).isCollapsed,
              canRestore(
                  pane,
                  preservingItsWidth: collapseCause == .container,
                  preservingOppositeWidth: collapseCause != nil
              ) else {
            return
        }
        setCollapsed(false, for: pane, animated: animated)
        panes[pane].pressureCollapseCause = nil
        splitView.layoutSubtreeIfNeeded()
    }

    private func canRestore(
        _ pane: SidePane,
        preservingItsWidth: Bool,
        preservingOppositeWidth: Bool
    ) -> Bool {
        let dividerWidth = splitView.dividerThickness
        let detailMinimum = isTerminalFullscreen ? 0 : detailMinimumWidth
        let paneWidth = preservingItsWidth
            ? clampedWidth(restorableWidth(for: pane), for: pane)
            : minimumWidth(of: pane)
        return paneWidth + dividerWidth + detailMinimum
            + occupiedWidth(of: pane.opposite, preservingWidth: preservingOppositeWidth)
            <= availableLayoutWidth
    }

    /// The room `pane` and its divider take beside the document: nothing while collapsed, otherwise its
    /// current width (or only its minimum) plus the divider.
    private func occupiedWidth(of pane: SidePane, preservingWidth: Bool) -> CGFloat {
        guard !item(for: pane).isCollapsed else { return 0 }
        let width = preservingWidth
            ? max(minimumWidth(of: pane), nativePaneWidth(of: pane))
            : minimumWidth(of: pane)
        return width + splitView.dividerThickness
    }

    private func observeCollapseChanges(of pane: SidePane) -> NSKeyValueObservation {
        item(for: pane).observe(\.isCollapsed, options: [.prior]) { [weak self] item, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                if change.isPrior {
                    self.captureWidthBeforeCollapse(of: pane)
                } else if !item.isCollapsed {
                    self.restoreCollapsedWidthIfNeeded(of: pane)
                }
            }
        }
    }

    private func captureWidthBeforeCollapse(of pane: SidePane) {
        guard !item(for: pane).isCollapsed, panes[pane].collapsedWidth == nil else { return }
        let width = nativePaneWidth(of: pane)
        guard width.isFinite, width > 0 else { return }
        panes[pane].collapsedWidth = width
    }

    private func restoreCollapsedWidthIfNeeded(of pane: SidePane) {
        let item = item(for: pane)
        let isOppositePressureRevealDuringDrag =
            workspaceSplitView.activeDividerIndex == pane.opposite.dividerIndex
                && panes[pane].pressureCollapseCause != nil
        if isOppositePressureRevealDuringDrag,
           !isChangingPressureDuringConstraint {
            item.isCollapsed = true
            return
        }

        guard let width = panes[pane].collapsedWidth else { return }
        // Restoring lays the split out, and in a window too narrow for every pane AppKit may
        // expand another item within that pass. That item restores once the pass is over.
        guard !isRestoringRetainedWidth else {
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, !item.isCollapsed else { return }
                self.restoreCollapsedWidthIfNeeded(of: pane)
            }
            return
        }
        isRestoringRetainedWidth = true
        defer { isRestoringRetainedWidth = false }
        panes[pane].collapsedWidth = nil
        splitView.layoutSubtreeIfNeeded()
        setNativeWidth(fittedWidth(retaining: width, for: pane), of: pane)
    }

    private func setCollapsed(_ collapsed: Bool, for pane: SidePane, animated: Bool) {
        let item = item(for: pane)
        guard item.isCollapsed != collapsed else { return }
        guard animated, view.window != nil else {
            item.isCollapsed = collapsed
            if !collapsed {
                splitView.layoutSubtreeIfNeeded()
            }
            return
        }

        // Opening and closing are the same native transition run in opposite directions. The
        // content holds its open width throughout and slides under the window edge.
        let paneController = pane == .sidebar ? sidebarPane : terminalPane
        let transition = paneController.beginTransition(
            fallbackWidth: clampedWidth(restorableWidth(for: pane), for: pane)
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotMotion.paneTransitionDuration
            context.timingFunction = MonknotMotion.paneTimingFunction
            item.animator().isCollapsed = collapsed
        } completionHandler: { [weak paneController] in
            MainActor.assumeIsolated {
                paneController?.endTransition(transition)
            }
        }
    }

    private func restorableWidth(for pane: SidePane) -> CGFloat {
        if item(for: pane).isCollapsed, let collapsedWidth = panes[pane].collapsedWidth {
            return collapsedWidth
        }
        return nativePaneWidth(of: pane)
    }

    private func restorableWidthIfAvailable(for pane: SidePane) -> CGFloat? {
        if item(for: pane).isCollapsed, let collapsedWidth = panes[pane].collapsedWidth {
            return collapsedWidth
        }
        let width = nativePaneWidth(of: pane)
        guard width.isFinite, width > 0 else { return nil }
        return width
    }

    private func nativePaneWidth(of pane: SidePane) -> CGFloat {
        guard splitView.arrangedSubviews.indices.contains(pane.arrangedIndex) else { return 0 }
        return splitView.arrangedSubviews[pane.arrangedIndex].frame.width
    }

    /// The divider position that gives `pane` the width `width`.
    private func dividerPosition(forWidth width: CGFloat, of pane: SidePane) -> CGFloat {
        switch pane {
        case .sidebar:
            return width
        case .terminal:
            return splitView.bounds.width - width - splitView.dividerThickness
        }
    }

    private func setNativeWidth(_ width: CGFloat, of pane: SidePane) {
        splitView.setPosition(dividerPosition(forWidth: width, of: pane), ofDividerAt: pane.dividerIndex)
        splitView.layoutSubtreeIfNeeded()
    }

    /// `retainedWidth` within the pane's limits and the room left beside the document minimum and
    /// the opposite pane at its current width.
    private func fittedWidth(retaining retainedWidth: CGFloat, for pane: SidePane) -> CGFloat {
        let maximumAvailable = availableLayoutWidth
            - detailMinimumWidth
            - occupiedWidth(of: pane.opposite, preservingWidth: true)
            - splitView.dividerThickness
        return clampedWidth(min(retainedWidth, maximumAvailable), for: pane)
    }

    /// Opens a collapsed pane just long enough to set its width through the native divider, so the
    /// collapse keeps that width for the pane's next reveal.
    private func stageCollapsedPane(
        _ pane: SidePane,
        atWidth width: CGFloat,
        limitedToSplitWidth: Bool = false
    ) {
        let item = item(for: pane)
        item.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()
        let stagedWidth = limitedToSplitWidth
            ? min(width, splitView.bounds.width - splitView.dividerThickness)
            : width
        setNativeWidth(stagedWidth, of: pane)
        item.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()
    }

    private func applyScaleChangeToNativePaneWidths(
        sidebarWidth: CGFloat?,
        terminalWidth: CGFloat?,
        ratio: CGFloat
    ) {
        guard availableLayoutWidth > 0,
              workspaceSplitView.activeDividerIndex == nil,
              ratio.isFinite,
              ratio > 0 else {
            return
        }

        let sidebarTarget = sidebarWidth.map { clampedWidth($0 * ratio, for: .sidebar) }
        let terminalTarget = terminalWidth.map { clampedWidth($0 * ratio, for: .terminal) }
        guard sidebarTarget != nil || terminalTarget != nil else { return }

        let sidebarWasCollapsed = sidebarItem.isCollapsed
        let terminalWasCollapsed = terminalItem.isCollapsed

        let wasReconcilingPresentation = isReconcilingPresentation
        isReconcilingPresentation = true
        defer { isReconcilingPresentation = wasReconcilingPresentation }
        splitView.layoutSubtreeIfNeeded()

        // Stage each collapsed pane through the native divider API while the
        // detail pane temporarily yields its minimum. Its transient collapsed
        // width is consumed on reveal and captured again after positioning at
        // the new scale.
        if sidebarWasCollapsed || terminalWasCollapsed {
            let detailMinimum = detailItem.minimumThickness
            detailItem.minimumThickness = 0
            defer { detailItem.minimumThickness = detailMinimum }

            sidebarItem.isCollapsed = true
            terminalItem.isCollapsed = true
            splitView.layoutSubtreeIfNeeded()

            if sidebarWasCollapsed, let sidebarTarget {
                stageCollapsedPane(.sidebar, atWidth: sidebarTarget, limitedToSplitWidth: true)
            }
            if terminalWasCollapsed, let terminalTarget {
                stageCollapsedPane(.terminal, atWidth: terminalTarget, limitedToSplitWidth: true)
            }
        }

        sidebarItem.isCollapsed = sidebarWasCollapsed
        terminalItem.isCollapsed = terminalWasCollapsed
        splitView.layoutSubtreeIfNeeded()

        if !terminalWasCollapsed, let terminalTarget {
            setNativeWidth(terminalTarget, of: .terminal)
        }
        if !sidebarWasCollapsed, let sidebarTarget {
            setNativeWidth(sidebarTarget, of: .sidebar)
        }
    }

    private func splitViewDidResize() {
        guard !isReconcilingPresentation,
              !isReconcilingTerminalFullscreen,
              !isChangingPressureDuringConstraint else { return }

        // A native window-pressure collapse does not alter the user's preferred
        // presentation. Its transient collapsed width is restored when the
        // document minimum and peripheral minimums fit again. A pane the window
        // had already squeezed keeps that cause through a later drag, so the
        // drag cannot bring it back mid-gesture.
        let activeDividerIndex = workspaceSplitView.activeDividerIndex
        let pressureCause: PressureCollapseCause = activeDividerIndex == nil ? .container : .divider
        for pane in SidePane.allCases
        where panes[pane].isPreferred
            && item(for: pane).isCollapsed
            && activeDividerIndex != pane.dividerIndex
            && panes[pane].pressureCollapseCause == nil {
            panes[pane].pressureCollapseCause = pressureCause
        }

        // Effective visibility is useful during live layout, but preference
        // changes are emitted only once native mouse tracking has completed.
        reportPresentationChanges()
        if activeDividerIndex == nil {
            reconcilePresentation(animated: false)
        }
    }

    private func dividerDragDidFinish(
        _ dividerIndex: Int,
        widthBeforeDrag: CGFloat?,
        finalRequestedPosition: CGFloat?
    ) {
        let draggedPane: SidePane = dividerIndex == 0 ? .sidebar : .terminal
        let oppositePane = draggedPane.opposite
        // AppKit can clamp divider tracking at a pane's minimum and leave the
        // pane expanded instead of collapsing it past half its minimum.
        // Reconcile that gesture after AppKit releases tracking.
        if widthBeforeDrag != nil,
           !item(for: draggedPane).isCollapsed,
           let finalRequestedPosition,
           shouldSnapDraggedPaneClosed(draggedPane, at: finalRequestedPosition) {
            let wasReconcilingPresentation = isReconcilingPresentation
            isReconcilingPresentation = true
            setCollapsed(true, for: draggedPane, animated: false)
            isReconcilingPresentation = wasReconcilingPresentation
        }

        if let widthBeforeDrag, item(for: draggedPane).isCollapsed {
            panes[draggedPane].collapsedWidth = widthBeforeDrag
        }

        var userInitiated: Set<SidePane> = []
        let failedPressureReveal = panes[draggedPane].isPreferred
            && item(for: draggedPane).isCollapsed
            && panes[draggedPane].pressureCollapseCause != nil
        if !failedPressureReveal {
            panes[draggedPane].isPreferred = !item(for: draggedPane).isCollapsed
            panes[draggedPane].pressureCollapseCause = nil
            userInitiated.insert(draggedPane)
        }

        // What the user sees when they let go is what stays. An opposite pane that is out of the
        // layout, because this drag pushed it out or the window had squeezed it, is closed, as its
        // toolbar button already shows: it reopens from that button, never because this drag or a
        // later one made room. (A window resize is not a drag; it restores what it squeezed.)
        if item(for: oppositePane).isCollapsed, panes[oppositePane].pressureCollapseCause != nil {
            panes[oppositePane].isPreferred = false
            panes[oppositePane].pressureCollapseCause = nil
            userInitiated.insert(oppositePane)
        }
        reportPresentationChanges(userInitiated: userInitiated, forced: userInitiated)
        reconcilePresentation(animated: false)
    }

    private func shouldSnapDraggedPaneClosed(_ pane: SidePane, at requestedPosition: CGFloat) -> Bool {
        let snapWidth = minimumWidth(of: pane) * WorkspaceSplitMetrics.snapThresholdFraction
        switch pane {
        case .sidebar:
            return requestedPosition < snapWidth
        case .terminal:
            return requestedPosition > availableLayoutWidth - snapWidth - splitView.dividerThickness
        }
    }

    private func changePressureCollapse(_ collapsed: Bool, for pane: SidePane) {
        guard item(for: pane).isCollapsed != collapsed else { return }
        isChangingPressureDuringConstraint = true
        setCollapsed(collapsed, for: pane, animated: false)
        isChangingPressureDuringConstraint = false
        reportPresentationChanges()
    }

    /// Reports each pane's effective visibility to SwiftUI when it changed, or always for a `forced`
    /// pane. `userInitiated` panes changed because the user dragged a divider.
    private func reportPresentationChanges(
        userInitiated: Set<SidePane> = [],
        forced: Set<SidePane> = []
    ) {
        // Pressure and layout callbacks can originate while SwiftUI is inside
        // updateNSViewController. Mutating the caller's @State synchronously in
        // that phase is re-entrant and can be discarded even though our report
        // dedupe has advanced. Deliver those effective-state reports on the next
        // main turn, coalescing repeated native layout notifications and reading
        // the split items again at delivery time. A completed divider drag stays
        // synchronous so its user preference cannot be fed back as stale input.
        for pane in forced {
            panes[pane].needsForcedReport = true
        }
        guard !userInitiated.isEmpty else {
            schedulePresentationReport()
            return
        }
        deliverPresentationChanges(userInitiated: userInitiated)
    }

    private func schedulePresentationReport() {
        guard !isPresentationReportScheduled else { return }
        let needsReport = SidePane.allCases.contains { pane in
            panes[pane].needsForcedReport
                || panes[pane].lastReportedPresentation != !item(for: pane).isCollapsed
        }
        guard needsReport else { return }
        isPresentationReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPresentationReportScheduled = false
                self.deliverPresentationChanges(userInitiated: [])
            }
        }
    }

    private func deliverPresentationChanges(userInitiated: Set<SidePane>) {
        let forced = Set(SidePane.allCases.filter { panes[$0].needsForcedReport })
        panes.sidebar.needsForcedReport = false
        panes.terminal.needsForcedReport = false
        for pane in SidePane.allCases {
            let isPresented = !item(for: pane).isCollapsed
            guard forced.contains(pane) || panes[pane].lastReportedPresentation != isPresented else {
                continue
            }
            panes[pane].lastReportedPresentation = isPresented
            panes[pane].onPresentationChange(isPresented, userInitiated.contains(pane))
        }
    }
}
