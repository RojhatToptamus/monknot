import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Every sidebar right-click menu, built by the real `SidebarView` over a real store and
/// performed item by item. Rows are identified by what their own "Copy Path" item reports, so
/// the assertions read the rows the sidebar actually shows.
@MainActor
final class SidebarContextMenuQATests: FileOperationsQATestCase {
    static let folderMenu = [
        "New File", "New Folder", "-", "Rename", "Copy Path", "Copy Relative Path", "Reveal in Finder", "-",
        "Copy", "Cut", "Paste", "Duplicate", "-", "Move to Trash",
    ]
    static let fileMenu = [
        "Rename", "Copy Path", "Copy Relative Path", "Reveal in Finder", "Export PDF…", "-",
        "Copy", "Cut", "Paste", "Duplicate", "-", "Move to Trash",
    ]
    static let emptyAreaMenu = ["New File", "New Folder", "-", "Paste", "-", "Copy Path", "Reveal in Finder"]

    /// docs/{a.md,b.md}, A/B/t.txt (a compact "A/B" row), Collapsed/inner.md, top.md; docs/a.md selected.
    func makeFixture() async throws -> (URL, WorkspaceStore, QASidebarHarness) {
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

    func rowIndex(_ h: QASidebarHarness, _ relativePath: String) -> Int? {
        h.visibleRowPaths().firstIndex(of: relativePath)
    }

    // MARK: - Inventory and wording

    func testMenusPerRowKindListTheExpectedItemsInOrder() async throws {
        let (_, _, h) = try await makeFixture()
        defer { h.close() }
        XCTAssertEqual(h.visibleRowPaths(), ["A/B", "Collapsed", "docs", "docs/a.md", "docs/b.md", "top.md"])

        XCTAssertEqual(QASidebarHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs")))), Self.folderMenu)
        XCTAssertEqual(QASidebarHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "A/B")))), Self.folderMenu)
        XCTAssertEqual(QASidebarHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs/b.md")))), Self.fileMenu)
        XCTAssertEqual(QASidebarHarness.titles(h.contextMenu(at: try XCTUnwrap(h.emptyTreePoint()))), Self.emptyAreaMenu)
        // A plain-text file has no Export PDF….
        let txtMenu = QASidebarHarness.titles(h.contextMenu(row: 0))
        XCTAssertFalse(txtMenu.contains("Export PDF…"))
    }

    /// New File and New Folder are offered on folder rows and the empty area, but not on a file
    /// row, where the user expects them to create beside the file.
    func testFileRowMenuOffersNewFileAndNewFolder() async throws {
        let (_, _, h) = try await makeFixture()
        defer { h.close() }
        let titles = QASidebarHarness.titles(h.contextMenu(row: try XCTUnwrap(rowIndex(h, "docs/b.md"))))
        XCTExpectFailure("A file row's context menu has no New File or New Folder item") {
            XCTAssertTrue(titles.contains("New File"), "\(titles)")
            XCTAssertTrue(titles.contains("New Folder"), "\(titles)")
        }
    }

    func openRecents(_ h: QASidebarHarness, _ store: WorkspaceStore, recording document: WorkspaceDocument) async throws {
        store.selectDocument(id: document.id)
        _ = await wait(timeout: 3) { store.recentDocuments().contains { $0.documentID == document.id } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let tree = try XCTUnwrap(h.treeFrameInWindow())
        await h.click(at: NSPoint(x: tree.midX, y: tree.minY - 16))
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testRecentsRowMenuOpensAndCopiesTheRightDocument() async throws {
        let (_, store, h) = try await makeFixture()
        defer { h.close() }
        let b = try XCTUnwrap(doc(store, "docs/b.md"))
        try await openRecents(h, store, recording: b)

        let first = try XCTUnwrap(h.recentsRowMenus().first, "No Recents rows found")
        h.perform("Copy Path", in: first)
        XCTAssertEqual(h.copiedPaths.last, b.url.standardizedFileURL)
        h.perform("Open", in: first)
        XCTAssertEqual(h.openedDocumentIDs.last, b.id)
    }

    /// Recents rows are file rows (design.md §10.4) and the last commit aligned the menus; the
    /// Recents menu still orders its location items differently and lacks Copy Relative Path.
    func testRecentsRowMenuMatchesTheFileRowLocationItems() async throws {
        let (_, store, h) = try await makeFixture()
        defer { h.close() }
        try await openRecents(h, store, recording: try XCTUnwrap(doc(store, "docs/b.md")))
        let titles = QASidebarHarness.titles(h.recentsRowMenus().first)
        XCTAssertEqual(titles.first, "Open")
        XCTExpectFailure("Recents menu is Open, Reveal in Finder, Copy Path: no Copy Relative Path and a different order from file rows") {
            XCTAssertEqual(titles, ["Open", "-", "Copy Path", "Copy Relative Path", "Reveal in Finder"])
        }
    }

    /// Paste is enabled even when nothing can be pasted, and then only beeps. Needs an empty
    /// general clipboard to show (the test never writes the general clipboard).
    func testPasteIsDisabledWhenThereIsNothingToPaste() async throws {
        let general = NSPasteboard.general
        let generalHasContent = (try? WorkspacePasteboardImportService.importItems(from: general).isEmpty == false) ?? true
        try XCTSkipIf(generalHasContent, "The general clipboard holds pasteable content; this check needs it empty")
        let (_, store, h) = try await makeFixture()
        defer { h.close() }
        XCTAssertFalse(store.canPasteDocumentTransfer)
        let folderPaste = QASidebarHarness.item("Paste", in: h.contextMenu(row: 0))
        let emptyPaste = QASidebarHarness.item("Paste", in: h.contextMenu(at: try XCTUnwrap(h.emptyTreePoint())))
        XCTExpectFailure("Paste is enabled with nothing to paste; choosing it only beeps") {
            XCTAssertEqual(folderPaste?.isEnabled, false)
            XCTAssertEqual(emptyPaste?.isEnabled, false)
        }
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

    func testCompactRowActsOnItsDeepestFolder() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let index = try XCTUnwrap(rowIndex(h, "A/B"))
        h.perform("Copy Relative Path", in: h.contextMenu(row: index))
        XCTAssertEqual(h.copiedRelativePaths.last, root.appendingPathComponent("A/B").standardizedFileURL)

        let opened = await h.performAndWaitForSheet("New File", in: h.contextMenu(row: index))
        XCTAssertTrue(opened, "New File sheet did not open")
        await h.submitSheet(name: "made.md")
        await idle(store)
        XCTAssertEqual(names("A/B", in: root), ["t.txt", "made.md"])
        XCTAssertEqual(store.selectedDocument?.relativePath, "A/B/made.md")
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("A/B/made.md") }
        XCTAssertTrue(h.visibleRowPaths().contains("A/B/made.md"), "\(h.visibleRowPaths())")
    }

    // MARK: - New File / New Folder

    func testNewFileFromACollapsedFolderRowAppearsSelectedAndRevealed() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let index = try XCTUnwrap(rowIndex(h, "Collapsed"))
        XCTAssertFalse(h.visibleRowPaths().contains("Collapsed/inner.md"))

        let opened = await h.performAndWaitForSheet("New File", in: h.contextMenu(row: index))
        XCTAssertTrue(opened, "New File sheet did not open")
        await h.submitSheet(name: "fresh.md")
        await idle(store)
        XCTAssertEqual(names("Collapsed", in: root), ["inner.md", "fresh.md"])
        XCTAssertEqual(store.selectedDocument?.relativePath, "Collapsed/fresh.md")
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("Collapsed/fresh.md") }
        XCTAssertTrue(h.visibleRowPaths().contains("Collapsed/fresh.md"), "\(h.visibleRowPaths())")
    }

    func testNewFolderFromACollapsedFolderRowIsRevealed() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let index = try XCTUnwrap(rowIndex(h, "Collapsed"))

        let opened = await h.performAndWaitForSheet("New Folder", in: h.contextMenu(row: index))
        XCTAssertTrue(opened, "New Folder sheet did not open")
        await h.submitSheet(name: "Sub")
        await idle(store)
        XCTAssertEqual(names("Collapsed", in: root), ["inner.md", "Sub"])
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("Collapsed/Sub") }
        let rows = h.visibleRowPaths()
        XCTExpectFailure("New Folder into a collapsed folder leaves the folder collapsed: the new folder is created but not shown") {
            XCTAssertTrue(rows.contains("Collapsed/Sub"), "\(rows)")
        }
    }

    func testNewFileAndFolderFromTheEmptyArea() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let empty = try XCTUnwrap(h.emptyTreePoint())

        let opened = await h.performAndWaitForSheet("New File", in: h.contextMenu(at: empty))
        XCTAssertTrue(opened, "New File sheet did not open")
        XCTAssertEqual(h.sheetTextField()?.stringValue, "Untitled.txt")
        await h.submitSheet(name: "root note.md")
        await idle(store)
        XCTAssertEqual(store.selectedDocument?.relativePath, "root note.md")
        // Let the menu re-render out of its busy (disabled) state before right-clicking again.
        try await Task.sleep(nanoseconds: 400_000_000)

        let openedFolder = await h.performAndWaitForSheet("New Folder", in: h.contextMenu(at: try XCTUnwrap(h.emptyTreePoint())))
        XCTAssertTrue(openedFolder, "New Folder sheet did not open")
        await h.submitSheet(name: "Zed")
        await idle(store)
        XCTAssertTrue(names("", in: root).isSuperset(of: ["root note.md", "Zed"]))
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("Zed") }
        XCTAssertTrue(h.visibleRowPaths().contains("Zed"), "\(h.visibleRowPaths())")
        XCTAssertTrue(h.visibleRowPaths().contains("root note.md"), "\(h.visibleRowPaths())")
    }

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

    func testNewFolderAndFileInAnEmptyWorkspace() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let h = await harness(store, root)
        defer { h.close() }
        let point = NSPoint(x: 140, y: 320)
        XCTAssertEqual(QASidebarHarness.titles(h.contextMenu(at: point)), Self.emptyAreaMenu)

        let opened = await h.performAndWaitForSheet("New Folder", in: h.contextMenu(at: point))
        XCTAssertTrue(opened, "New Folder sheet did not open")
        XCTAssertEqual(h.sheetTextField()?.stringValue, "New Folder")
        await h.submitSheet(name: "First")
        await idle(store)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(h.visibleRowPaths(), ["First"])

        let openedFile = await h.performAndWaitForSheet("New File", in: h.contextMenu(row: 0))
        XCTAssertTrue(openedFile, "New File sheet did not open")
        await h.submitSheet(name: "note.md")
        await idle(store)
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("First/note.md") }
        XCTAssertEqual(h.visibleRowPaths(), ["First", "First/note.md"])
        XCTAssertEqual(store.selectedDocument?.relativePath, "First/note.md")
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
        XCTExpectFailure("Renaming (or moving) an expanded folder collapses it: expansion is keyed by path and not remapped") {
            XCTAssertTrue(rows.contains("notes/a.md"), "\(rows)")
        }
    }

    // MARK: - Busy

    func testMutatingItemsAreDisabledWhileAFileOperationRuns() async throws {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        let scanner = QAGatedScanner()
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
        for title in ["Rename", "Copy", "Cut", "Paste", "Duplicate", "Move to Trash"] {
            XCTAssertEqual(file[title], false, "File \(title)")
        }
        for title in ["New File", "New Folder", "Paste"] {
            XCTAssertEqual(empty[title], false, "Empty area \(title)")
        }
        XCTAssertEqual(folder["Copy Path"], true)
        XCTAssertEqual(file["Copy Path"], true)
    }

    // MARK: - Recents follow renames

    func testRecentsRowFollowsARename() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let b = try XCTUnwrap(doc(store, "docs/b.md"))
        store.selectDocument(id: b.id)
        _ = await wait(timeout: 3) { store.recentDocuments().contains { $0.documentID == b.id } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let tree = try XCTUnwrap(h.treeFrameInWindow())
        await h.click(at: NSPoint(x: tree.midX, y: tree.minY - 16))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(h.recentsRowMenus().isEmpty)

        store.renameDocument(id: b.id, to: "bee")
        await settle(store)
        XCTAssertNotNil(doc(store, "docs/bee.md"))
        try await Task.sleep(nanoseconds: 400_000_000)

        var recentPaths: [URL] = []
        for menu in h.recentsRowMenus() {
            h.perform("Copy Path", in: menu)
            if let url = h.copiedPaths.last { recentPaths.append(url) }
        }
        XCTExpectFailure("After a rename the Recents row keeps the old path (it is neither remapped nor refreshed)") {
            XCTAssertFalse(recentPaths.contains(b.url.standardizedFileURL), "Recents still lists the old name: \(recentPaths)")
            XCTAssertTrue(recentPaths.contains(root.appendingPathComponent("docs/bee.md").standardizedFileURL), "\(recentPaths)")
        }
        // Its Open item asks for a document that no longer exists, so choosing it does nothing.
        if let stale = h.recentsRowMenus().first {
            h.perform("Open", in: stale)
            if let opened = h.openedDocumentIDs.last {
                XCTExpectFailure("The stale Recents row opens a document ID the workspace no longer has") {
                    XCTAssertNotNil(store.document(id: opened), opened)
                }
            }
        }
    }

    // MARK: - Paste into a collapsed folder

    func testFileCopyPastedIntoACollapsedFolderIsRevealed() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("top.md"), cutting: false, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Collapsed")))
        await idle(store)
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("Collapsed/top.md") }
        XCTAssertTrue(h.visibleRowPaths().contains("Collapsed/top.md"), "\(h.visibleRowPaths())")
    }

    func testFinderFilesPastedIntoACollapsedFolderAreRevealed() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let outside = try makeRoot()
        try write("o\n", "outside.md", in: outside)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("outside.md") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Collapsed")))
        await idle(store)
        XCTAssertEqual(names("Collapsed", in: root), ["inner.md", "outside.md"])
        _ = await wait(timeout: 2) { h.visibleRowPaths().contains("Collapsed/outside.md") }
        let rows = h.visibleRowPaths()
        XCTExpectFailure("Finder files pasted (or dropped) into a collapsed folder are neither revealed nor selected") {
            XCTAssertTrue(rows.contains("Collapsed/outside.md"), "\(rows)")
        }
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
        var info = QAFakeDraggingInfo(pasteboard: pasteboard, location: point, window: h.window)
        XCTAssertEqual(dropView.draggingEntered(info), .copy)
        XCTAssertTrue(dropView.performDragOperation(info))
        await idle(store)
        XCTAssertTrue(names("", in: root).contains("dropped.md"))
        XCTAssertTrue(names("", in: outside).contains("dropped.md"))

        pasteboard.clearContents()
        pasteboard.writeObjects([root.appendingPathComponent("docs/b.md") as NSURL])
        info = QAFakeDraggingInfo(pasteboard: pasteboard, location: point, window: h.window)
        XCTAssertEqual(dropView.draggingEntered(info), .move)
        XCTAssertTrue(dropView.performDragOperation(info))
        await settle(store)
        XCTAssertTrue(names("", in: root).contains("b.md"))
        XCTAssertFalse(names("docs", in: root).contains("b.md"))
    }

    // MARK: - Dragging rows

    func testDragWhileBusyMovesNothingAndLaterDragsWork() async throws {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        try write("# top\n", "top.md", in: root)
        let scanner = QAGatedScanner()
        let store = try await openStore(root, scanner: scanner, selecting: "docs/a.md")
        let h = await harness(store, root)
        defer { h.close() }
        XCTAssertEqual(h.visibleRowPaths(), ["docs", "docs/a.md", "top.md"])
        let source = try XCTUnwrap(h.rowCenter(2))
        let target = try XCTUnwrap(h.rowCenter(0))

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("docs/a.md"))
        await h.drag(from: source, to: target)
        scanner.release()
        await idle(store)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(names("", in: root).contains("top.md"), "Moved while busy")

        let rows = h.visibleRowPaths()
        let from = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rows.firstIndex(of: "top.md"))))
        await h.drag(from: from, to: target)
        await settle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md", "a copy.md", "top.md"])
    }

    /// Finder copies when Option is held during a drag; the sidebar's Finder drops follow that,
    /// but dragging a row with Option still moves it.
    func testOptionDragOfARowCopiesLikeFinder() async throws {
        let (root, store, h) = try await makeFixture()
        defer { h.close() }
        let source = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))
        let target = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "docs"))))
        await h.drag(from: source, to: target, modifiers: [.option])
        await settle(store)
        _ = await wait(timeout: 2) { self.names("docs", in: root).contains("top.md") }
        XCTAssertTrue(names("docs", in: root).contains("top.md"), "Nothing landed in docs")
        XCTExpectFailure("Option-dragging a sidebar row moves it; it never copies (Finder drops onto the sidebar do copy with Option)") {
            XCTAssertTrue(names("", in: root).contains("top.md"))
        }
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
