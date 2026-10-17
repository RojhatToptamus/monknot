import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Every sidebar right-click menu, built by the real `SidebarView` over a real store and
/// performed item by item. Rows are identified by what their own "Copy Path" item reports, so
/// the assertions read the rows the sidebar actually shows.
@MainActor
final class SidebarContextMenuTests: FileOperationsTestCase {
    static let folderMenu = [
        "New File", "New Folder", "-", "Rename", "Copy Path", "Copy Relative Path", "Reveal in Finder", "-",
        "Copy", "Cut", "Paste", "Duplicate", "-", "Move to Trash",
    ]
    static let fileMenu = [
        "New File", "New Folder", "-", "Rename", "Copy Path", "Copy Relative Path", "Reveal in Finder", "Export PDF…", "-",
        "Copy", "Cut", "Paste", "Duplicate", "-", "Move to Trash",
    ]
    static let emptyAreaMenu = ["New File", "New Folder", "-", "Paste", "-", "Copy Path", "Reveal in Finder"]

    /// docs/{a.md,b.md}, A/B/t.txt (a compact "A/B" row), Collapsed/inner.md, top.md; docs/a.md selected.
    func makeFixture() async throws -> (URL, WorkspaceStore, SidebarMenuHarness) {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        try write("# b\n", "docs/b.md", in: root)
        try write("t\n", "A/B/t.txt", in: root)
        try write("# i\n", "Collapsed/inner.md", in: root)
        try write("# top\n", "top.md", in: root)
        let store = try await openStore(root, selecting: "docs/a.md")
        let h = await harness(store, root)
        return (root, store, h)
    }

    func rowIndex(_ h: SidebarMenuHarness, _ relativePath: String) -> Int? {
        h.visibleRowPaths().firstIndex(of: relativePath)
    }

    // MARK: - Inventory and wording

    func testMenusPerRowKindListTheExpectedItemsInOrder() async throws {
        let (_, _, h) = try await makeFixture()
        defer { h.close() }
        XCTAssertEqual(h.visibleRowPaths(), ["A/B", "Collapsed", "docs", "docs/a.md", "docs/b.md", "top.md"])

        XCTAssertEqual(SidebarMenuHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs")))), Self.folderMenu)
        XCTAssertEqual(SidebarMenuHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "A/B")))), Self.folderMenu)
        XCTAssertEqual(SidebarMenuHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs/b.md")))), Self.fileMenu)
        XCTAssertEqual(SidebarMenuHarness.titles(h.contextMenu(at: try XCTUnwrap(h.emptyTreePoint()))), Self.emptyAreaMenu)
        // A plain-text file has no Export PDF….
        let txtMenu = SidebarMenuHarness.titles(h.contextMenu(row: 0))
        XCTAssertFalse(txtMenu.contains("Export PDF…"))
    }

    func openRecents(_ h: SidebarMenuHarness, _ store: WorkspaceStore, recording document: WorkspaceDocument) async throws {
        store.selectDocument(id: document.id)
        _ = await wait(timeout: 3) { store.recentDocuments().contains { $0.documentID == document.id } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let tree = try XCTUnwrap(h.treeFrameInWindow())
        await h.click(at: NSPoint(x: tree.midX, y: tree.minY - 16))
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Recents rows are file rows (design.md §10.4), with the file row's location items in order.
    func testRecentsRowMenuMatchesTheFileRowLocationItems() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        try await openRecents(h, store, recording: try XCTUnwrap(doc(store, "docs/b.md")))
        let menu = h.recentsRowMenus().first
        XCTAssertEqual(SidebarMenuHarness.titles(menu), ["Open", "-", "Copy Path", "Copy Relative Path", "Reveal in Finder"])
        h.perform("Copy Relative Path", in: menu)
        XCTAssertEqual(h.copiedRelativePaths.last, root.appendingPathComponent("docs/b.md").standardizedFileURL)
    }

    /// Paste is enabled only while the clipboard holds something to paste, checked each time a
    /// menu opens.
    func testPasteIsEnabledOnlyWhenThereIsSomethingToPaste() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let empty = try XCTUnwrap(h.emptyTreePoint())
        func pasteEnabled() -> [Bool?] {
            [
                SidebarMenuHarness.item("Paste", in: h.contextMenu(row: 0))?.isEnabled,
                SidebarMenuHarness.item("Paste", in: h.contextMenu(row: try! XCTUnwrap(rowIndex(h, "top.md"))))?.isEnabled,
                SidebarMenuHarness.item("Paste", in: h.contextMenu(at: empty))?.isEnabled,
            ]
        }

        h.pasteboard.clearContents()
        XCTAssertEqual(pasteEnabled(), [false, false, false])

        h.pasteboard.setString("Some words", forType: .string)
        XCTAssertEqual(pasteEnabled(), [true, true, true])

        h.pasteboard.clearContents()
        XCTAssertEqual(pasteEnabled(), [false, false, false])

        h.perform("Copy", in: h.contextMenu(row: try XCTUnwrap(rowIndex(h, "top.md"))))
        XCTAssertEqual(pasteEnabled(), [true, true, true])
        h.perform("Paste", in: h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs"))))
        await idle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md", "b.md", "top.md"])
    }

    func testMoveToTrashFromAFolderMenuWithAnUnsavedDocumentInsideIsRefused() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let a = try XCTUnwrap(doc(store, "docs/a.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("# a edited\n")
        try await Task.sleep(nanoseconds: 300_000_000)

        h.perform("Move to Trash", in: h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs"))))
        await idle(store)
        XCTAssertEqual(store.errorMessage, "Save or close a.md before moving docs to the Trash.")
        XCTAssertEqual(names("docs", in: root), ["a.md", "b.md"])
        XCTAssertEqual(store.documentText, "# a edited\n")

        store.errorMessage = nil
        h.perform("Move to Trash", in: h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs/a.md"))))
        await idle(store)
        XCTAssertEqual(store.errorMessage, "Save or close a.md before moving it to the Trash.")
        XCTAssertTrue(names("docs", in: root).contains("a.md"))
    }

    func testEditorContextMenuOffersCutCopyPaste() throws {
        let textView = MarkdownNSTextView()
        textView.string = "Some words"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let titles = try XCTUnwrap(textView.menu(for: event)).items.map(\.title)
        for title in ["Cut", "Copy", "Paste", "Copy Rendered Markdown"] {
            XCTAssertTrue(titles.contains(title), "\(title) missing from \(titles)")
        }
    }

    // MARK: - Acts on the right-clicked row

    func testRowMenuActsOnTheRightClickedRowNotTheSelectedDocument() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        XCTAssertEqual(store.selectedDocument?.relativePath, "docs/a.md")
        let bIndex = try XCTUnwrap(rowIndex(h, "docs/b.md"))
        let b = root.appendingPathComponent("docs/b.md").standardizedFileURL

        h.perform("Copy Path", in: h.contextMenu(row: bIndex))
        XCTAssertEqual(h.copiedPaths.last, b)
        h.perform("Copy Relative Path", in: h.contextMenu(row: bIndex))
        XCTAssertEqual(h.copiedRelativePaths.last, b)
        h.perform("Export PDF…", in: h.contextMenu(row: bIndex))
        XCTAssertEqual(h.exportedPDFs.last, b.path)

        h.perform("Duplicate", in: h.contextMenu(row: bIndex))
        await idle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md", "b.md", "b copy.md"])

        // The duplicate's row shows once the tree has re-rendered.
        let rendered = await wait(timeout: 3) { self.rowIndex(h, "docs/b copy.md") != nil }
        XCTAssertTrue(rendered, "\(h.visibleRowPaths())")
        let renameIndex = try XCTUnwrap(rowIndex(h, "docs/b.md"))
        let opened = await h.performAndWaitForSheet("Rename", in: h.contextMenu(row: renameIndex))
        XCTAssertTrue(opened, "Rename sheet did not open")
        XCTAssertNotNil(h.sheetWindow, "Rename sheet did not open")
        XCTAssertEqual(h.sheetTextField()?.stringValue, "b.md", "Rename does not start from the right-clicked file's name")
        await h.submitSheet(name: "bee")
        await settle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md", "bee.md", "b copy.md"])
        XCTAssertNil(h.sheetWindow)
    }

    // MARK: - New File / New Folder

    func testNameSheetStaysOpenForInvalidNamesAndCreatesNothing() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let index = try XCTUnwrap(rowIndex(h, "docs"))
        let before = names("docs", in: root)

        let opened = await h.performAndWaitForSheet("New File", in: h.contextMenu(row: index))
        XCTAssertTrue(opened, "New File sheet did not open")
        for name in ["a/b.md", "x:y.md", ".hidden.md", "a.md", "A.MD", "..", "   "] {
            await h.submitSheet(name: name, expectClose: false)
            XCTAssertNotNil(h.sheetWindow, "Sheet closed for \(name)")
        }
        await idle(store)
        XCTAssertEqual(names("docs", in: root), before)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Rename

    func testRenamingAnExpandedFolderKeepsItExpanded() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        // Select a file outside docs, so only the expansion (not the selection) keeps docs open.
        let top = try XCTUnwrap(doc(store, "top.md"))
        store.selectDocument(id: top.id)
        _ = await wait { !store.isDocumentLoading }
        XCTAssertTrue(h.visibleRowPaths().contains("docs/a.md"))

        let opened = await h.performAndWaitForSheet("Rename", in: h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs"))))
        XCTAssertTrue(opened, "Rename sheet did not open")
        await h.submitSheet(name: "notes")
        await settle(store)
        XCTAssertEqual(names("notes", in: root), ["a.md", "b.md"])
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("notes/a.md") }
        let rows = h.visibleRowPaths()
        XCTAssertTrue(rows.contains("notes/a.md"), "\(rows)")
    }

    // MARK: - Busy

    func testMutatingItemsAreDisabledWhileAFileOperationRuns() async throws {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        let scanner = GatedWorkspaceScanner()
        let store = try await openStore(root, scanner: scanner, selecting: "docs/a.md")
        let h = await harness(store, root)
        defer { h.close() }

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("docs/a.md"))
        XCTAssertTrue(store.isBusy)
        try await Task.sleep(nanoseconds: 300_000_000)

        func enabled(_ menu: NSMenu?) -> [String: Bool] {
            Dictionary((menu?.items ?? []).filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) }, uniquingKeysWith: { a, _ in a })
        }
        let folder = enabled(h.contextMenu(row: 0))
        let file = enabled(h.contextMenu(row: 1))
        let empty = enabled(h.contextMenu(at: try XCTUnwrap(h.emptyTreePoint())))
        scanner.release()
        await idle(store)

        for title in ["New File", "New Folder", "Rename", "Copy", "Cut", "Paste", "Duplicate", "Move to Trash"] {
            XCTAssertEqual(folder[title], false, "Folder \(title)")
        }
        for title in ["New File", "New Folder", "Rename", "Copy", "Cut", "Paste", "Duplicate", "Move to Trash"] {
            XCTAssertEqual(file[title], false, "File \(title)")
        }
        for title in ["New File", "New Folder", "Paste"] {
            XCTAssertEqual(empty[title], false, "Empty area \(title)")
        }
        XCTAssertEqual(folder["Copy Path"], true)
        XCTAssertEqual(file["Copy Path"], true)
    }

    // MARK: - Finder drop on the empty sidebar

    func testFinderDropOnTheSidebarCopiesOutsideFilesAndMovesWorkspaceFilesToTheRoot() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let outside = try makeRoot()
        try write("o\n", "dropped.md", in: outside)
        let dropView = try XCTUnwrap(h.sidebarDropView())
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let point = try XCTUnwrap(h.emptyTreePoint())

        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("dropped.md") as NSURL])
        var info = FakeDraggingInfo(pasteboard: pasteboard, location: point, window: h.window)
        XCTAssertEqual(dropView.draggingEntered(info), .copy)
        XCTAssertTrue(dropView.performDragOperation(info))
        await idle(store)
        XCTAssertTrue(names("", in: root).contains("dropped.md"))
        XCTAssertTrue(names("", in: outside).contains("dropped.md"))

        pasteboard.clearContents()
        pasteboard.writeObjects([root.appendingPathComponent("docs/b.md") as NSURL])
        info = FakeDraggingInfo(pasteboard: pasteboard, location: point, window: h.window)
        XCTAssertEqual(dropView.draggingEntered(info), .move)
        XCTAssertTrue(dropView.performDragOperation(info))
        await settle(store)
        XCTAssertTrue(names("", in: root).contains("b.md"))
        XCTAssertFalse(names("docs", in: root).contains("b.md"))
    }

    // MARK: - Tabs

    func testTabMenuItemsAreDisabledWhileTabsAre() async throws {
        let theme = AppTheme.defaultDark
        let chrome = MonknotMetrics.chromeHeight(theme: theme, zoomScale: 1)
        var closed: [String] = []
        var pinned: [String] = []
        let bar = DocumentTabBar(
            tabs: [
                WorkspaceTabItem(documentID: "/w/a.md", displayName: "a.md", relativePath: "a.md", kind: .markdown),
                WorkspaceTabItem(documentID: "/w/b.md", displayName: "b.md", relativePath: "b.md", kind: .markdown),
            ],
            selectedDocumentID: "/w/a.md",
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: 1,
            isDisabled: true,
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { closed.append($0) },
            togglePin: { pinned.append($0) },
            reorderTab: { _, _ in }
        )
        .frame(width: 600, height: chrome)
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: chrome)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)

        let point = host.convert(NSPoint(x: 40, y: chrome / 2), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        var view: NSView? = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        menu?.update()
        let items = try XCTUnwrap(menu).items
        XCTAssertEqual(items.map(\.title), ["Pin Tab", "Close Tab"])
        XCTAssertEqual(items.map(\.isEnabled), [false, false])
        _ = (closed, pinned)
    }
}
