import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitFullscreenTests: WorkspaceSplitViewTestCase {
    func testTerminalFullscreenCoversDocumentAreaAndRestoresExactDockedGeometry() async throws {
        try await assertTerminalFullscreenRoundTrip(prepopulateAutosave: false)
    }

    func testTerminalFullscreenRestoresGeometryLoadedFromAutosave() async throws {
        try await assertTerminalFullscreenRoundTrip(prepopulateAutosave: true)
    }

    func testClosingTerminalFromFullscreenClearsTheStateAndReopensAtDockedWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_500)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        controller.splitView.setPosition(
            controller.splitView.bounds.width - 475 - controller.splitView.dividerThickness,
            ofDividerAt: 1
        )
        layout(window, controller)
        let dockedWidth = paneWidth(controller.terminalItem, in: controller)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            isTerminalFullscreen: true,
            recorder: recorder
        )
        layout(window, controller)
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            isTerminalFullscreen: false,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.isTerminalFullscreen)
        XCTAssertFalse(controller.detailItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            isTerminalFullscreen: false,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), dockedWidth, accuracy: 1)
    }

    func testTerminalFullscreenScalesItsRetainedDockedWidthWithWorkspaceZoom() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 2_200)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        controller.splitView.setPosition(
            controller.splitView.bounds.width - 400 - controller.splitView.dividerThickness,
            ofDividerAt: 1
        )
        layout(window, controller)
        let dockedWidth = paneWidth(controller.terminalItem, in: controller)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            isTerminalFullscreen: true,
            recorder: recorder
        )
        layout(window, controller)
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            isTerminalFullscreen: true,
            layoutScale: 1.25,
            recorder: recorder
        )
        layout(window, controller)
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            isTerminalFullscreen: false,
            layoutScale: 1.25,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            dockedWidth * 1.25,
            accuracy: 1
        )
    }
}
