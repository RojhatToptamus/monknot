import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class PDFTabInteractionTests: XCTestCase {
    func testInactiveMarkdownTabReceivesPointerClickWhilePDFTabIsSelected() async {
        for zoomScale in [1.0, WorkspaceZoomPolicy.maximum] {
            await assertInactiveMarkdownTabReceivesPointerClick(zoomScale: zoomScale)
        }
    }

    private func assertInactiveMarkdownTabReceivesPointerClick(zoomScale: Double) async {
        let theme = AppTheme.codexDark
        let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
        let markdownID = "/Notes.md"
        let pdfID = "/Active.pdf"
        let selection = TabSelectionProbe()

        let tabBar = DocumentTabBar(
            tabs: [
                WorkspaceTabItem(
                    documentID: markdownID,
                    displayName: "A.md",
                    relativePath: "Notes.md",
                    kind: .markdown
                ),
                WorkspaceTabItem(
                    documentID: pdfID,
                    displayName: "Active.pdf",
                    relativePath: "Active.pdf",
                    kind: .pdf
                )
            ],
            selectedDocumentID: pdfID,
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: theme.uiFontSize,
            isDisabled: false,
            saveState: { _ in .clean },
            selectTab: { selection.selectedDocumentID = $0 },
            closeTab: { _ in },
            togglePin: { _ in },
            reorderTab: { _, _ in }
        )
        .frame(width: 600, height: chromeHeight)

        let host = NSHostingView(rootView: tabBar)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: chromeHeight)

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

        await settleLayout()

        // Click near the trailing edge of the selection slot, not on its
        // label. This protects the full allocated tab hit target at normal
        // and maximum interface scale while staying clear of the close slot.
        let clickPoint = NSPoint(
            x: MonknotMetrics.interfaceDensity(75, theme: theme, zoomScale: zoomScale),
            y: chromeHeight / 2
        )
        let windowPoint = host.convert(clickPoint, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )

        guard let mouseDown, let mouseUp else {
            return XCTFail("Expected AppKit to create pointer events")
        }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)

        let didSelectMarkdown = await waitUntil {
            selection.selectedDocumentID == markdownID
        }
        XCTAssertTrue(
            didSelectMarkdown,
            "The inactive Markdown tab should remain clickable while the PDF tab is selected"
        )
    }

    private func settleLayout() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let stepNanoseconds: UInt64 = 10_000_000
        var elapsed: UInt64 = 0

        while elapsed < timeoutNanoseconds {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: stepNanoseconds)
            elapsed += stepNanoseconds
        }

        return condition()
    }
}

@MainActor
private final class TabSelectionProbe {
    var selectedDocumentID: String?
}
