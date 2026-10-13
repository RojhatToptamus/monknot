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

    func testAFolderWithUnsavedWorkInsideIsNotDeleted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("Plan.md")
        try "# Plan\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && !store.documents.isEmpty }
        let document = try XCTUnwrap(store.documents.first { $0.url == fileURL.standardizedFileURL })
        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setOpenDocumentIDs([document.id])
        store.setDocumentText("# Plan\nedited\n")

        store.deleteFolder(at: folder)
        XCTAssertTrue(store.errorMessage?.contains("Save or close Plan.md") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        store.deleteFolder(at: root)
        XCTAssertFalse(store.isBusy, "The workspace folder itself is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
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
