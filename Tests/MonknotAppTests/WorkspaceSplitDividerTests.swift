import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitDividerTests: WorkspaceSplitViewTestCase {
    func testNativeDividerHitRectsAreWiderThanTheirDividersAndNeverCoverAScrollBar() throws {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)

        let leftBoundary = splitView.arrangedSubviews[0].frame.maxX
        let rightBoundary = splitView.arrangedSubviews[1].frame.maxX
        let leftHitRect = splitView.hitRect(forDividerAt: 0)
        let rightHitRect = splitView.hitRect(forDividerAt: 1)
        let leftEffectiveRect = controller.splitView(
            splitView,
            effectiveRect: .zero,
            forDrawnRect: NSRect(
                x: leftBoundary,
                y: splitView.bounds.minY,
                width: splitView.dividerThickness,
                height: splitView.bounds.height
            ),
            ofDividerAt: 0
        )
        let rightEffectiveRect = controller.splitView(
            splitView,
            effectiveRect: .zero,
            forDrawnRect: NSRect(
                x: rightBoundary,
                y: splitView.bounds.minY,
                width: splitView.dividerThickness,
                height: splitView.bounds.height
            ),
            ofDividerAt: 1
        )

        XCTAssertGreaterThan(leftHitRect.width, splitView.dividerThickness)
        XCTAssertEqual(leftEffectiveRect, leftHitRect.intersection(splitView.bounds))
        XCTAssertEqual(leftHitRect.minX, leftBoundary, accuracy: 0.001)
        XCTAssertGreaterThan(leftHitRect.maxX, leftBoundary + splitView.dividerThickness)
        XCTAssertTrue(splitView.acceptsFirstMouse(for: nil))
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: leftHitRect.midX, y: leftHitRect.midY)) === splitView
        )

        XCTAssertGreaterThan(rightHitRect.width, splitView.dividerThickness)
        XCTAssertEqual(rightEffectiveRect, rightHitRect.intersection(splitView.bounds))
        XCTAssertEqual(
            rightHitRect.minX,
            rightBoundary,
            accuracy: 0.001,
            "The terminal-side target must not extend over the document's scroll bar, which sits against this divider"
        )
        XCTAssertGreaterThan(rightHitRect.maxX, splitView.arrangedSubviews[2].frame.minX)
        let documentScrollBarStrip = NSPoint(
            x: rightBoundary - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) / 2,
            y: splitView.bounds.midY
        )
        XCTAssertFalse(splitView.hitTest(documentScrollBarStrip) === splitView)
        _ = window
    }

    func testNativeDividerHoverAndActiveStatesFollowPointerTracking() throws {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)
        splitView.updateTrackingAreas()

        XCTAssertTrue(splitView.trackingAreas.contains { trackingArea in
            trackingArea.options.contains(.activeInActiveApp)
                && trackingArea.options.contains(.inVisibleRect)
                && trackingArea.options.contains(.mouseMoved)
        })

        let leftHitRect = splitView.hitRect(forDividerAt: 0)
        let hoverEvent = try XCTUnwrap(mouseEvent(
            type: .mouseMoved,
            location: splitView.convert(
                NSPoint(x: leftHitRect.midX, y: leftHitRect.midY),
                to: nil
            ),
            windowNumber: window.windowNumber
        ))
        splitView.mouseMoved(with: hoverEvent)
        XCTAssertEqual(splitView.hoveredDividerIndex, 0)

        let leaveEvent = try XCTUnwrap(mouseEvent(
            type: .mouseMoved,
            location: splitView.convert(
                NSPoint(x: splitView.bounds.midX, y: splitView.bounds.midY),
                to: nil
            ),
            windowNumber: window.windowNumber
        ))
        splitView.mouseMoved(with: leaveEvent)
        XCTAssertNil(splitView.hoveredDividerIndex)

        let observation = DividerTrackingObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            MainActor.assumeIsolated {
                if splitView?.activeDividerIndex == 0,
                   splitView?.hoveredDividerIndex == 0 {
                    observation.sawActiveAndHoveredDivider = true
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try dragDivider(
            0,
            to: splitView.arrangedSubviews[0].frame.maxX + 24,
            in: splitView,
            window: window
        )

        XCTAssertTrue(observation.sawActiveAndHoveredDivider)
        XCTAssertNil(splitView.activeDividerIndex)
    }

    func testNativeSetPositionChangesBothPeripheralWidths() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)

        let initialSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let sidebarTarget: CGFloat = initialSidebarWidth > 350 ? 300 : 380
        controller.splitView.setPosition(sidebarTarget, ofDividerAt: 0)
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), sidebarTarget, accuracy: 1)
        XCTAssertNotEqual(paneWidth(controller.sidebarItem, in: controller), initialSidebarWidth, accuracy: 1)

        let initialTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        let terminalTarget: CGFloat = initialTerminalWidth > 440 ? 380 : 460
        controller.splitView.setPosition(
            controller.splitView.bounds.width - terminalTarget,
            ofDividerAt: 1
        )
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), terminalTarget, accuracy: 4)
        XCTAssertNotEqual(paneWidth(controller.terminalItem, in: controller), initialTerminalWidth, accuracy: 1)
    }

    func testASidebarDragThatPushesTheTerminalOutClosesItForGood() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(0, to: terminalCollapseThreshold + 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true),
            "The pushed-out terminal closes as the user's own choice"
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)

        for target in [terminalCollapseThreshold - snapEpsilon / 2, terminalCollapseThreshold - 2 * snapEpsilon, 300] {
            try dragDivider(0, to: target, in: controller, window: window)
            layout(window, controller)
            XCTAssertTrue(
                controller.terminalItem.isCollapsed,
                "Narrowing the sidebar again must not reopen the terminal (drag to \(target))"
            )
        }
        XCTAssertFalse(recorder.terminalEvents.contains { $0.isPresented })

        // Its toolbar button still reopens it, and the reveal makes room for it.
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
    }

    func testDraggingTheSidebarNeverOpensAClosedTerminal() throws {
        for width in [CGFloat(940), 1_440] {
            let recorder = PresentationRecorder()
            let controller = makeController(terminalPresented: false, recorder: recorder)
            let window = mount(controller, width: width)
            update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)
            layout(window, controller)
            recorder.terminalEvents.removeAll()

            for target in [CGFloat(420), 200, 600, 60, 300] {
                try dragDivider(0, to: target, in: controller, window: window)
                layout(window, controller)
                // SwiftUI feeds the sidebar's reported state back, as ContentView does.
                update(
                    controller,
                    sidebarPresented: !controller.sidebarItem.isCollapsed,
                    terminalPresented: false,
                    recorder: recorder
                )
                layout(window, controller)
                XCTAssertTrue(controller.terminalItem.isCollapsed, "width \(width), drag to \(target)")
                XCTAssertFalse(controller.preferredTerminalPresentation, "width \(width), drag to \(target)")
                XCTAssertFalse(
                    recorder.terminalEvents.contains { $0.isPresented },
                    "width \(width), drag to \(target): \(recorder.terminalEvents)"
                )
            }
            window.orderOut(nil)
        }
    }

    func testOnePointContainerGrowthPreservesOppositeDividerPressureAndSourceWidth() throws {
        let controller = makeController()
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
                * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let expandedSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let splitWidthBeforeGrowth = controller.splitView.bounds.width

        window.contentViewController = nil
        layoutController(controller, width: splitWidthBeforeGrowth + 1)

        XCTAssertEqual(
            controller.splitView.bounds.width,
            splitWidthBeforeGrowth + 1,
            accuracy: 0.001
        )
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A one-point container resize must not reclassify divider pressure as a restorable container collapse"
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            expandedSidebarWidth,
            accuracy: 1
        )
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertFalse(
            controller.preferredTerminalPresentation,
            "The terminal the sidebar drag pushed out is closed, so container growth cannot reopen it"
        )
    }

    func testNativeSidebarSnapCollapseReportsUserIntentAndOutwardDragRestoresWidth() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(360, ofDividerAt: 0)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.sidebarItem, in: controller)
        recorder.sidebarEvents.removeAll()

        try dragDivider(
            0,
            to: WorkspaceSplitMetrics.sidebarMinimumWidth * 0.4,
            in: controller,
            window: window
        )
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true),
            "A completed native divider gesture must report user intent synchronously at mouse-up"
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(paneView(controller.sidebarItem, in: controller).isHidden)
        XCTAssertFalse(controller.preferredSidebarPresentation)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true)
        )
        normalizeHiddenPaneToMinimum(controller.sidebarItem, in: controller)

        // Mirror SwiftUI feeding the user-visible collapsed preference back
        // into the representable before the next pointer gesture.
        update(controller, sidebarPresented: false, terminalPresented: true, recorder: recorder)

        try dragDivider(0, to: usefulWidth, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            usefulWidth,
            accuracy: controller.splitView.dividerThickness + 1
        )
    }

    func testNativeTerminalSnapCollapseReportsUserIntentAndOutwardDragRestoresWidth() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(sidebarPresented: false, recorder: recorder)
        let window = mount(controller, width: 720)
        let visibleFrame = NSScreen.screens.first?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: visibleFrame.minX - 300, y: visibleFrame.minY))

        controller.splitView.setPosition(controller.splitView.bounds.width - 350, ofDividerAt: 1)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.terminalItem, in: controller)
        recorder.terminalEvents.removeAll()

        try dragDivider(
            1,
            to: controller.splitView.bounds.width - WorkspaceSplitMetrics.terminalMinimumWidth * 0.4,
            in: controller,
            window: window
        )
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true),
            "A completed native divider gesture must report user intent synchronously at mouse-up"
        )
        layout(window, controller)

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(paneView(controller.terminalItem, in: controller).isHidden)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true)
        )
        normalizeHiddenPaneToMinimum(controller.terminalItem, in: controller)

        // Mirror SwiftUI feeding the user-visible collapsed preference back
        // into the representable before the next pointer gesture.
        update(controller, sidebarPresented: false, terminalPresented: false, recorder: recorder)

        try dragDivider(
            1,
            to: controller.splitView.bounds.width - usefulWidth,
            in: controller,
            window: window
        )
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulWidth,
            accuracy: controller.splitView.dividerThickness + 1
        )
    }

    func testMouseUpReconcilesAnUnclampedTerminalSnapAfterNativeTrackingEndsOpen() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(sidebarPresented: false, recorder: recorder)
        let window = mount(controller, width: 720)
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)

        controller.splitView.setPosition(controller.splitView.bounds.width - 350, ofDividerAt: 1)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.terminalItem, in: controller)
        let terminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * controller.layoutScale

        splitView.didFinishDraggingDivider?(
            1,
            usefulWidth,
            splitView.bounds.width - terminalMinimum * 0.6
        )
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)

        recorder.terminalEvents.removeAll()
        splitView.didFinishDraggingDivider?(
            1,
            usefulWidth,
            splitView.bounds.width - terminalMinimum * 0.4
        )

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true)
        )
        normalizeHiddenPaneToMinimum(controller.terminalItem, in: controller)

        update(
            controller,
            sidebarPresented: false,
            terminalPresented: true,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulWidth,
            accuracy: controller.splitView.dividerThickness + 1
        )
    }

    func testATerminalDragThatPushesTheSidebarOutClosesItForGood() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(1, to: sidebarCollapseThreshold - 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertFalse(controller.preferredSidebarPresentation)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true),
            "The pushed-out sidebar closes as the user's own choice"
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        update(controller, sidebarPresented: false, terminalPresented: true, recorder: recorder)

        for target in [sidebarCollapseThreshold + snapEpsilon / 2, sidebarCollapseThreshold + 2 * snapEpsilon] {
            try dragDivider(1, to: target, in: controller, window: window)
            layout(window, controller)
            XCTAssertTrue(
                controller.sidebarItem.isCollapsed,
                "Narrowing the terminal again must not reopen the sidebar (drag to \(target))"
            )
        }
        XCTAssertFalse(recorder.sidebarEvents.contains { $0.isPresented })
    }

    func testScaledOutwardTerminalDragCannotRevealAnUnderMinimumThreePaneLayout() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 1_800)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, 1_800, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let allocatedWidth = controller.splitView.bounds.width

        let attemptedTerminalWidth: CGFloat = 576
        try dragDivider(
            1,
            to: controller.splitView.bounds.width
                - attemptedTerminalWidth
                - controller.splitView.dividerThickness,
            in: controller,
            window: window
        )
        layout(window, controller)

        XCTAssertLessThanOrEqual(
            controller.splitView.bounds.width,
            allocatedWidth + 1,
            "A constrained native drag must never expand the split beyond its controller allocation"
        )
        let scaledSidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * 2
        let scaledDetailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * 2
        let scaledTerminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * 2
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            scaledDetailMinimum - 1
        )
        if !controller.sidebarItem.isCollapsed {
            XCTAssertGreaterThanOrEqual(
                paneWidth(controller.sidebarItem, in: controller),
                scaledSidebarMinimum - 1
            )
        }
        if !controller.terminalItem.isCollapsed {
            XCTAssertGreaterThanOrEqual(
                paneWidth(controller.terminalItem, in: controller),
                scaledTerminalMinimum - 1,
                "An outward drag may reveal the terminal only at its scaled native minimum"
            )
        }
        XCTAssertTrue(
            controller.sidebarItem.isCollapsed || controller.terminalItem.isCollapsed,
            "A 1,800-point split cannot legally show all three panes at their 200% minimums"
        )
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "The lowest-priority terminal must return to its pressure-collapsed state when the reveal cannot fit"
        )
    }

    func testProgrammaticVisibilityChangesAreReportedWithoutBeingMarkedAsUserDrags() async {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 2_000)
        let didReportInitialTruth = await waitForMainQueueCondition {
            recorder.sidebarEvents.last
                == PresentationEvent(isPresented: true, userInitiated: false)
                && recorder.terminalEvents.last
                    == PresentationEvent(isPresented: true, userInitiated: false)
        }
        XCTAssertTrue(didReportInitialTruth)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(controller, sidebarPresented: false, terminalPresented: false, recorder: recorder)
        layout(window, controller)
        let didReportHiddenState = await waitForMainQueueCondition {
            recorder.sidebarEvents.last
                == PresentationEvent(isPresented: false, userInitiated: false)
                && recorder.terminalEvents.last
                    == PresentationEvent(isPresented: false, userInitiated: false)
        }
        XCTAssertTrue(didReportHiddenState)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(recorder.sidebarEvents.last, PresentationEvent(isPresented: false, userInitiated: false))
        XCTAssertEqual(recorder.terminalEvents.last, PresentationEvent(isPresented: false, userInitiated: false))
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)
        let didReportVisibleState = await waitForMainQueueCondition {
            recorder.sidebarEvents.last
                == PresentationEvent(isPresented: true, userInitiated: false)
                && recorder.terminalEvents.last
                    == PresentationEvent(isPresented: true, userInitiated: false)
        }
        XCTAssertTrue(didReportVisibleState)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(recorder.sidebarEvents.last, PresentationEvent(isPresented: true, userInitiated: false))
        XCTAssertEqual(recorder.terminalEvents.last, PresentationEvent(isPresented: true, userInitiated: false))
    }
}
