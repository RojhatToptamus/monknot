import AppKit
import MonknotCore
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceRegressionTests: WorkspaceStorePDFTestCase {
    func testAnEmptyNewFolderChangesTheTreeTheSidebarShows() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Note".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.documents.isEmpty }
        XCTAssertTrue(didLoad)
        let documentsBefore = store.documents
        let revisionBefore = store.rootNodeRevision

        store.createFolder(named: "Drafts")
        let didCreate = await waitUntil {
            !store.isBusy && store.rootNode?.children?.contains { $0.name == "Drafts" } == true
        }

        XCTAssertTrue(didCreate)
        XCTAssertEqual(store.documents, documentsBefore, "An empty folder adds no document")
        XCTAssertGreaterThan(store.rootNodeRevision, revisionBefore, "The sidebar refreshes on the tree's revision")
    }

    func testAFocusedWebViewTakesThePasteInsteadOfTheWorkspace() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        final class TerminalLikeWebView: WKWebView {}
        let webView = TerminalLikeWebView(frame: window.contentLayoutRect)
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(webView))

        XCTAssertTrue(
            MonknotNativePasteboardCommand.monknotIsNativeTextTarget(webView),
            "⌘V in the terminal must paste into it, not import the clipboard as a file"
        )
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(NSView()))
    }
}
