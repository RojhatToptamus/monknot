import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitPressureTests: WorkspaceSplitViewTestCase {
    func testCollapsedTerminalPaneHasNoVisibleContentResponder() {
        let controller = makeController(terminalPresented: true)
        let window = mount(controller, width: 1_400)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        let terminalResponder = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 28)
        )
        controller.terminalHostingController.view.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        XCTAssertTrue(TerminalFocusRestorer.hasVisibleContentResponder(in: window))

        controller.terminalItem.isCollapsed = true
        layout(window, controller)

        XCTAssertFalse(TerminalFocusRestorer.hasVisibleContentResponder(in: window))
    }

    func testNativeSplitDelegateExposesOnlyOuterPanesAsCollapsible() {
        let controller = makeController()
        _ = controller.view
        let panes = controller.splitView.arrangedSubviews

        XCTAssertEqual(panes.count, 3)
        XCTAssertTrue(controller.splitView(controller.splitView, canCollapseSubview: panes[0]))
        XCTAssertFalse(controller.splitView(controller.splitView, canCollapseSubview: panes[1]))
        XCTAssertTrue(controller.splitView(controller.splitView, canCollapseSubview: panes[2]))
    }

    func testNativeThreePaneOwnerDefinesLegalCollisionPriorities() {
        let controller = makeController()
        _ = controller.view

        XCTAssertTrue(controller.splitView is WorkspaceNativeSplitView)
        XCTAssertTrue(controller.splitView.isVertical)
        XCTAssertEqual(controller.splitView.dividerStyle, .thin)
        XCTAssertEqual(controller.splitViewItems.count, 3)
        XCTAssertEqual(controller.splitView.arrangedSubviews.count, 3)

        let priorities = [
            controller.sidebarItem.holdingPriority,
            controller.detailItem.holdingPriority,
            controller.terminalItem.holdingPriority,
        ]
        XCTAssertTrue(priorities.allSatisfy { $0.rawValue < 490 })
        XCTAssertLessThan(
            controller.detailItem.holdingPriority.rawValue,
            controller.sidebarItem.holdingPriority.rawValue,
            "The center must absorb container growth before AppKit replaces the user's sidebar width"
        )
        XCTAssertLessThan(
            controller.detailItem.holdingPriority.rawValue,
            controller.terminalItem.holdingPriority.rawValue,
            "The center must absorb container growth before AppKit replaces the terminal width"
        )
        XCTAssertGreaterThan(
            controller.sidebarItem.holdingPriority.rawValue,
            controller.terminalItem.holdingPriority.rawValue,
            "The terminal must yield before the sidebar when both peripheral panes compete"
        )

        XCTAssertTrue(controller.sidebarItem.canCollapse)
        XCTAssertFalse(controller.detailItem.canCollapse)
        XCTAssertTrue(controller.terminalItem.canCollapse)
        XCTAssertEqual(controller.sidebarItem.minimumThickness, WorkspaceSplitMetrics.sidebarMinimumWidth)
        XCTAssertEqual(controller.detailItem.minimumThickness, WorkspaceSplitMetrics.detailMinimumWidth)
        XCTAssertEqual(controller.terminalItem.minimumThickness, WorkspaceSplitMetrics.terminalMinimumWidth)
        XCTAssertEqual(controller.sidebarItem.preferredThicknessFraction, NSSplitViewItem.unspecifiedDimension)
        XCTAssertEqual(controller.terminalItem.preferredThicknessFraction, NSSplitViewItem.unspecifiedDimension)
    }

    func testSidebarCollapseReleasesItsSpaceAndRevealRestoresUsefulWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(360, ofDividerAt: 0)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.sidebarItem, in: controller)
        let detailWidthBeforeCollapse = paneWidth(controller.detailItem, in: controller)

        update(controller, sidebarPresented: false, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.splitView(controller.splitView, shouldHideDividerAt: 0)
        )
        XCTAssertTrue(paneView(controller.sidebarItem, in: controller).isHidden)
        let splitView = controller.splitView as! WorkspaceNativeSplitView
        let collapsedHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        XCTAssertEqual(collapsedHitRect.minX, splitView.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(collapsedHitRect.width, splitView.dividerHitWidth, accuracy: 0.001)
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: collapsedHitRect.midX, y: collapsedHitRect.midY)) === splitView
        )
        XCTAssertEqual(paneFrame(controller.detailItem, in: controller).minX, controller.splitView.bounds.minX, accuracy: 1)
        XCTAssertGreaterThan(paneWidth(controller.detailItem, in: controller), detailWidthBeforeCollapse)

        normalizeHiddenPaneToMinimum(controller.sidebarItem, in: controller)
        XCTAssertEqual(
            paneView(controller.sidebarItem, in: controller).bounds.width,
            controller.sidebarItem.minimumThickness,
            accuracy: 0.001,
            "The fixture must emulate macOS 15 discarding the hidden arranged view's useful width"
        )

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulWidth, accuracy: 1)
        let restoredHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        XCTAssertEqual(restoredHitRect.minX, paneFrame(controller.sidebarItem, in: controller).maxX, accuracy: 1)
        XCTAssertGreaterThan(restoredHitRect.minX, splitView.bounds.minX)
    }

    func testTerminalCollapseReleasesItsSpaceAndRevealRestoresUsefulWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.terminalItem, in: controller)
        let detailWidthBeforeCollapse = paneWidth(controller.detailItem, in: controller)

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)
        layout(window, controller)

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(
            controller.splitView(controller.splitView, shouldHideDividerAt: 1)
        )
        XCTAssertTrue(paneView(controller.terminalItem, in: controller).isHidden)
        let splitView = controller.splitView as! WorkspaceNativeSplitView
        let collapsedHitRect = splitView.centerBiasedHitRect(forDividerAt: 1)
        XCTAssertEqual(collapsedHitRect.maxX, splitView.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(collapsedHitRect.width, splitView.dividerHitWidth, accuracy: 0.001)
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: collapsedHitRect.midX, y: collapsedHitRect.midY)) === splitView
        )
        XCTAssertEqual(paneFrame(controller.detailItem, in: controller).maxX, controller.splitView.bounds.maxX, accuracy: 1)
        XCTAssertGreaterThan(paneWidth(controller.detailItem, in: controller), detailWidthBeforeCollapse)

        normalizeHiddenPaneToMinimum(controller.terminalItem, in: controller)
        XCTAssertEqual(
            paneView(controller.terminalItem, in: controller).bounds.width,
            controller.terminalItem.minimumThickness,
            accuracy: 0.001,
            "The fixture must emulate macOS 15 discarding the hidden arranged view's useful width"
        )

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulWidth, accuracy: 1)
        let restoredHitRect = splitView.centerBiasedHitRect(forDividerAt: 1)
        XCTAssertEqual(restoredHitRect.maxX, paneFrame(controller.terminalItem, in: controller).minX, accuracy: 1)
        XCTAssertLessThan(restoredHitRect.maxX, splitView.bounds.maxX)
    }

    func testLeftPressureCannotShrinkTheDocumentBelowItsMinimum() {
        let controller = makeController()
        let window = mount(controller, width: 1_000)

        controller.splitView.setPosition(WorkspaceSplitMetrics.sidebarMaximumWidth, ofDividerAt: 0)
        layout(window, controller)

        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1
        )
    }

    func testRightPressureCannotShrinkTheDocumentBelowItsMinimum() {
        let controller = makeController()
        let window = mount(controller, width: 1_000)

        controller.splitView.setPosition(
            WorkspaceSplitMetrics.sidebarMinimumWidth + WorkspaceSplitMetrics.detailMinimumWidth,
            ofDividerAt: 1
        )
        layout(window, controller)

        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.sidebarItem, in: controller),
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
    }

    func testSamePreferenceUpdateAndResizeDoNotCancelOppositeTerminalPressureCollapse() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            recorder: recorder
        )
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification,
            object: controller.splitView
        )
        controller.viewDidLayout()
        layout(window, controller)

        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A same-preference SwiftUI update and unchanged-bounds layout must preserve opposite-pane drag hysteresis"
        )
        XCTAssertTrue(controller.preferredTerminalPresentation)
    }

    func testTerminalRevealRequestShowsAnEffectivelyHiddenPreferredPane() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testHidingSidebarRestoresTheOppositePressureHiddenTerminal() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: false,
            terminalPresented: true,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(
            controller.terminalItem.isCollapsed,
            "Hiding the dragged source pane must release its pressure collapse on the opposite pane"
        )
        XCTAssertFalse(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
    }

    func testHidingTerminalRestoresTheOppositePressureHiddenSidebar() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            1,
            to: sidebarCollapseThreshold - 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(
            controller.sidebarItem.isCollapsed,
            "Hiding the dragged source pane must release its pressure collapse on the opposite pane"
        )
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertFalse(controller.preferredTerminalPresentation)
    }

    func testSidebarRevealRequestShowsAnEffectivelyHiddenPreferredPane() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            1,
            to: sidebarCollapseThreshold - 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            sidebarRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testInitiallyHiddenNativePanesMountAndRevealWithoutReplacingContainers() {
        let recorder = PresentationRecorder()
        let controller = makeController(
            sidebarPresented: false,
            terminalPresented: false,
            recorder: recorder
        )
        let window = mount(controller, width: 1_600)
        let arrangedSubviews = controller.splitView.arrangedSubviews

        XCTAssertEqual(arrangedSubviews.count, 3)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertEqual(controller.splitView.arrangedSubviews.count, 3)
        XCTAssertTrue(
            zip(controller.splitView.arrangedSubviews, arrangedSubviews).allSatisfy {
                $0.0 === $0.1
            }
        )
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.sidebarItem, in: controller),
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1
        )
    }

    func testContainerBoundsPressureCollapsesTerminalFirstAndRestoresItsNativeWidth() async {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(360, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        // Offscreen NSWindow fitting-size enforcement prevents simulating a
        // below-minimum live resize. Drive the controller's real AppKit frames
        // through the same viewDidLayout seam used by window state changes.
        window.contentViewController = nil
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        let didReportPressureCollapse = await waitForMainQueueCondition {
            recorder.terminalEvents.last
                == PresentationEvent(isPresented: false, userInitiated: false)
        }
        XCTAssertTrue(didReportPressureCollapse)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "Expected terminal pressure collapse at split width \(controller.splitView.bounds.width); pane widths are \(controller.splitView.arrangedSubviews.map { $0.frame.width })"
        )
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: false)
        )

        controller.view.frame = NSRect(x: 0, y: 0, width: 1_600, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        let didReportPressureRestore = await waitForMainQueueCondition {
            recorder.terminalEvents.last
                == PresentationEvent(isPresented: true, userInitiated: false)
        }
        XCTAssertTrue(didReportPressureRestore)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulSidebarWidth, accuracy: 2)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulTerminalWidth, accuracy: 2)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
    }

    func testContainerGrowthWaitsForRetainedTerminalWidthWithoutExpandingTheSidebar() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(440, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertGreaterThan(
            usefulTerminalWidth,
            WorkspaceSplitMetrics.terminalMinimumWidth
        )
        window.contentViewController = nil
        layoutController(controller, width: 900)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let sidebarWidthBeforeRestore = paneWidth(controller.sidebarItem, in: controller)
        XCTAssertGreaterThan(
            sidebarWidthBeforeRestore,
            WorkspaceSplitMetrics.sidebarMinimumWidth
        )

        let minimumOnlyWidth = WorkspaceSplitMetrics.sidebarMinimumWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
            + 2 * controller.splitView.dividerThickness
        layoutController(controller, width: minimumOnlyWidth)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A container resize must not reveal the terminal by discarding its retained useful width"
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidthBeforeRestore,
            accuracy: 2
        )

        let retainedWidthFit = sidebarWidthBeforeRestore
            + WorkspaceSplitMetrics.detailMinimumWidth
            + usefulTerminalWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: retainedWidthFit)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidthBeforeRestore,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulTerminalWidth,
            accuracy: 2
        )
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testContainerGrowthWaitsForBothRetainedWidthsBeforeRestoringBothHiddenPanes() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(360, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 500, ofDividerAt: 1)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertGreaterThan(
            usefulSidebarWidth,
            WorkspaceSplitMetrics.sidebarMinimumWidth
        )
        XCTAssertGreaterThan(
            usefulTerminalWidth,
            WorkspaceSplitMetrics.terminalMinimumWidth
        )
        window.contentViewController = nil
        layoutController(controller, width: 550)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        let minimumOnlyWidth = WorkspaceSplitMetrics.sidebarMinimumWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: minimumOnlyWidth)

        XCTAssertTrue(
            controller.sidebarItem.isCollapsed || controller.terminalItem.isCollapsed,
            "Minimum-only capacity must not discard a retained peripheral width"
        )

        let retainedWidthFit = usefulSidebarWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + usefulTerminalWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: retainedWidthFit)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            usefulSidebarWidth,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulTerminalWidth,
            accuracy: 2
        )
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testProgrammaticPressureCallbackArrivesAfterUpdateWithCurrentNativeTruth() async {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        _ = mount(controller, width: 1_230)
        let didReportInitialTruth = await waitForMainQueueCondition {
            recorder.terminalEvents.last
                == PresentationEvent(isPresented: true, userInitiated: false)
        }
        XCTAssertTrue(didReportInitialTruth)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(
            recorder.terminalEvents.isEmpty,
            "A representable update must return before its non-user callback mutates SwiftUI state"
        )

        let didReportPressureCollapse = await waitForMainQueueCondition {
            recorder.terminalEvents
                == [PresentationEvent(isPresented: false, userInitiated: false)]
        }
        XCTAssertTrue(didReportPressureCollapse)

        XCTAssertEqual(
            recorder.terminalEvents,
            [PresentationEvent(isPresented: false, userInitiated: false)]
        )
    }

    func testDeferredPressureCallbackCoalescesToNativeTruthBeforeDelivery() async {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        _ = mount(controller, width: 1_230)
        let didReportInitialTruth = await waitForMainQueueCondition {
            recorder.terminalEvents.last
                == PresentationEvent(isPresented: true, userInitiated: false)
        }
        XCTAssertTrue(didReportInitialTruth)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(recorder.terminalEvents.isEmpty)

        await drainMainQueue()

        XCTAssertEqual(
            recorder.terminalEvents,
            [],
            "A queued pressure callback must read current native state instead of delivering stale collapse"
        )
    }

    func testLegacyTerminalWidthMigratesOnceIntoTheNativeTerminalItem() {
        let legacyTerminalWidth: CGFloat = 470
        withIsolatedLegacyMigrationDefaults(terminalWidth: legacyTerminalWidth) { defaults in
            let controller = makeController(migratesLegacyLayout: true)
            let window = mount(controller, width: 1_600)
            controller.viewDidLayout()
            layout(window, controller)

            XCTAssertEqual(
                paneWidth(controller.terminalItem, in: controller),
                legacyTerminalWidth,
                accuracy: 1
            )
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))
            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))
        }
    }
}
