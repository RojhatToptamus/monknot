import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class TerminalChromeLayoutTests: XCTestCase {
    func testTerminalHeaderDragGapDragsWithoutZoomingTheWindow() throws {
        let host = NSHostingView(
            rootView: WindowTitleBarDragArea(doubleClickZoomsWindow: false)
        )
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        let window = WindowInteractionRecordingWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let dragView = try XCTUnwrap(
            host.allDescendantsForTesting()
                .compactMap { $0 as? WindowTitleBarDragArea.NativeTitleBarDragView }
                .first
        )

        dragView.mouseDown(with: titleBarMouseEvent(clickCount: 1, windowNumber: window.windowNumber))
        dragView.mouseDown(with: titleBarMouseEvent(clickCount: 2, windowNumber: window.windowNumber))

        XCTAssertEqual(window.dragCallCount, 1)
        XCTAssertEqual(window.zoomCallCount, 0)
    }

    func testTerminalPanelRowUsesItsSubordinateThirtySixPointHeader() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            let sessions = TerminalSessionCollectionStore()

            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let terminalRow = TerminalDrawerChromeRow(
                    sessions: sessions,
                    workingDirectory: nil,
                    theme: theme,
                    zoomScale: zoomScale,
                    close: {}
                )
                let terminalHost = NSHostingView(rootView: terminalRow.frame(width: 420))
                let expectedHeight = MonknotMetrics.interfaceControl(36, theme: theme, zoomScale: zoomScale)

                XCTAssertEqual(terminalHost.fittingSize.height, expectedHeight, accuracy: 0.01)
            }
        }
    }

    func testTerminalPanelKeepsTabsInAHorizontalScrollContainer() {
        let theme = AppTheme.defaultDark
        let sessions = TerminalSessionCollectionStore()
        XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        defer { sessions.stopAll() }

        let drawerHost = NSHostingView(rootView: TerminalDrawerChromeRow(
            sessions: sessions,
            workingDirectory: nil,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            close: {}
        ))
        drawerHost.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            drawerHost.allDescendantsForTesting().contains { $0 is NSScrollView },
            "The terminal panel must keep excess tabs in a bounded horizontal scroller"
        )
    }

    func testMountedTerminalTabsKeepManualHorizontalScrollPosition() async {
        let theme = AppTheme.defaultDark
        let sessions = TerminalSessionCollectionStore()
        for _ in 0..<10 {
            XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        }
        defer { sessions.stopAll() }

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: TerminalDrawerChromeRow(
            sessions: sessions,
            workingDirectory: FileManager.default.temporaryDirectory,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            close: {}
        ).frame(width: 180, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 180, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Mounted terminal overflow must expose a horizontal scroll container")
        }

        let maximumOffset = documentView.frame.width - horizontalScrollView.contentView.bounds.width
        XCTAssertGreaterThan(maximumOffset, 80)

        horizontalScrollView.contentView.scroll(to: NSPoint(x: 60, y: 0))
        horizontalScrollView.reflectScrolledClipView(horizontalScrollView.contentView)
        let manualOffset = horizontalScrollView.contentView.bounds.origin.x
        XCTAssertEqual(manualOffset, 60, accuracy: 1)

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            horizontalScrollView.contentView.bounds.origin.x,
            manualOffset,
            accuracy: 1,
            "Manual terminal-tab scrolling was overridden by active-tab reveal"
        )
    }

    func testTerminalUsesCompactTopPaddingBelowItsChrome() {
        let theme = AppTheme.defaultDark
        let html = TerminalWebView.html(
            theme: theme,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("padding: 10px 12px;"))
        XCTAssertFalse(html.contains("padding: 18px 20px;"))
        XCTAssertTrue(html.contains("new ResizeObserver"))
        XCTAssertFalse(
            html.contains("postResize();\n            term.focus();"),
            "A pressure-hidden terminal must not focus itself outside the native visibility gate"
        )
        XCTAssertTrue(html.contains("width: 12px;"))
        XCTAssertTrue(html.contains("--terminal-bg: \(theme.terminalSurfaceHex);"))
        XCTAssertTrue(html.contains("background: '\(theme.terminalSurfaceHex)'"))
        XCTAssertFalse(html.contains("background: '\(theme.background)'"))
    }

    func testTerminalResizeKeepsTheFirstScrollbackAnchorAcrossObserverCallbacks() {
        let html = TerminalWebView.html(
            theme: .defaultDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("let pendingResizeFrame = null;"))
        XCTAssertTrue(html.contains("let pendingScrollDistanceFromBottom = null;"))
        XCTAssertTrue(
            html.contains("options.preserveScroll && pendingScrollDistanceFromBottom === null")
        )
        XCTAssertTrue(html.contains("if (pendingResizeFrame !== null) return;"))
        XCTAssertTrue(
            html.contains("term.buffer.active.baseY - distanceFromBottom")
        )
        XCTAssertTrue(html.contains("const wasAtBottom = buffer.baseY - buffer.viewportY <= 0;"))
        XCTAssertTrue(html.contains("if (wasAtBottom) term.scrollToBottom();"))
        XCTAssertFalse(html.contains("Math.min(viewportY, term.buffer.active.baseY)"))
        XCTAssertFalse(html.contains("term.write(data, () => {\n              term.scrollToBottom();"))
    }

    func testTerminalFontUsesTheSameWorkspaceZoomAsDocumentContent() {
        let theme = AppTheme.defaultDark
        let minimum = TerminalDrawerView.terminalFontSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.minimum
        )
        let normal = TerminalDrawerView.terminalFontSize(theme: theme, zoomScale: 1)
        let maximum = TerminalDrawerView.terminalFontSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let maximumDocumentFont = TerminalDrawerView.fontSizeBase
            * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum)

        XCTAssertLessThan(minimum, normal)
        XCTAssertEqual(normal, TerminalDrawerView.fontSizeBase, accuracy: 0.001)
        XCTAssertEqual(maximum, 27, accuracy: 0.001)
        XCTAssertGreaterThan(maximum, normal)
        XCTAssertEqual(maximum, maximumDocumentFont, accuracy: 0.001)
    }
}
