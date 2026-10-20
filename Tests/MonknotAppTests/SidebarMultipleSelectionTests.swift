import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Selecting several items in the sidebar and the tree's keyboard (design.md §10.4), driven by
/// real mouse and key events over the real sidebar and store: ⇧- and ⌘-click, the arrow keys,
/// typing a name, and the commands, menus, drags and clipboard that act on every selected item.
@MainActor
final class SidebarMultipleSelectionTests: FileOperationsTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let harness: SidebarMenuHarness

        func path(_ relativePath: String) -> String {
            root.appendingPathComponent(relativePath).standardizedFileURL.path
        }

        /// The rows the sidebar shows, from the folders it saves as open.
        var rows: [VisibleSidebarNode] {
            SidebarTreePresentation.visibleNodes(
                from: store.rootNode?.children ?? [],
                expandedFolderIDs: WorkspaceTreeExpansionPersistence().load(for: root) ?? []
            )
        }

        var rowPaths: [String] {
            rows.map(\.dropTargetNode.relativePath)
        }

        /// What the sidebar selects, as workspace-relative paths in path order.
        var selected: [String] {
            store.sidebarSelectionIDs
                .map { String($0.dropFirst(root.path.count + 1)) }
                .sorted()
        }

        func center(of relativePath: String) throws -> NSPoint {
            let index = try XCTUnwrap(rowPaths.firstIndex(of: relativePath), "\(relativePath) is not a row: \(rowPaths)")
            return try XCTUnwrap(harness.rowCenter(index))
        }

        func click(_ relativePath: String, modifiers: NSEvent.ModifierFlags = []) async throws {
            let point = try center(of: relativePath)
            await harness.drag(from: point, to: point, modifiers: modifiers)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        /// A key press to the focused view, as AppKit delivers it.
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: harness.window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                ) else { continue }
                harness.window.sendEvent(event)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        func treeHasFocus() -> Bool {
            harness.window.firstResponder === harness.treeDocumentView
        }
    }

    private enum Key {
        static let up: (String, UInt16) = ("\u{F700}", 126)
        static let down: (String, UInt16) = ("\u{F701}", 125)
        static let left: (String, UInt16) = ("\u{F702}", 123)
        static let right: (String, UInt16) = ("\u{F703}", 124)
        static let home: (String, UInt16) = ("\u{F729}", 115)
        static let end: (String, UInt16) = ("\u{F72B}", 119)
        static let delete: (String, UInt16) = ("\u{7F}", 51)
    }

    /// a.md … d.md at the root, docs/{e.md, f.md} and docs/deep/g.md, Archive/keep.md; a.md open.
    private func makeFixture() async throws -> Fixture {
        let root = try makeRoot()
        for name in ["a.md", "b.md", "c.md", "d.md"] {
            try write("# \(name)\n", name, in: root)
        }
        try write("# e\n", "docs/e.md", in: root)
        try write("# f\n", "docs/f.md", in: root)
        try write("# g\n", "docs/deep/g.md", in: root)
        try write("# keep\n", "Archive/keep.md", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let h = await harness(store, root)
        addTeardownBlock { @MainActor in
            MonknotContextMenuController.shared.close(animated: false)
            h.close()
            UserDefaults.standard.removeObject(forKey: WorkspaceTreeExpansionPersistence().key(for: root))
        }
        return Fixture(root: root, store: store, harness: h)
    }

    // MARK: - The mouse

    func testShiftClickSelectsTheRowsBetweenAndCommandClickAddsOrRemovesOneWithoutOpeningAny() async throws {
        let f = try await makeFixture()
        XCTAssertEqual(f.rowPaths, ["Archive", "docs", "a.md", "b.md", "c.md", "d.md"])

        try await f.click("b.md")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("b.md"), "A plain click opens the file")
        XCTAssertEqual(f.selected, ["b.md"])

        try await f.click("d.md", modifiers: .shift)
        XCTAssertEqual(f.selected, ["b.md", "c.md", "d.md"], "⇧-click selects from the file last clicked")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("b.md"), "⇧-click opens nothing")

        try await f.click("c.md", modifiers: .command)
        XCTAssertEqual(f.selected, ["b.md", "d.md"], "⌘-click takes an item out")
        try await f.click("Archive", modifiers: .command)
        XCTAssertEqual(f.selected, ["Archive", "b.md", "d.md"], "⌘-click adds an item")
        XCTAssertFalse(f.rowPaths.contains("Archive/keep.md"), "⌘-click does not open a folder")

        // ⇧-click again runs from the item ⌘-click added.
        try await f.click("a.md", modifiers: .shift)
        XCTAssertEqual(f.selected, ["Archive", "a.md", "docs"])

        try await f.click("c.md")
        XCTAssertEqual(f.selected, ["c.md"], "A plain click selects that row alone")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("c.md"))

        try await f.click("c.md", modifiers: .command)
        XCTAssertEqual(f.selected, [], "⌘-click takes out the open file too")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("c.md"), "It stays open")
    }

    // MARK: - The keyboard

    func testArrowKeysMoveTheSelectionAndShiftExtendsIt() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        XCTAssertTrue(f.treeHasFocus())

        await f.press(Key.down.0, keyCode: Key.down.1)
        XCTAssertEqual(f.selected, ["c.md"])
        XCTAssertEqual(f.store.selectedDocumentID, f.path("b.md"), "Moving the selection opens nothing")

        await f.press(Key.down.0, keyCode: Key.down.1, modifiers: .shift)
        XCTAssertEqual(f.selected, ["c.md", "d.md"])
        await f.press(Key.up.0, keyCode: Key.up.1, modifiers: .shift)
        await f.press(Key.up.0, keyCode: Key.up.1, modifiers: .shift)
        XCTAssertEqual(f.selected, ["b.md", "c.md"], "⇧↑ turns the range round its anchor")

        await f.press(Key.home.0, keyCode: Key.home.1)
        XCTAssertEqual(f.selected, ["Archive"])
        await f.press(Key.end.0, keyCode: Key.end.1, modifiers: .shift)
        XCTAssertEqual(f.selected, ["Archive", "a.md", "b.md", "c.md", "d.md", "docs"])

        await f.press(Key.up.0, keyCode: Key.up.1)
        XCTAssertEqual(f.selected, ["c.md"])
        await f.press("a", keyCode: 0, modifiers: .command)
        XCTAssertEqual(f.selected, ["Archive", "a.md", "b.md", "c.md", "d.md", "docs"], "⌘A selects every row")
    }

    func testLeftAndRightArrowsOpenAndCloseFoldersAndClimbToTheParent() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        await f.press(Key.home.0, keyCode: Key.home.1)
        await f.press(Key.down.0, keyCode: Key.down.1)
        XCTAssertEqual(f.selected, ["docs"])

        await f.press(Key.right.0, keyCode: Key.right.1)
        XCTAssertEqual(f.rowPaths, ["Archive", "docs", "docs/deep", "docs/e.md", "docs/f.md", "a.md", "b.md", "c.md", "d.md"], "→ opens the folder")
        XCTAssertEqual(f.selected, ["docs"])
        await f.press(Key.right.0, keyCode: Key.right.1)
        XCTAssertEqual(f.selected, ["docs/deep"], "→ on an open folder selects its first item")
        await f.press(Key.down.0, keyCode: Key.down.1)
        XCTAssertEqual(f.selected, ["docs/e.md"])

        await f.press(Key.left.0, keyCode: Key.left.1)
        XCTAssertEqual(f.selected, ["docs"], "← on a file selects its folder")
        await f.press(Key.left.0, keyCode: Key.left.1)
        XCTAssertFalse(f.rowPaths.contains("docs/e.md"), "← on an open folder closes it")

        await f.press(Key.right.0, keyCode: Key.right.1, modifiers: .option)
        XCTAssertTrue(f.rowPaths.contains("docs/deep/g.md"), "⌥→ opens every folder inside: \(f.rowPaths)")
        await f.press(Key.left.0, keyCode: Key.left.1, modifiers: .command)
        XCTAssertEqual(f.rowPaths, ["Archive", "docs", "a.md", "b.md", "c.md", "d.md"], "⌘← closes every folder")
    }

    func testClosingAFolderTakesItsSelectedItemsOutOfTheSelection() async throws {
        let f = try await makeFixture()
        try await f.click("docs")
        XCTAssertTrue(f.rowPaths.contains("docs/e.md"))
        try await f.click("a.md")
        try await f.click("docs/e.md", modifiers: .command)
        XCTAssertEqual(f.selected, ["a.md", "docs/e.md"])

        await f.press(Key.left.0, keyCode: Key.left.1, modifiers: .command)
        XCTAssertFalse(f.rowPaths.contains("docs/e.md"))
        XCTAssertEqual(f.selected, ["a.md"], "An item the tree no longer shows leaves the selection")

        // ⌘-click adds to exactly what is selected, never to a folder standing in for a hidden item.
        try await f.click("c.md", modifiers: .command)
        XCTAssertEqual(f.selected, ["a.md", "c.md"])
        await f.press(Key.delete.0, keyCode: Key.delete.1, modifiers: .command)
        await idle(f.store)
        XCTAssertEqual(names("docs", in: f.root), ["deep", "e.md", "f.md"], "⌘⌫ never reaches into the closed folder")
        XCTAssertFalse(names("", in: f.root).contains("a.md"))
        XCTAssertFalse(names("", in: f.root).contains("c.md"))
    }

    func testClosingTheFolderOfTheOnlySelectedItemSelectsTheFolder() async throws {
        let f = try await makeFixture()
        try await f.click("docs")
        try await f.click("docs/e.md", modifiers: .command)
        try await f.click("docs", modifiers: .command)
        XCTAssertEqual(f.selected, ["docs/e.md"], "⌘-click took docs out")

        await f.press(Key.home.0, keyCode: Key.home.1)
        try await f.click("docs/e.md")
        try await f.click("docs/f.md", modifiers: .command)
        XCTAssertEqual(f.selected, ["docs/e.md", "docs/f.md"])
        try await f.click("docs", modifiers: .command)
        await f.press(Key.left.0, keyCode: Key.left.1)
        XCTAssertFalse(f.rowPaths.contains("docs/e.md"), "← closes the lead folder")
        XCTAssertEqual(f.selected, ["docs"], "The items it hid leave the selection")
    }

    func testTypingANameSelectsTheRowItStarts() async throws {
        let f = try await makeFixture()
        try await f.click("a.md")
        await f.press("c", keyCode: 8)
        XCTAssertEqual(f.selected, ["c.md"])
        await f.press("D", keyCode: 2, modifiers: .shift)
        // "cD" starts nothing; a pause, then "do" starts docs.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        await f.press("d", keyCode: 2)
        await f.press("o", keyCode: 31)
        XCTAssertEqual(f.selected, ["docs"])
        XCTAssertEqual(f.store.selectedDocumentID, f.path("a.md"), "Typing opens nothing")
    }

    func testCommandDownOpensTheSelectedFiles() async throws {
        let f = try await makeFixture()
        try await f.click("a.md")
        await f.press(Key.down.0, keyCode: Key.down.1)
        await f.press(Key.down.0, keyCode: Key.down.1, modifiers: .shift)
        XCTAssertEqual(f.selected, ["b.md", "c.md"])
        await f.press(Key.down.0, keyCode: Key.down.1, modifiers: .command)
        XCTAssertEqual(f.harness.openedDocumentIDs.suffix(2), [f.path("b.md"), f.path("c.md")], "The lead opens last, so its tab shows")
    }

    func testDuplicateAndMoveToTrashActOnEverySelectedItem() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        try await f.click("c.md", modifiers: .shift)

        await f.press("d", keyCode: 2, modifiers: .command)
        await idle(f.store)
        XCTAssertTrue(names("", in: f.root).isSuperset(of: ["b copy.md", "c copy.md"]), "\(names("", in: f.root))")
        XCTAssertEqual(f.selected, ["b copy.md", "c copy.md"], "The copies are selected")
        XCTAssertEqual(f.store.fileOperationUndo.undoActionName, "Duplicate 2 Items")

        await f.press(Key.delete.0, keyCode: Key.delete.1, modifiers: .command)
        await idle(f.store)
        XCTAssertFalse(names("", in: f.root).contains("b copy.md"))
        XCTAssertFalse(names("", in: f.root).contains("c copy.md"))
        XCTAssertTrue(f.selected.isEmpty, "Nothing is selected once the selection is in the Trash")
        XCTAssertNil(f.store.errorMessage)
    }

    func testMoveToTrashKeepsEverySelectedItemWhenOneHasUnsavedChanges() async throws {
        let f = try await makeFixture()
        f.store.setOpenDocumentIDs([f.path("a.md")])
        _ = await wait { f.store.documentText == "# a.md\n" }
        f.store.setDocumentText("# Unsaved")
        // The open a.md is selected, so ⌘-click adds Archive beside it.
        try await f.click("Archive", modifiers: .command)
        XCTAssertEqual(f.selected, ["Archive", "a.md"])

        await f.press(Key.delete.0, keyCode: Key.delete.1, modifiers: .command)
        XCTAssertEqual(f.store.errorMessage, "Save or close a.md before moving it to the Trash.")
        XCTAssertTrue(names("", in: f.root).isSuperset(of: ["Archive", "a.md"]))
    }

    // MARK: - Menus

    func testARowMenuActsOnTheWholeSelectionOnlyWhenTheRowIsPartOfIt() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        try await f.click("d.md", modifiers: .command)

        let selectedRow = try XCTUnwrap(f.rowPaths.firstIndex(of: "d.md"))
        f.harness.perform("Copy Path", in: f.harness.contextMenu(row: selectedRow))
        XCTAssertEqual(f.harness.copiedPaths.suffix(2).map(\.path), [f.path("b.md"), f.path("d.md")])

        let otherRow = try XCTUnwrap(f.rowPaths.firstIndex(of: "c.md"))
        f.harness.perform("Copy Path", in: f.harness.contextMenu(row: otherRow))
        XCTAssertEqual(f.harness.copiedPaths.last?.path, f.path("c.md"), "A row outside the selection acts on itself")

        f.harness.perform("Move to Trash", in: f.harness.contextMenu(row: selectedRow))
        await idle(f.store)
        XCTAssertFalse(names("", in: f.root).contains("b.md"))
        XCTAssertFalse(names("", in: f.root).contains("d.md"))
        XCTAssertTrue(names("", in: f.root).contains("c.md"))
    }

    /// Right-clicking a row outside a selection of several acts on that row alone: Move to Trash
    /// and Duplicate never reach the selected items, and the selection stays.
    func testARowMenuOutsideTheSelectionTrashesAndDuplicatesOnlyThatRow() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        try await f.click("d.md", modifiers: .command)
        XCTAssertEqual(f.selected, ["b.md", "d.md"])

        let c = try XCTUnwrap(f.rowPaths.firstIndex(of: "c.md"))
        f.harness.perform("Move to Trash", in: f.harness.contextMenu(row: c))
        await idle(f.store)
        XCTAssertNil(f.store.errorMessage)
        XCTAssertEqual(names("", in: f.root), ["Archive", "docs", "a.md", "b.md", "d.md"])
        XCTAssertEqual(f.selected, ["b.md", "d.md"], "The selection stays")

        let a = try XCTUnwrap(f.rowPaths.firstIndex(of: "a.md"))
        f.harness.perform("Duplicate", in: f.harness.contextMenu(row: a))
        await idle(f.store)
        XCTAssertEqual(names("", in: f.root), ["Archive", "docs", "a.md", "a copy.md", "b.md", "d.md"])
    }

    /// Collapsing a folder hands its hidden selection, the open document included, to the folder's
    /// row, so the keys act on what the tree shows selected and never on a hidden file.
    func testCollapsingAFolderGivesItsHiddenSelectionToTheFolderRow() async throws {
        let f = try await makeFixture()
        try await f.click("docs")
        try await f.click("docs/e.md")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("docs/e.md"))
        XCTAssertEqual(f.selected, ["docs/e.md"], "The open document is the selection")
        XCTAssertTrue(f.treeHasFocus())

        await f.press(Key.left.0, keyCode: Key.left.1, modifiers: .command)
        XCTAssertFalse(f.rowPaths.contains("docs/e.md"), "The folder closed")
        XCTAssertEqual(f.selected, ["docs"], "The folder's row holds the selection")
        XCTAssertEqual(f.store.selectedDocumentID, f.path("docs/e.md"), "The document stays open")

        await f.press("d", keyCode: 2, modifiers: .command)
        await idle(f.store)
        XCTAssertTrue(names("", in: f.root).contains("docs copy"), "⌘D duplicates the folder shown selected")
        XCTAssertEqual(names("docs", in: f.root), ["deep", "e.md", "f.md"], "Not the hidden file")
    }

    // MARK: - Dragging

    func testDraggingOneOfSeveralSelectedRowsMovesThemAllAsOneStep() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        try await f.click("c.md", modifiers: .shift)

        await f.harness.drag(from: try f.center(of: "c.md"), to: try f.center(of: "Archive"))
        let moved = await wait { self.names("Archive", in: f.root) == ["keep.md", "b.md", "c.md"] && !f.store.isBusy }
        XCTAssertTrue(moved, "\(names("Archive", in: f.root))")
        XCTAssertEqual(f.selected, ["Archive/b.md", "Archive/c.md"], "The selection follows the items")
        XCTAssertEqual(f.store.fileOperationUndo.undoActionName, "Move 2 Items")

        f.store.undoFileOperation()
        await idle(f.store)
        XCTAssertTrue(names("", in: f.root).isSuperset(of: ["b.md", "c.md"]))
        XCTAssertEqual(names("Archive", in: f.root), ["keep.md"])
    }

    func testOptionDraggingSeveralSelectedRowsCopiesThemAll() async throws {
        let f = try await makeFixture()
        try await f.click("b.md")
        try await f.click("c.md", modifiers: .shift)

        await f.harness.drag(from: try f.center(of: "b.md"), to: try f.center(of: "Archive"), modifiers: .option)
        let copied = await wait { self.names("Archive", in: f.root) == ["keep.md", "b.md", "c.md"] && !f.store.isBusy }
        XCTAssertTrue(copied, "\(names("Archive", in: f.root))")
        XCTAssertTrue(names("", in: f.root).isSuperset(of: ["b.md", "c.md"]), "The originals stay")
        XCTAssertEqual(f.store.fileOperationUndo.undoActionName, "Copy 2 Items")
    }

    func testADropTargetInsideAnyDraggedItemIsRefused() throws {
        let root = URL(fileURLWithPath: "/w", isDirectory: true)
        func node(_ path: String, _ kind: SidebarNode.Kind, _ children: [SidebarNode]? = nil) -> SidebarNode {
            SidebarNode(id: "/w/\(path)", url: URL(fileURLWithPath: "/w/\(path)"), name: (path as NSString).lastPathComponent, relativePath: path, kind: kind, children: children)
        }
        let tree = [
            node("A", .folder, [node("A/in.md", .file)]),
            node("B", .folder, [node("B/x.md", .file)]),
            node("top.md", .file),
        ]
        let rows = SidebarTreePresentation.visibleNodes(from: tree, expandedFolderIDs: ["/w/A", "/w/B"])
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, CGRect(x: 0, y: CGFloat(index) * 28, width: 200, height: 28))
        })
        func target(over rowIndex: Int, dragging urls: [String], copies: Bool = false) -> SidebarMoveDropTarget? {
            SidebarMoveDropTarget.resolve(
                draggedRowID: "/w/top.md",
                draggedItemURLs: urls.map { URL(fileURLWithPath: $0) },
                location: CGPoint(x: 10, y: CGFloat(rowIndex) * 28 + 14),
                rows: rows,
                rowFrames: frames,
                treeSize: CGSize(width: 200, height: 400),
                workspaceURL: root,
                copies: copies
            )
        }
        // Rows: A, A/in.md, B, B/x.md, top.md.
        XCTAssertEqual(target(over: 2, dragging: ["/w/top.md", "/w/A/in.md"]), .folder(URL(fileURLWithPath: "/w/B", isDirectory: true)))
        XCTAssertNil(target(over: 1, dragging: ["/w/top.md", "/w/A"]), "Not into a dragged folder")
        XCTAssertNil(target(over: 1, dragging: ["/w/top.md", "/w/A/in.md"]), "Not onto a dragged row")
        XCTAssertEqual(target(over: 0, dragging: ["/w/top.md", "/w/B/x.md"]), .folder(URL(fileURLWithPath: "/w/A", isDirectory: true)))
        // Where one of them already is still moves the others.
        XCTAssertEqual(target(over: 3, dragging: ["/w/top.md", "/w/B/x.md"]), nil, "onto a dragged row")
        XCTAssertEqual(target(over: 2, dragging: ["/w/top.md", "/w/B/x.md"]), .folder(URL(fileURLWithPath: "/w/B", isDirectory: true)))
    }

    // MARK: - The clipboard

    func testCopyAndPasteOfSeveralItemsCopiesThemAllAsOneStep() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Inbox", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemsOnPasteboard(
            at: [root.appendingPathComponent("a.md"), root.appendingPathComponent("b.md")],
            cutting: false,
            pasteboard: pasteboard
        )
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "One pasteboard item per file, for other apps too")
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Inbox")))
        await idle(store)
        XCTAssertEqual(names("Inbox", in: root), ["a.md", "b.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Copy 2 Items")
        XCTAssertEqual(store.sidebarSelectionIDs.sorted(), [
            root.appendingPathComponent("Inbox/a.md").standardizedFileURL.path,
            root.appendingPathComponent("Inbox/b.md").standardizedFileURL.path,
        ], "The copies are selected")

        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(names("Inbox", in: root), [])
    }

    func testCutAndPasteOfSeveralItemsMovesThemAllAndEndsTheCut() async throws {
        let root = try makeRoot()
        try write("[a](a.md)\n", "Index.md", in: root)
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Inbox", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemsOnPasteboard(
            at: [root.appendingPathComponent("a.md"), root.appendingPathComponent("b.md")],
            cutting: true,
            pasteboard: pasteboard
        )
        XCTAssertTrue(store.hasPendingCut)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Inbox")))
        await settle(store)
        _ = await wait { self.names("Inbox", in: root) == ["a.md", "b.md"] && !store.isBusy }
        XCTAssertEqual(names("Inbox", in: root), ["a.md", "b.md"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8), "[a](Inbox/a.md)\n", "Links follow, as a single move's do")
        XCTAssertFalse(store.hasPendingCut, "The Cut ends")
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move 2 Items")
    }

    // MARK: - Snapshots

    /// With `MONKNOT_SIDEBAR_SELECTION_SNAPSHOT_DIR` set, captures the sidebar with three rows in a
    /// run and one apart selected, in the light and dark themes (needs an awake, unlocked screen).
    func testCaptureTheSelection() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_SIDEBAR_SELECTION_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_SIDEBAR_SELECTION_SNAPSHOT_DIR to capture the selection")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            let root = try makeRoot()
            for file in ["a.md", "b.md", "c.md", "d.md", "e.md"] {
                try write("# \(file)\n", file, in: root)
            }
            let store = try await openStore(root, selecting: "a.md")
            let h = SidebarMenuHarness(store: store, root: root, theme: theme)
            defer { h.close() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let f = Fixture(root: root, store: store, harness: h)
            try await f.click("a.md")
            try await f.click("c.md", modifiers: .shift)
            try await f.click("e.md", modifiers: .command)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(h.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { continue }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("selection-\(name).png"))
        }
    }

    // MARK: - The store

    func testTheSelectionFollowsMovesAndLosesItemsThatAreGone() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Inbox", in: root)
        let store = try await openStore(root)
        let a = root.appendingPathComponent("a.md").standardizedFileURL.path
        let b = root.appendingPathComponent("b.md").standardizedFileURL.path

        store.selectSidebarItems(.items([a, b, root.appendingPathComponent("missing.md").path, root.standardizedFileURL.path]))
        XCTAssertEqual(store.sidebarSelectionIDs, [a, b], "Only items of the tree, never the root, are selected")
        XCTAssertNil(store.selectedFolderID)
        XCTAssertEqual(store.sidebarTargetFolderURL?.standardizedFileURL, root.standardizedFileURL, "New and Paste go beside the lead file")

        store.moveItem(id: a, toDirectory: root.appendingPathComponent("Inbox"))
        await settle(store)
        XCTAssertEqual(store.sidebarSelectionIDs, [root.appendingPathComponent("Inbox/a.md").standardizedFileURL.path, b])

        store.deleteItems(at: [URL(fileURLWithPath: b)])
        await idle(store)
        XCTAssertEqual(store.sidebarSelectionIDs, [root.appendingPathComponent("Inbox/a.md").standardizedFileURL.path], "A trashed item leaves the selection")
    }
}
