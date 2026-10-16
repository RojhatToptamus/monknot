import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp

/// Showing and hiding side panes from their toolbar buttons: the buttons always act, and the
/// panes slide rather than squeeze.
@MainActor
final class WorkspaceSplitTransitionTests: WorkspaceSplitViewTestCase {
    /// At 115% zoom a 1,000pt window holds the document and one side pane, not both.
    private let narrowScale: CGFloat = 1.15
    private let narrowWidth: CGFloat = 1_000

    private func mountChrome(
        _ model: ChromeToggleModel,
        width: CGFloat
    ) -> (NSWindow, NSHostingView<ChromeToggleFixture>) {
        let host = NSHostingView(rootView: ChromeToggleFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return (window, host)
    }

    private func visiblePanesFit(_ splitView: NSSplitView, in host: NSView) -> Bool {
        splitView.arrangedSubviews.allSatisfy { pane in
            pane.isHidden || pane.convert(pane.bounds, to: host).maxX <= host.bounds.width + 0.5
        }
    }

    func testShowingTheTerminalInANarrowWindowMovesTheSidebarAside() async throws {
        let model = ChromeToggleModel(layoutScale: narrowScale)
        let (window, host) = mountChrome(model, width: narrowWidth)
        defer { window.contentView = nil }
        await waitForMountedSplitHost(window: window, host: host) { _ in
            model.sidebarVisible && !model.terminalVisible
        }
        XCTAssertTrue(model.terminalPreferred, "Precondition: the window squeezes out a terminal that is still wanted")

        model.toggleTerminal()
        await waitForMountedSplitHost(window: window, host: host) { _ in
            model.terminalVisible && !model.sidebarVisible
        }

        let splitView = try XCTUnwrap(firstDescendant(of: WorkspaceNativeSplitView.self, in: host))
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden, "The terminal button must always open the terminal")
        XCTAssertTrue(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(model.sidebarPreferred, "The sidebar only steps aside; it returns when there is room")
        XCTAssertTrue(visiblePanesFit(splitView, in: host))

        model.toggleTerminal()
        await waitForMountedSplitHost(window: window, host: host) { _ in
            !model.terminalVisible && model.sidebarVisible
        }
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertFalse(
            splitView.arrangedSubviews[0].isHidden,
            "Closing the terminal gives the room back to the sidebar"
        )
    }

    func testShowingTheSidebarInANarrowWindowMovesTheTerminalAside() async throws {
        let model = ChromeToggleModel(layoutScale: narrowScale)
        let (window, host) = mountChrome(model, width: narrowWidth)
        defer { window.contentView = nil }
        await waitForMountedSplitHost(window: window, host: host) { _ in
            model.sidebarVisible && !model.terminalVisible
        }
        model.toggleTerminal()
        await waitForMountedSplitHost(window: window, host: host) { _ in
            model.terminalVisible && !model.sidebarVisible
        }

        model.toggleSidebar()
        await waitForMountedSplitHost(window: window, host: host) { _ in
            model.sidebarVisible && !model.terminalVisible
        }

        let splitView = try XCTUnwrap(firstDescendant(of: WorkspaceNativeSplitView.self, in: host))
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden, "The sidebar button must always open the sidebar")
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertTrue(visiblePanesFit(splitView, in: host))
    }

    func testTheShownPaneKeepsItsPlaceWhenZoomLeavesRoomForOnlyOne() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: narrowWidth)
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

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: narrowScale,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed, "The terminal was shown last, so it keeps its place")
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testReopeningATerminalWhileItIsStillClosingLeavesItOpen() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(MonknotMotion.paneTransitionDuration / 3))
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            terminalRevealRequest: 1,
            recorder: recorder,
            animated: true
        )
        RunLoop.main.run(until: Date().addingTimeInterval(MonknotMotion.paneTransitionDuration * 2))
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
        let terminalContent = controller.terminalHostingController.view
        XCTAssertEqual(
            terminalContent.frame.width,
            paneWidth(controller.terminalItem, in: controller),
            accuracy: 1,
            "Once the transition settles, the content fills the pane again"
        )
    }

    func testSidePaneContentSlidesAtItsOpenWidthInsteadOfSqueezing() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_280)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        layout(window, controller)
        let sidebarContent = controller.sidebarHostingController.view
        let terminalContent = controller.terminalHostingController.view
        let sidebarWidth = sidebarContent.frame.width
        let terminalWidth = terminalContent.frame.width

        update(controller, sidebarPresented: false, terminalPresented: false, recorder: recorder, animated: true)
        var sawPartlyOpenPane = false
        let deadline = Date().addingTimeInterval(MonknotMotion.paneTransitionDuration * 2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let sidebarPane = controller.splitView.arrangedSubviews[0]
            let terminalPane = controller.splitView.arrangedSubviews[2]
            if !sidebarPane.isHidden, sidebarPane.frame.width > 1, sidebarPane.frame.width < sidebarWidth - 1 {
                sawPartlyOpenPane = true
                XCTAssertEqual(sidebarContent.frame.width, sidebarWidth, accuracy: 0.5)
            }
            if !terminalPane.isHidden, terminalPane.frame.width > 1, terminalPane.frame.width < terminalWidth - 1 {
                sawPartlyOpenPane = true
                XCTAssertEqual(terminalContent.frame.width, terminalWidth, accuracy: 0.5)
            }
        }

        XCTAssertTrue(sawPartlyOpenPane, "Precondition: the panes animate closed")
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
    }

    func testTrafficLightsStayPutWhileSidePanesOpenAndClose() async throws {
        let model = ChromeToggleModel(layoutScale: 1)
        let root = VStack(spacing: 0) {
            Color.gray.frame(height: 44)
            ChromeToggleFixture(model: model)
        }
        .background(WindowChromeConfigurator(
            surfaceColor: .black,
            isDark: true,
            trafficLightRowHeight: 44,
            trafficLightLeadingInset: 16,
            enablesStandardWindowControls: true
        ))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_300, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        let resting = try closeButtonOrigin(in: window)
        let toggles: [() -> Void] = [
            { model.toggleSidebar(animated: true) },
            { model.toggleSidebar(animated: true) },
            { model.toggleTerminal(animated: true) },
            { model.toggleTerminal(animated: true) },
        ]
        for toggle in toggles {
            toggle()
            try assertCloseButtonStays(
                at: resting,
                in: window,
                for: MonknotMotion.paneTransitionDuration * 1.6
            )
        }
    }

    private func closeButtonOrigin(in window: NSWindow) throws -> CGPoint {
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        return button.convert(button.bounds, to: nil).origin
    }

    /// Samples the close button every few milliseconds while the run loop drives the transition.
    /// Synchronous, so every sample sees one completed run-loop pass.
    private func assertCloseButtonStays(
        at resting: CGPoint,
        in window: NSWindow,
        for duration: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            XCTAssertEqual(
                try closeButtonOrigin(in: window),
                resting,
                "The traffic lights must not move with a side pane"
            )
        }
    }
}
