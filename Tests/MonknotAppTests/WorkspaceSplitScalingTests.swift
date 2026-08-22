import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitScalingTests: WorkspaceSplitViewTestCase {
    func testSplitLayoutScaleNormalizationUsesWorkspaceZoomPolicyForAllNumericInputs() {
        let inputs: [CGFloat] = [0.25, 1.35, 4, .infinity, -.infinity, .nan]

        for input in inputs {
            XCTAssertEqual(
                WorkspaceSplitMetrics.normalizedScale(input),
                CGFloat(WorkspaceZoomPolicy.clamp(Double(input))),
                accuracy: 0.000_1,
                "Split layout normalization must share the authoritative workspace zoom policy for \(input)"
            )
        }
    }

    func testZoomUpdatesNativeConstraintsWithoutReplacingSplitItemsOrVisibilityPreferences() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 2_200)
        let sidebarItem = controller.sidebarItem
        let detailItem = controller.detailItem
        let terminalItem = controller.terminalItem
        controller.splitView.setPosition(
            controller.splitView.bounds.width - 360 - controller.splitView.dividerThickness,
            ofDividerAt: 1
        )
        layout(window, controller)
        controller.splitView.setPosition(300, ofDividerAt: 0)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertEqual(usefulSidebarWidth, 300, accuracy: 2)
        XCTAssertGreaterThan(usefulTerminalWidth, WorkspaceSplitMetrics.terminalMinimumWidth)
        let scaledSidebarWidth = min(
            WorkspaceSplitMetrics.sidebarMaximumWidth * 1.5,
            usefulSidebarWidth * 1.5
        )
        let scaledTerminalWidth = min(
            WorkspaceSplitMetrics.terminalMaximumWidth * 1.5,
            usefulTerminalWidth * 1.5
        )

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem === sidebarItem)
        XCTAssertTrue(controller.detailItem === detailItem)
        XCTAssertTrue(controller.terminalItem === terminalItem)
        XCTAssertEqual(controller.sidebarItem.minimumThickness, WorkspaceSplitMetrics.sidebarMinimumWidth * 1.5)
        XCTAssertEqual(controller.detailItem.minimumThickness, WorkspaceSplitMetrics.detailMinimumWidth * 1.5)
        XCTAssertEqual(controller.terminalItem.minimumThickness, WorkspaceSplitMetrics.terminalMinimumWidth * 1.5)
        XCTAssertEqual(controller.layoutScale, 1.5)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            scaledSidebarWidth,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            scaledTerminalWidth,
            accuracy: 2
        )

        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)
        XCTAssertEqual(splitView.dividerHitWidth, WorkspaceSplitMetrics.dividerHitWidth * 1.5)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulSidebarWidth, accuracy: 2)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulTerminalWidth, accuracy: 2)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            scaledTerminalWidth,
            accuracy: 2
        )
    }

    func testZoomIncreaseCollapsesTheLowestPriorityPaneBeforeViolatingMinimums() {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 1_230)
        let initialSplitWidth = controller.splitView.bounds.width
        let initialTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "terminal stayed visible at split width \(controller.splitView.bounds.width), "
                + "active divider \(String(describing: (controller.splitView as? WorkspaceNativeSplitView)?.activeDividerIndex))"
        )
        assertAllVisiblePanesMeetMinimums(controller)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            initialTerminalWidth,
            accuracy: 2,
            "Zooming back to 100% must restore the terminal's retained native width"
        )
    }

    func testZoomIncreaseWithPreferredHiddenTerminalCollapsesAndRestoresSidebar() {
        let recorder = PresentationRecorder()
        let controller = makeController(
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        let window = mount(controller, width: 1_100)
        let usefulSidebarWidth: CGFloat = 360
        controller.splitView.setPosition(usefulSidebarWidth, ofDividerAt: 0)
        layout(window, controller)
        let initialSplitWidth = controller.splitView.bounds.width
        let initialSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        XCTAssertEqual(initialSidebarWidth, usefulSidebarWidth, accuracy: 2)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth * 2 - 1
        )

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            initialSidebarWidth,
            accuracy: 2,
            "Zooming back to 100% must restore the sidebar while preserving a user-hidden terminal"
        )
    }
}
