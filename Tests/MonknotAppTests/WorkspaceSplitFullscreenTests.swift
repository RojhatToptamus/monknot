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

    /// Leaving full width is entering run backwards (design.md §11): the document comes back through
    /// the same native transition, its card a divider's width from the sidebar and the terminal on
    /// every frame, and lands exactly where it was, with nothing settling afterwards.
    func testLeavingTerminalFullWidthRunsTheTransitionBackwardsAndLandsExactly() async throws {
        let animates = await splitViewsAnimateHere()
        try XCTSkipUnless(animates, "AppKit finishes split view animations at once on this display, so there are no frames to check")
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_300)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        let split = controller.splitView
        let gap = WorkspaceSplitMetrics.dividerThickness

        struct Edges {
            let documentShown: Bool
            let sidebar: CGFloat
            let card: NSRect
            let terminal: CGFloat
            let documentWidth: CGFloat
        }
        func edges() -> Edges {
            Edges(
                documentShown: !split.arrangedSubviews[1].isHidden,
                sidebar: split.arrangedSubviews[0].frame.maxX,
                card: split.convert(controller.detailPane.cardFrameInWindow, from: nil),
                terminal: split.arrangedSubviews[2].frame.minX,
                documentWidth: controller.detailHostingController.view.frame.width
            )
        }
        func record(for seconds: TimeInterval) async -> [Edges] {
            var samples: [Edges] = []
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                samples.append(edges())
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            return samples
        }

        let docked = edges()
        XCTAssertEqual(docked.terminal - docked.card.maxX, gap, accuracy: 0.5)

        update(controller, sidebarPresented: true, terminalPresented: true, isTerminalFullscreen: true, recorder: recorder, animated: true)
        let entering = await record(for: 0.6)
        let full = try XCTUnwrap(entering.last)
        XCTAssertEqual(full.terminal - full.sidebar, gap, accuracy: 0.5, "Full width, one gap beside the sidebar")

        update(controller, sidebarPresented: true, terminalPresented: true, isTerminalFullscreen: false, recorder: recorder, animated: true)
        let leaving = await record(for: 0.6)

        for (index, sample) in (entering + leaving).enumerated() {
            // The document keeps its width under the terminal, collapsed too: it is never laid out
            // at a sliver of a width and again on its return.
            XCTAssertEqual(sample.documentWidth, docked.documentWidth, accuracy: 0.5, "Document width, sample \(index)")
            guard sample.documentShown, sample.card.width > 1 else { continue }
            XCTAssertEqual(sample.terminal - sample.card.maxX, gap, accuracy: 0.5, "Gap to the terminal, sample \(index)")
            XCTAssertEqual(sample.card.minX - sample.sidebar, gap, accuracy: 0.5, "Gap to the sidebar, sample \(index)")
        }
        func steps(_ samples: [Edges]) -> Int {
            Set(samples.map { $0.terminal.rounded() }.filter { $0 > full.terminal + 1 && $0 < docked.terminal - 1 }).count
        }
        XCTAssertGreaterThanOrEqual(steps(entering), 3, "Entering animates")
        XCTAssertGreaterThanOrEqual(steps(leaving), 3, "Leaving animates too, rather than snapping open")

        let landed = try XCTUnwrap(leaving.last)
        XCTAssertEqual(landed.card.minX, docked.card.minX, accuracy: 0.5)
        XCTAssertEqual(landed.card.maxX, docked.card.maxX, accuracy: 0.5)
        XCTAssertEqual(landed.terminal, docked.terminal, accuracy: 0.5)
        // The last fifth of the recording comes well after the transition: nothing moves in it.
        for sample in leaving.suffix(leaving.count / 5) {
            XCTAssertEqual(sample.card.maxX, landed.card.maxX, accuracy: 0.1, "Nothing settles after the transition")
            XCTAssertEqual(sample.terminal, landed.terminal, accuracy: 0.1, "Nothing settles after the transition")
        }
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

    /// Whether AppKit animates a split view here: an item collapsed through its animator is between
    /// its widths partway through. A CI runner's display can end the animation at once, leaving a
    /// recording of a transition no frames to check.
    private func splitViewsAnimateHere() async -> Bool {
        func item(width: CGFloat) -> NSSplitViewItem {
            let content = NSViewController()
            content.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            return NSSplitViewItem(viewController: content)
        }
        let controller = NSSplitViewController()
        let collapsing = item(width: 200)
        collapsing.canCollapse = true
        controller.addSplitViewItem(collapsing)
        controller.addSplitViewItem(item(width: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        controller.view.layoutSubtreeIfNeeded()
        let start = controller.splitView.arrangedSubviews[0].frame.width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            collapsing.animator().isCollapsed = true
        }, completionHandler: nil)
        var widths: Set<CGFloat> = []
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            widths.insert(controller.splitView.arrangedSubviews[0].frame.width.rounded())
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return widths.filter { $0 > 1 && $0 < start - 1 }.count >= 2
    }
}
