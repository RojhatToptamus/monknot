import AppKit
import SwiftUI

/// The native owner of Monknot's sidebar, document area, and terminal layout.
///
/// AppKit owns pane geometry, divider dragging, collapse state, and persisted
/// divider positions. The SwiftUI layer supplies only preferred visibility;
/// callbacks report the effective visibility when window pressure differs.
struct WorkspaceSplitView<Sidebar: View, Detail: View, Terminal: View>: NSViewControllerRepresentable {
    let isSidebarPresented: Bool
    let isTerminalPresented: Bool
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
    var didFinishDraggingDivider: ((Int, CGFloat?) -> Void)?

    private(set) var hoveredDividerIndex: Int?
    private(set) var activeDividerIndex: Int?
    private var pointerTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override var dividerThickness: CGFloat { WorkspaceSplitMetrics.dividerThickness }

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
        for index in dividerIndices {
            addCursorRect(centerBiasedHitRect(forDividerAt: index), cursor: horizontalResizeCursor)
        }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
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
        let widthBeforeDrag: CGFloat?
        if arrangedSubviews.indices.contains(outerPaneIndex),
           !arrangedSubviews[outerPaneIndex].isHidden {
            widthBeforeDrag = arrangedSubviews[outerPaneIndex].frame.width
        } else {
            widthBeforeDrag = nil
        }
        defer {
            activeDividerIndex = nil
            if let window {
                let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                setHoveredDivider(self.dividerIndex(containing: pointer))
            } else {
                setHoveredDivider(nil)
            }
            needsDisplay = true
            didFinishDraggingDivider?(dividerIndex, widthBeforeDrag)
        }
        super.mouseDown(with: event)
    }

    func centerBiasedHitRect(forDividerAt index: Int) -> NSRect {
        guard dividerIndices.contains(index) else { return .zero }
        let drawnRect = dividerRect(at: index)
        let extraWidth = max(0, dividerHitWidth - drawnRect.width)

        // Both targets grow into the document area. This keeps them clear of
        // the sidebar and terminal scrollbars at their outer pane edges.
        if index == 0 {
            return NSRect(
                x: drawnRect.minX,
                y: bounds.minY,
                width: drawnRect.width + extraWidth,
                height: bounds.height
            )
        }
        return NSRect(
            x: drawnRect.minX - extraWidth,
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
        dividerIndices.first { centerBiasedHitRect(forDividerAt: $0).contains(point) }
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

@MainActor
final class WorkspaceSplitViewController<Sidebar: View, Detail: View, Terminal: View>: NSSplitViewController {
    private enum PressureCollapseCause {
        case divider
        case container
    }

    let sidebarHostingController: NSHostingController<Sidebar>
    let detailHostingController: NSHostingController<Detail>
    let terminalHostingController: NSHostingController<Terminal>
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    let terminalItem: NSSplitViewItem

    private(set) var preferredSidebarPresentation: Bool
    private(set) var preferredTerminalPresentation: Bool
    private(set) var layoutScale: CGFloat

    private var onSidebarPresentationChange: (Bool, Bool) -> Void
    private var onTerminalPresentationChange: (Bool, Bool) -> Void
    private var sidebarRevealRequest: UInt
    private var terminalRevealRequest: UInt
    private var sidebarPressureCollapseCause: PressureCollapseCause?
    private var terminalPressureCollapseCause: PressureCollapseCause?
    private var lastReportedSidebarPresentation: Bool?
    private var lastReportedTerminalPresentation: Bool?
    private var isPresentationReportScheduled = false
    private var pendingForceSidebarPresentationReport = false
    private var pendingForceTerminalPresentationReport = false
    private var splitViewResizeObserver: NSObjectProtocol?
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var terminalCollapseObservation: NSKeyValueObservation?
    // macOS 15 can normalize a hidden arranged view to its minimum width.
    // Each value exists only while its pane is collapsed; visible geometry
    // remains owned exclusively by NSSplitView.
    private var collapsedSidebarWidth: CGFloat?
    private var collapsedTerminalWidth: CGFloat?
    private var isReconcilingPresentation = false
    private var isChangingPressureDuringConstraint = false
    private let migratesLegacyLayout: Bool
    private let workspaceSplitView: WorkspaceNativeSplitView

    init(
        sidebar: Sidebar,
        detail: Detail,
        terminal: Terminal,
        isSidebarPresented: Bool,
        isTerminalPresented: Bool,
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
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        detailItem = NSSplitViewItem(viewController: detailHostingController)
        terminalItem = NSSplitViewItem(inspectorWithViewController: terminalHostingController)
        preferredSidebarPresentation = isSidebarPresented
        preferredTerminalPresentation = isTerminalPresented
        self.layoutScale = WorkspaceSplitMetrics.normalizedScale(layoutScale)
        self.onSidebarPresentationChange = onSidebarPresentationChange
        self.onTerminalPresentationChange = onTerminalPresentationChange
        self.sidebarRevealRequest = sidebarRevealRequest
        self.terminalRevealRequest = terminalRevealRequest
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

        sidebarCollapseObservation = observeCollapseChanges(for: sidebarItem)
        terminalCollapseObservation = observeCollapseChanges(for: terminalItem)

        workspaceSplitView.didFinishDraggingDivider = { [weak self] dividerIndex, widthBeforeDrag in
            self?.dividerDragDidFinish(dividerIndex, widthBeforeDrag: widthBeforeDrag)
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

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let systemRect = super.splitView(
            splitView,
            effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect,
            ofDividerAt: dividerIndex
        )
        guard let workspaceSplitView = splitView as? WorkspaceNativeSplitView else {
            return systemRect
        }
        let centerBiasedRect = workspaceSplitView.centerBiasedHitRect(forDividerAt: dividerIndex)
        let verticalRect = systemRect.isEmpty ? splitView.bounds : systemRect
        return NSRect(
            x: centerBiasedRect.minX,
            y: verticalRect.minY,
            width: centerBiasedRect.width,
            height: verticalRect.height
        ).intersection(splitView.bounds)
    }

    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        let systemRect = super.splitView(
            splitView,
            additionalEffectiveRectOfDividerAt: dividerIndex
        )
        let isCollapsedEdge = (dividerIndex == 0 && sidebarItem.isCollapsed)
            || (dividerIndex == 1 && terminalItem.isCollapsed)
        guard isCollapsedEdge,
              let workspaceSplitView = splitView as? WorkspaceNativeSplitView else {
            return systemRect
        }

        // AppKit hides a collapsed outer divider so it occupies exactly zero
        // layout width. Its additive effective rect keeps that native divider
        // reachable at the window edge without reintroducing a visible gutter.
        return workspaceSplitView.centerBiasedHitRect(forDividerAt: dividerIndex)
    }

    override func splitView(
        _ splitView: NSSplitView,
        shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        let systemShouldHideDivider = super.splitView(
            splitView,
            shouldHideDividerAt: dividerIndex
        )
        let isCollapsedOuterDivider = (dividerIndex == 0 && sidebarItem.isCollapsed)
            || (dividerIndex == 1 && terminalItem.isCollapsed)
        return systemShouldHideDivider || isCollapsedOuterDivider
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
        let sidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale
        let sidebarMaximum = WorkspaceSplitMetrics.sidebarMaximumWidth * layoutScale
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale
        let terminalMaximum = WorkspaceSplitMetrics.terminalMaximumWidth * layoutScale
        let snapEpsilon = max(1, layoutScale)
        let availableWidth = availableLayoutWidth

        if dividerIndex == 0 {
            if sidebarItem.isCollapsed {
                guard proposedPosition >= sidebarMinimum else { return 0 }
                setCollapsed(false, for: sidebarItem, animated: false)
            } else if proposedPosition
                < sidebarMinimum * WorkspaceSplitMetrics.snapThresholdFraction {
                setCollapsed(true, for: sidebarItem, animated: false)
                return 0
            }

            let maximumSidebarWithBothPeripherals = availableWidth
                - (2 * dividerWidth)
                - detailMinimum
                - terminalMinimum
            let terminalCollapseThreshold = maximumSidebarWithBothPeripherals
                + terminalMinimum * WorkspaceSplitMetrics.snapThresholdFraction

            if terminalPressureCollapseCause == .divider,
               terminalItem.isCollapsed,
               proposedPosition < terminalCollapseThreshold - snapEpsilon {
                changePressureCollapse(false, for: terminalItem)
                terminalPressureCollapseCause = nil
            } else if preferredTerminalPresentation,
                      !terminalItem.isCollapsed,
                      maximumSidebarWithBothPeripherals < sidebarMaximum,
                      proposedPosition > terminalCollapseThreshold {
                terminalPressureCollapseCause = .divider
                changePressureCollapse(true, for: terminalItem)
            }
        } else if dividerIndex == 1 {
            let maximumDividerForTerminalMinimum = availableWidth
                - terminalMinimum
                - dividerWidth
            if terminalItem.isCollapsed {
                guard proposedPosition <= maximumDividerForTerminalMinimum else {
                    return availableWidth - dividerWidth
                }
                setCollapsed(false, for: terminalItem, animated: false)
            } else if proposedPosition > availableWidth
                - terminalMinimum * WorkspaceSplitMetrics.snapThresholdFraction
                - dividerWidth {
                setCollapsed(true, for: terminalItem, animated: false)
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

            if sidebarPressureCollapseCause == .divider,
               sidebarItem.isCollapsed,
               proposedPosition > sidebarCollapseThreshold + snapEpsilon {
                changePressureCollapse(false, for: sidebarItem)
                sidebarPressureCollapseCause = nil
            } else if preferredSidebarPresentation,
                      !sidebarItem.isCollapsed,
                      maximumTerminalWithBothPeripherals < terminalMaximum,
                      proposedPosition < sidebarCollapseThreshold {
                sidebarPressureCollapseCause = .divider
                changePressureCollapse(true, for: sidebarItem)
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
        let requestsSidebarReveal = self.sidebarRevealRequest != sidebarRevealRequest
        let requestsTerminalReveal = self.terminalRevealRequest != terminalRevealRequest
        preferredSidebarPresentation = isSidebarPresented
        preferredTerminalPresentation = isTerminalPresented
        self.sidebarRevealRequest = sidebarRevealRequest
        self.terminalRevealRequest = terminalRevealRequest
        self.onSidebarPresentationChange = onSidebarPresentationChange
        self.onTerminalPresentationChange = onTerminalPresentationChange
        workspaceSplitView.separatorColor = separatorColor
        workspaceSplitView.accentColor = accentColor

        let normalizedScale = WorkspaceSplitMetrics.normalizedScale(layoutScale)
        if self.layoutScale != normalizedScale {
            let previousScale = self.layoutScale
            let sidebarWidth = restorableWidthIfAvailable(for: sidebarItem)
            let terminalWidth = restorableWidthIfAvailable(for: terminalItem)
            applyLayoutScaleChange(
                to: normalizedScale,
                sidebarWidth: sidebarWidth,
                terminalWidth: terminalWidth,
                ratio: normalizedScale / previousScale,
                availableWidth: availableLayoutWidth
            )
        }
        if !isSidebarPresented {
            sidebarPressureCollapseCause = nil
            if workspaceSplitView.activeDividerIndex == nil,
               terminalPressureCollapseCause == .divider {
                terminalPressureCollapseCause = nil
            }
        }
        if !isTerminalPresented {
            terminalPressureCollapseCause = nil
            if workspaceSplitView.activeDividerIndex == nil,
               sidebarPressureCollapseCause == .divider {
                sidebarPressureCollapseCause = nil
            }
        }
        if requestsSidebarReveal, isSidebarPresented {
            sidebarPressureCollapseCause = nil
        }
        if requestsTerminalReveal, isTerminalPresented {
            terminalPressureCollapseCause = nil
        }
        reconcilePresentation(animated: animated)
        if requestsSidebarReveal, isSidebarPresented, sidebarItem.isCollapsed {
            reportPresentationChanges(
                userInitiatedSidebar: false,
                userInitiatedTerminal: false,
                forceSidebar: true
            )
        }
        if requestsTerminalReveal, isTerminalPresented, terminalItem.isCollapsed {
            reportPresentationChanges(
                userInitiatedSidebar: false,
                userInitiatedTerminal: false,
                forceTerminal: true
            )
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
        sidebarItem.isSpringLoaded = false

        detailItem.minimumThickness = WorkspaceSplitMetrics.detailMinimumWidth * scale
        detailItem.holdingPriority = WorkspaceSplitMetrics.detailHoldingPriority
        detailItem.canCollapse = false

        terminalItem.minimumThickness = WorkspaceSplitMetrics.terminalMinimumWidth * scale
        terminalItem.maximumThickness = WorkspaceSplitMetrics.terminalMaximumWidth * scale
        terminalItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        terminalItem.holdingPriority = WorkspaceSplitMetrics.terminalHoldingPriority
        terminalItem.canCollapse = true
        terminalItem.canCollapseFromWindowResize = true
        terminalItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        terminalItem.isSpringLoaded = false

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
        if !preferredSidebarPresentation {
            sidebarPressureCollapseCause = nil
            setCollapsed(true, for: sidebarItem, animated: false)
        }
        if !preferredTerminalPresentation {
            terminalPressureCollapseCause = nil
            setCollapsed(true, for: terminalItem, animated: false)
        }
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

    private func collapsePanesThatCannotFit(
        at scale: CGFloat,
        availableWidth: CGFloat
    ) {
        guard availableWidth > 0 else { return }

        let dividerWidth = splitView.dividerThickness
        let sidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * scale
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * scale
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * scale

        func requiredMinimumWidth(sidebar: Bool, terminal: Bool) -> CGFloat {
            detailMinimum
                + (sidebar ? sidebarMinimum + dividerWidth : 0)
                + (terminal ? terminalMinimum + dividerWidth : 0)
        }

        if preferredTerminalPresentation,
           requiredMinimumWidth(
               sidebar: preferredSidebarPresentation,
               terminal: true
           ) > availableWidth {
            terminalPressureCollapseCause = .container
            setCollapsed(true, for: terminalItem, animated: false)
        }
        if preferredSidebarPresentation,
           requiredMinimumWidth(sidebar: true, terminal: false) > availableWidth {
            sidebarPressureCollapseCause = .container
            setCollapsed(true, for: sidebarItem, animated: false)
        }
    }

    /// Imports the former two-pane sidebar autosave and the former public
    /// terminal-width preference once. AppKit reads its own legacy autosave;
    /// Monknot does not inspect or copy NSSplitView's private defaults keys.
    private func migrateLegacyLayoutIfNeeded() {
        guard migratesLegacyLayout,
              availableLayoutWidth > 0,
              !UserDefaults.standard.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey) else {
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
        let sidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale
        let sidebarMaximum = WorkspaceSplitMetrics.sidebarMaximumWidth * layoutScale
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale
        let terminalMaximum = WorkspaceSplitMetrics.terminalMaximumWidth * layoutScale
        let legacySidebarWidth = readLegacySidebarWidth(availableWidth: availableWidth)
        let sidebarWidth = min(
            sidebarMaximum,
            max(sidebarMinimum, legacySidebarWidth)
        )
        let terminalWidth = min(
            terminalMaximum,
            max(terminalMinimum, CGFloat(legacyTerminalWidth))
        )
        let stagingWidth = max(
            availableWidth,
            detailMinimum + dividerWidth + max(sidebarWidth, terminalWidth)
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
        sidebarItem.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        sidebarItem.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()

        terminalItem.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(
            splitView.bounds.width - terminalWidth - dividerWidth,
            ofDividerAt: 1
        )
        splitView.layoutSubtreeIfNeeded()
        terminalItem.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()

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
            reportPresentationChanges(userInitiatedSidebar: false, userInitiatedTerminal: false)
        }

        if !preferredSidebarPresentation {
            sidebarPressureCollapseCause = nil
            setCollapsed(true, for: sidebarItem, animated: animated)
        }
        if !preferredTerminalPresentation {
            terminalPressureCollapseCause = nil
            setCollapsed(true, for: terminalItem, animated: animated)
        }

        collapsePanesThatCannotFit(
            at: layoutScale,
            availableWidth: availableLayoutWidth
        )

        let sidebarCollapseCause = sidebarPressureCollapseCause
        if preferredSidebarPresentation,
           sidebarItem.isCollapsed,
           canRestoreSidebar(
               preservingSidebarWidth: sidebarCollapseCause == .container,
               preservingTerminalWidth: sidebarCollapseCause == .divider
                   || sidebarCollapseCause == .container
           ) {
            setCollapsed(false, for: sidebarItem, animated: animated)
            sidebarPressureCollapseCause = nil
            splitView.layoutSubtreeIfNeeded()
        }

        let terminalCollapseCause = terminalPressureCollapseCause
        if preferredTerminalPresentation,
           terminalItem.isCollapsed,
           canRestoreTerminal(
               preservingSidebarWidth: terminalCollapseCause == .divider
                   || terminalCollapseCause == .container,
               preservingTerminalWidth: terminalCollapseCause == .container
           ) {
            setCollapsed(false, for: terminalItem, animated: animated)
            terminalPressureCollapseCause = nil
        }
    }

    private func canRestoreSidebar(
        preservingSidebarWidth: Bool,
        preservingTerminalWidth: Bool
    ) -> Bool {
        let dividerWidth = splitView.dividerThickness
        let sidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale
        let sidebarMaximum = WorkspaceSplitMetrics.sidebarMaximumWidth * layoutScale
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
        let sidebarWidth = preservingSidebarWidth
            ? min(sidebarMaximum, max(sidebarMinimum, restorableWidth(for: sidebarItem)))
            : sidebarMinimum
        let terminalWidth = terminalItem.isCollapsed
            ? 0
            : (preservingTerminalWidth
                ? max(
                    WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale,
                    splitView.arrangedSubviews[2].frame.width
                )
                : WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale) + dividerWidth
        return sidebarWidth + dividerWidth + detailMinimum + terminalWidth
            <= availableLayoutWidth
    }

    private func canRestoreTerminal(
        preservingSidebarWidth: Bool,
        preservingTerminalWidth: Bool
    ) -> Bool {
        let dividerWidth = splitView.dividerThickness
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale
        let terminalMaximum = WorkspaceSplitMetrics.terminalMaximumWidth * layoutScale
        let sidebarWidth = sidebarItem.isCollapsed
            ? 0
            : (preservingSidebarWidth
                ? max(
                    WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale,
                    splitView.arrangedSubviews[0].frame.width
                )
                : WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale) + dividerWidth
        let terminalWidth = preservingTerminalWidth
            ? min(terminalMaximum, max(terminalMinimum, restorableWidth(for: terminalItem)))
            : terminalMinimum
        return sidebarWidth + detailMinimum + terminalWidth + dividerWidth
            <= availableLayoutWidth
    }

    private func observeCollapseChanges(
        for item: NSSplitViewItem
    ) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: [.prior]) { [weak self] item, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                if change.isPrior {
                    self.captureWidthBeforeCollapse(for: item)
                } else if !item.isCollapsed {
                    self.restoreCollapsedWidthIfNeeded(for: item)
                }
            }
        }
    }

    private func captureWidthBeforeCollapse(for item: NSSplitViewItem) {
        guard !item.isCollapsed, collapsedWidth(for: item) == nil else { return }
        let width = nativePaneWidth(for: item)
        guard width.isFinite, width > 0 else { return }
        setCollapsedWidth(width, for: item)
    }

    private func restoreCollapsedWidthIfNeeded(for item: NSSplitViewItem) {
        let isOppositePressureRevealDuringDrag: Bool
        if item === sidebarItem {
            isOppositePressureRevealDuringDrag = workspaceSplitView.activeDividerIndex == 1
                && sidebarPressureCollapseCause != nil
        } else {
            isOppositePressureRevealDuringDrag = workspaceSplitView.activeDividerIndex == 0
                && terminalPressureCollapseCause != nil
        }
        if isOppositePressureRevealDuringDrag,
           !isChangingPressureDuringConstraint {
            item.isCollapsed = true
            return
        }

        guard let width = collapsedWidth(for: item) else { return }
        setCollapsedWidth(nil, for: item)
        splitView.layoutSubtreeIfNeeded()
        restoreNativeRetainedWidth(width, for: item)
    }

    private func collapsedWidth(for item: NSSplitViewItem) -> CGFloat? {
        item === sidebarItem ? collapsedSidebarWidth : collapsedTerminalWidth
    }

    private func setCollapsedWidth(_ width: CGFloat?, for item: NSSplitViewItem) {
        if item === sidebarItem {
            collapsedSidebarWidth = width
        } else {
            collapsedTerminalWidth = width
        }
    }

    private func setCollapsed(_ collapsed: Bool, for item: NSSplitViewItem, animated: Bool) {
        guard item.isCollapsed != collapsed else { return }
        if !collapsed {
            item.isCollapsed = false
            splitView.layoutSubtreeIfNeeded()
            return
        }
        guard animated, view.window != nil else {
            item.isCollapsed = collapsed
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotMotion.sidebarTransitionDuration
            item.animator().isCollapsed = collapsed
        }
    }

    private func restorableWidth(for item: NSSplitViewItem) -> CGFloat {
        if item.isCollapsed, let collapsedWidth = collapsedWidth(for: item) {
            return collapsedWidth
        }
        return nativePaneWidth(for: item)
    }

    private func restorableWidthIfAvailable(for item: NSSplitViewItem) -> CGFloat? {
        if item.isCollapsed, let collapsedWidth = collapsedWidth(for: item) {
            return collapsedWidth
        }
        let width = nativePaneWidth(for: item)
        guard width.isFinite, width > 0 else { return nil }
        return width
    }

    private func nativePaneWidth(for item: NSSplitViewItem) -> CGFloat {
        let index = item === sidebarItem ? 0 : 2
        guard splitView.arrangedSubviews.indices.contains(index) else { return 0 }
        return splitView.arrangedSubviews[index].frame.width
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

        let sidebarTarget = sidebarWidth.map {
            min(
                WorkspaceSplitMetrics.sidebarMaximumWidth * layoutScale,
                max(WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale, $0 * ratio)
            )
        }
        let terminalTarget = terminalWidth.map {
            min(
                WorkspaceSplitMetrics.terminalMaximumWidth * layoutScale,
                max(WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale, $0 * ratio)
            )
        }
        guard sidebarTarget != nil || terminalTarget != nil else { return }

        let sidebarWasCollapsed = sidebarItem.isCollapsed
        let terminalWasCollapsed = terminalItem.isCollapsed
        let dividerWidth = splitView.dividerThickness

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
                sidebarItem.isCollapsed = false
                splitView.layoutSubtreeIfNeeded()
                splitView.setPosition(
                    min(sidebarTarget, splitView.bounds.width - dividerWidth),
                    ofDividerAt: 0
                )
                splitView.layoutSubtreeIfNeeded()
                sidebarItem.isCollapsed = true
                splitView.layoutSubtreeIfNeeded()
            }
            if terminalWasCollapsed, let terminalTarget {
                terminalItem.isCollapsed = false
                splitView.layoutSubtreeIfNeeded()
                let stagedTerminalWidth = min(
                    terminalTarget,
                    splitView.bounds.width - dividerWidth
                )
                splitView.setPosition(
                    splitView.bounds.width - stagedTerminalWidth - dividerWidth,
                    ofDividerAt: 1
                )
                splitView.layoutSubtreeIfNeeded()
                terminalItem.isCollapsed = true
                splitView.layoutSubtreeIfNeeded()
            }
        }

        sidebarItem.isCollapsed = sidebarWasCollapsed
        terminalItem.isCollapsed = terminalWasCollapsed
        splitView.layoutSubtreeIfNeeded()

        if !terminalWasCollapsed, let terminalTarget {
            splitView.setPosition(
                splitView.bounds.width - terminalTarget - dividerWidth,
                ofDividerAt: 1
            )
            splitView.layoutSubtreeIfNeeded()
        }
        if !sidebarWasCollapsed, let sidebarTarget {
            splitView.setPosition(sidebarTarget, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
    }

    private func restoreNativeRetainedWidth(_ retainedWidth: CGFloat, for item: NSSplitViewItem) {
        let dividerWidth = splitView.dividerThickness
        let detailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * layoutScale
        let availableWidth = availableLayoutWidth

        if item === sidebarItem {
            let terminalContribution = terminalItem.isCollapsed
                ? 0
                : max(
                    WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale,
                    splitView.arrangedSubviews[2].frame.width
                ) + dividerWidth
            let maximumAvailable = availableWidth
                - detailMinimum
                - terminalContribution
                - dividerWidth
            let targetWidth = min(
                WorkspaceSplitMetrics.sidebarMaximumWidth * layoutScale,
                max(
                    WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale,
                    min(retainedWidth, maximumAvailable)
                )
            )
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        } else {
            let sidebarContribution = sidebarItem.isCollapsed
                ? 0
                : max(
                    WorkspaceSplitMetrics.sidebarMinimumWidth * layoutScale,
                    splitView.arrangedSubviews[0].frame.width
                ) + dividerWidth
            let maximumAvailable = availableWidth
                - detailMinimum
                - sidebarContribution
                - dividerWidth
            let targetWidth = min(
                WorkspaceSplitMetrics.terminalMaximumWidth * layoutScale,
                max(
                    WorkspaceSplitMetrics.terminalMinimumWidth * layoutScale,
                    min(retainedWidth, maximumAvailable)
                )
            )
            splitView.setPosition(
                splitView.bounds.width - targetWidth - dividerWidth,
                ofDividerAt: 1
            )
        }
        splitView.layoutSubtreeIfNeeded()
    }

    private func splitViewDidResize() {
        guard !isReconcilingPresentation, !isChangingPressureDuringConstraint else { return }

        // A native window-pressure collapse does not alter the user's preferred
        // presentation. Its transient collapsed width is restored when the
        // document minimum and peripheral minimums fit again.
        if preferredSidebarPresentation,
           sidebarItem.isCollapsed,
           workspaceSplitView.activeDividerIndex != 0 {
            if workspaceSplitView.activeDividerIndex != nil {
                sidebarPressureCollapseCause = .divider
            } else if sidebarPressureCollapseCause == nil {
                sidebarPressureCollapseCause = .container
            }
        }
        if preferredTerminalPresentation,
           terminalItem.isCollapsed,
           workspaceSplitView.activeDividerIndex != 1 {
            if workspaceSplitView.activeDividerIndex != nil {
                terminalPressureCollapseCause = .divider
            } else if terminalPressureCollapseCause == nil {
                terminalPressureCollapseCause = .container
            }
        }

        // Effective visibility is useful during live layout, but preference
        // changes are emitted only once native mouse tracking has completed.
        reportPresentationChanges(userInitiatedSidebar: false, userInitiatedTerminal: false)
        if workspaceSplitView.activeDividerIndex == nil {
            reconcilePresentation(animated: false)
        }
    }

    private func dividerDragDidFinish(_ dividerIndex: Int, widthBeforeDrag: CGFloat?) {
        if let widthBeforeDrag {
            let draggedItem = dividerIndex == 0 ? sidebarItem : terminalItem
            if draggedItem.isCollapsed {
                setCollapsedWidth(widthBeforeDrag, for: draggedItem)
            }
        }

        var userInitiatedSidebar = false
        var userInitiatedTerminal = false
        if dividerIndex == 0 {
            let failedPressureReveal = preferredSidebarPresentation
                && sidebarItem.isCollapsed
                && sidebarPressureCollapseCause != nil
            if !failedPressureReveal {
                preferredSidebarPresentation = !sidebarItem.isCollapsed
                sidebarPressureCollapseCause = nil
                userInitiatedSidebar = true
            }
        }
        if dividerIndex == 1 {
            let failedPressureReveal = preferredTerminalPresentation
                && terminalItem.isCollapsed
                && terminalPressureCollapseCause != nil
            if !failedPressureReveal {
                preferredTerminalPresentation = !terminalItem.isCollapsed
                terminalPressureCollapseCause = nil
                userInitiatedTerminal = true
            }
        }
        reportPresentationChanges(
            userInitiatedSidebar: userInitiatedSidebar,
            userInitiatedTerminal: userInitiatedTerminal,
            forceSidebar: userInitiatedSidebar,
            forceTerminal: userInitiatedTerminal
        )
        reconcilePresentation(animated: false)
    }

    private func changePressureCollapse(_ collapsed: Bool, for item: NSSplitViewItem) {
        guard item.isCollapsed != collapsed else { return }
        isChangingPressureDuringConstraint = true
        setCollapsed(collapsed, for: item, animated: false)
        isChangingPressureDuringConstraint = false
        reportPresentationChanges(userInitiatedSidebar: false, userInitiatedTerminal: false)
    }

    private func reportPresentationChanges(
        userInitiatedSidebar: Bool,
        userInitiatedTerminal: Bool,
        forceSidebar: Bool = false,
        forceTerminal: Bool = false
    ) {
        // Pressure and layout callbacks can originate while SwiftUI is inside
        // updateNSViewController. Mutating the caller's @State synchronously in
        // that phase is re-entrant and can be discarded even though our report
        // dedupe has advanced. Deliver those effective-state reports on the next
        // main turn, coalescing repeated native layout notifications and reading
        // the split items again at delivery time. A completed divider drag stays
        // synchronous so its user preference cannot be fed back as stale input.
        guard userInitiatedSidebar || userInitiatedTerminal else {
            pendingForceSidebarPresentationReport =
                pendingForceSidebarPresentationReport || forceSidebar
            pendingForceTerminalPresentationReport =
                pendingForceTerminalPresentationReport || forceTerminal
            schedulePresentationReport()
            return
        }

        let effectiveForceSidebar = forceSidebar || pendingForceSidebarPresentationReport
        let effectiveForceTerminal = forceTerminal || pendingForceTerminalPresentationReport
        pendingForceSidebarPresentationReport = false
        pendingForceTerminalPresentationReport = false
        deliverPresentationChanges(
            userInitiatedSidebar: userInitiatedSidebar,
            userInitiatedTerminal: userInitiatedTerminal,
            forceSidebar: effectiveForceSidebar,
            forceTerminal: effectiveForceTerminal
        )
    }

    private func schedulePresentationReport() {
        guard !isPresentationReportScheduled else { return }
        let sidebarIsPresented = !sidebarItem.isCollapsed
        let terminalIsPresented = !terminalItem.isCollapsed
        let needsReport = pendingForceSidebarPresentationReport
            || pendingForceTerminalPresentationReport
            || lastReportedSidebarPresentation != sidebarIsPresented
            || lastReportedTerminalPresentation != terminalIsPresented
        guard needsReport else { return }
        isPresentationReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.deliverScheduledPresentationReport()
            }
        }
    }

    private func deliverScheduledPresentationReport() {
        isPresentationReportScheduled = false
        let forceSidebar = pendingForceSidebarPresentationReport
        let forceTerminal = pendingForceTerminalPresentationReport
        pendingForceSidebarPresentationReport = false
        pendingForceTerminalPresentationReport = false
        deliverPresentationChanges(
            userInitiatedSidebar: false,
            userInitiatedTerminal: false,
            forceSidebar: forceSidebar,
            forceTerminal: forceTerminal
        )
    }

    private func deliverPresentationChanges(
        userInitiatedSidebar: Bool,
        userInitiatedTerminal: Bool,
        forceSidebar: Bool,
        forceTerminal: Bool
    ) {
        let sidebarIsPresented = !sidebarItem.isCollapsed
        if forceSidebar || lastReportedSidebarPresentation != sidebarIsPresented {
            lastReportedSidebarPresentation = sidebarIsPresented
            onSidebarPresentationChange(sidebarIsPresented, userInitiatedSidebar)
        }

        let terminalIsPresented = !terminalItem.isCollapsed
        if forceTerminal || lastReportedTerminalPresentation != terminalIsPresented {
            lastReportedTerminalPresentation = terminalIsPresented
            onTerminalPresentationChange(terminalIsPresented, userInitiatedTerminal)
        }
    }
}
