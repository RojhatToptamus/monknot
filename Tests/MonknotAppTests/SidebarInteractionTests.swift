import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Sidebar pointer interactions and clipboard/undo command routing.
@MainActor
final class SidebarInteractionTests: WorkspaceStoreTestCase {
    // MARK: - Clipboard target classification

    func testNativeTextTargetClassification() {
        let window = makeWindow()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let webChild = NSView(frame: .zero)
        webView.addSubview(webChild)
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let plain = NSView(frame: .zero)
        [textView, textField, webView, pdfView, plain].forEach { window.contentView?.addSubview($0) }

        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(textView))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(textField))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(webView))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(webChild))
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(plain))
        // A focused PDF gets clipboard commands and Select All through the focused-document path.
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(pdfView))
    }

    // MARK: - Undo routing

    func testUndoAndRedoWithTerminalFocusLeaveTheEditorsEditsAlone() {
        // The terminal shares the window's undo manager, which holds the editor's edits.
        for canPerformNative in [true, false] {
            XCTAssertEqual(
                monknotUndoCommandDestination(
                    isPDFDocumentActive: false,
                    hasNativeEditingFocus: true,
                    terminalHasFocus: true,
                    canPerformNative: canPerformNative,
                    canPerformWorkspaceReplace: true,
                    canPerformPDF: false
                ),
                .unavailable
            )
            XCTAssertEqual(
                monknotUndoCommandDestination(
                    isPDFDocumentActive: true,
                    hasNativeEditingFocus: false,
                    terminalHasFocus: true,
                    canPerformNative: canPerformNative,
                    canPerformPDF: true
                ),
                .unavailable
            )
        }
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: false,
                hasNativeEditingFocus: true,
                terminalHasFocus: false,
                canPerformNative: true,
                canPerformPDF: false
            ),
            .native
        )
    }

    // MARK: - Sidebar drag to move

    func testDragRootFileOntoFolderRowMovesIt() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "other"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        _ = await waitUntil { fixture.listing().contains("other/top.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("top.md") }, ["other/top.md"])
    }

    func testDragOntoFileRowMovesIntoThatFilesFolder() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        _ = await waitUntil { fixture.listing().contains("docs/top.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("top.md") }, ["docs/top.md"])
    }

    func testDragIntoEmptyTreeSpaceMovesToTheRoot() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        let lastRow = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let empty = NSPoint(x: lastRow.midX, y: lastRow.minY - 40)
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: empty)
        _ = await waitUntil { fixture.listing().contains("b.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("b.md") }, ["b.md"])
    }

    func testClickWithoutMovementStillOpensTheFile() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        await fixture.drag(from: NSPoint(x: row.midX, y: row.midY), to: NSPoint(x: row.midX, y: row.midY))
        let opened = await waitUntil {
            fixture.store.selectedDocumentID == fixture.workspaceURL.appendingPathComponent("docs/b.md").path
        }

        XCTAssertTrue(opened)
    }

    // MARK: - Move target resolution

    func testMoveTargetRules() {
        let root = URL(fileURLWithPath: "/workspace")
        let tree = SidebarNode(id: root.path, url: root, name: "workspace", relativePath: "", kind: .folder, children: [
            folder("A", in: root, children: [
                folder("B", in: root.appendingPathComponent("A"), children: [
                    file("deep.md", in: root.appendingPathComponent("A/B")),
                    file("other.md", in: root.appendingPathComponent("A/B")),
                ]),
            ]),
            folder("C", in: root, children: [file("c.md", in: root.appendingPathComponent("C"))]),
            file("top.md", in: root),
        ])
        let rows = SidebarTreePresentation.visibleNodes(
            from: tree.children ?? [],
            expandedFolderIDs: [root.appendingPathComponent("A").path, root.appendingPathComponent("A/B").path, root.appendingPathComponent("C").path]
        )
        XCTAssertEqual(rows.map(\.displayName), ["A/B", "deep.md", "other.md", "C", "c.md", "top.md"])

        var frames: [String: CGRect] = [:]
        for (index, row) in rows.enumerated() {
            frames[row.id] = CGRect(x: 6, y: 6 + CGFloat(index) * 32, width: 200, height: 30)
        }
        func target(_ dragged: String, onto rowName: String) -> SidebarMoveDropTarget? {
            let draggedRow = rows.first { $0.displayName == dragged }!
            let frame = frames[rows.first { $0.displayName == rowName }!.id]!
            return SidebarMoveDropTarget.resolve(
                draggedRowID: draggedRow.id,
                location: CGPoint(x: frame.midX, y: frame.midY),
                rows: rows,
                rowFrames: frames,
                treeSize: CGSize(width: 212, height: 400),
                workspaceURL: root
            )
        }
        func emptySpaceTarget(_ dragged: String, y: CGFloat) -> SidebarMoveDropTarget? {
            SidebarMoveDropTarget.resolve(
                draggedRowID: rows.first { $0.displayName == dragged }!.id,
                location: CGPoint(x: 100, y: y),
                rows: rows,
                rowFrames: frames,
                treeSize: CGSize(width: 212, height: 400),
                workspaceURL: root
            )
        }

        // A compact folder row is its deepest folder.
        XCTAssertEqual(target("top.md", onto: "A/B")?.folderID, root.appendingPathComponent("A/B").path)
        XCTAssertEqual(target("top.md", onto: "c.md")?.folderID, root.appendingPathComponent("C").path)
        XCTAssertEqual(target("deep.md", onto: "top.md"), .root)
        XCTAssertNil(target("deep.md", onto: "other.md"), "Same folder")
        XCTAssertNil(target("deep.md", onto: "deep.md"), "Own row")
        XCTAssertNil(target("A/B", onto: "deep.md"), "Into itself")
        XCTAssertNil(target("A/B", onto: "A/B"), "Own row")
        XCTAssertEqual(target("A/B", onto: "C")?.folderID, root.appendingPathComponent("C").path)
        XCTAssertEqual(emptySpaceTarget("deep.md", y: 300), .root)
        XCTAssertNil(emptySpaceTarget("top.md", y: 300), "Already at the root")
        XCTAssertNil(emptySpaceTarget("deep.md", y: 500), "Below the visible tree")
        XCTAssertNil(emptySpaceTarget("deep.md", y: 37), "Between two rows")

        // A Paste or Finder drop on a row lands where a moved row would.
        XCTAssertEqual(rows.map(\.destinationURL.path), [
            "/workspace/A/B", "/workspace/A/B", "/workspace/A/B", "/workspace/C", "/workspace/C", "/workspace",
        ])
    }

    /// The drag cursor and the drop agree: workspace items move unless Option asks for a copy,
    /// and anything from outside the workspace is copied in.
    func testFinderDropMovesWorkspaceItemsAndCopiesWithOption() {
        let root = URL(fileURLWithPath: "/workspace")
        let inside = [root.appendingPathComponent("Notes/a.md")]
        let outside = [URL(fileURLWithPath: "/elsewhere/b.md")]

        XCTAssertFalse(SidebarFileDrop.copies(inside, workspaceURL: root, isOptionPressed: false))
        XCTAssertTrue(SidebarFileDrop.copies(inside, workspaceURL: root, isOptionPressed: true))
        XCTAssertTrue(SidebarFileDrop.copies(outside, workspaceURL: root, isOptionPressed: false))
        XCTAssertFalse(SidebarFileDrop.copies(inside + outside, workspaceURL: root, isOptionPressed: false))
        XCTAssertTrue(SidebarFileDrop.copies([root], workspaceURL: root, isOptionPressed: false), "The root itself")
        XCTAssertTrue(SidebarFileDrop.copies(
            [URL(fileURLWithPath: "/workspace-other/c.md")], workspaceURL: root, isOptionPressed: false
        ))
        XCTAssertTrue(SidebarFileDrop.copies(inside, workspaceURL: nil, isOptionPressed: false), "No workspace")
    }

    // MARK: - File clipboard

    func testSidebarCopyPastedIntoEditorLinksTheWorkspaceFile() throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotSidebarClipboard")
        let note = root.appendingPathComponent("note.md")
        let other = root.appendingPathComponent("other.md")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)
        try "# Other".write(to: other, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotSidebarClipboard-\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        try WorkspacePasteboardExportService.copyFile(at: other, to: pasteboard)
        let urls = try XCTUnwrap(WorkspacePasteboardExportService.workspaceFileURLs(on: pasteboard))
        let plan = try MarkdownImageAssetService.planFileDrop(urls, workspaceURL: root, markdownDocumentURL: note)

        XCTAssertEqual(plan.items.map(\.isExternal), [false])
    }

    // MARK: - Selection and keyboard focus

    /// Clicking a folder selects it and moves keyboard focus from the editor to the tree, so the
    /// Edit menu's Paste, which goes to the editor while the editor has focus, pastes into it.
    func testClickingAFolderSelectsItAndPastesIntoIt() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotSidebarSelection-\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.editor))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(fixture.editor))
        let openDocument = fixture.store.selectedDocumentID
        XCTAssertFalse(fixture.expandedFolderIDs.contains(fixture.path("other")))

        try await fixture.click(rowNamed: "other")

        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("other"))
        XCTAssertEqual(fixture.store.selectedDocumentID, openDocument, "The open document stays open")
        XCTAssertTrue(fixture.treeHasFocus())
        let responder = try XCTUnwrap(fixture.window.firstResponder)
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(responder))
        XCTAssertEqual(fixture.store.sidebarTargetFolderURL?.path, fixture.path("other"))

        // A second click closes the folder and keeps it selected; a paste opens it to show the copy.
        try await fixture.click(rowNamed: "other")
        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("other"))
        XCTAssertFalse(fixture.expandedFolderIDs.contains(fixture.path("other")))

        fixture.store.putItemOnPasteboard(
            at: fixture.workspaceURL.appendingPathComponent("top.md"),
            cutting: false,
            pasteboard: pasteboard
        )
        XCTAssertTrue(fixture.store.pasteFromPasteboard(pasteboard, into: fixture.store.sidebarTargetFolderURL))
        let pasted = await waitUntil { fixture.listing().contains("other/top.md") && !fixture.store.isBusy }
        XCTAssertTrue(pasted)
        XCTAssertEqual(fixture.store.selectedDocumentID, fixture.path("other/top.md"))
        let revealed = await waitUntil { fixture.expandedFolderIDs.contains(fixture.path("other")) }
        XCTAssertTrue(revealed, "The folder the copy landed in opens")
    }

    func testClickingADocumentSelectsItAndTargetsItsFolder() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }

        try await fixture.click(rowNamed: "other")
        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("other"))
        // "other" is open now, so b.md sits a row lower than the fixture's first layout.
        try await fixture.click(rowNamed: "b.md")

        XCTAssertNil(fixture.store.selectedFolderID, "Opening a document moves the selection to it")
        XCTAssertEqual(fixture.store.selectedDocumentID, fixture.path("docs/b.md"))
        XCTAssertEqual(fixture.store.sidebarTargetFolderURL?.path, fixture.path("docs"))

        // The window's open action hands focus on to a document shown for typing.
        XCTAssertTrue(fixture.treeHasFocus())
        let document = try XCTUnwrap(fixture.store.selectedDocument)
        XCTAssertTrue(SidebarDocumentOpenFocus.movesFocusToDocument(document, editorMode: .source, isSplitViewEnabled: false))
        TerminalFocusRestorer.focusVisibleDocument(in: fixture.window)
        let editorFocused = await waitUntil { fixture.window.firstResponder === fixture.editor }
        XCTAssertTrue(editorFocused)
    }

    /// Only a document shown for typing takes focus from the tree when chosen there. Anything else
    /// leaves focus in the tree, where ⌘C, ⌘X and ⌘V act on the selected file.
    func testOnlyADocumentShownForTypingTakesFocusFromTheTree() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        func takesFocus(_ name: String, _ mode: EditorMode, split: Bool = false) -> Bool {
            SidebarDocumentOpenFocus.movesFocusToDocument(
                WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root),
                editorMode: mode,
                isSplitViewEnabled: split
            )
        }

        XCTAssertTrue(takesFocus("note.md", .source))
        XCTAssertTrue(takesFocus("note.md", .preview, split: true), "Its source shows beside the preview")
        XCTAssertTrue(takesFocus("note.md", .preview), "Preview edits Markdown in place")
        XCTAssertTrue(takesFocus("notes.txt", .preview), "Text has no preview")
        XCTAssertTrue(takesFocus("page.html", .source))
        XCTAssertFalse(takesFocus("page.html", .preview))
        for name in ["photo.png", "paper.pdf", "clip.mov", "tone.wav"] {
            XCTAssertFalse(takesFocus(name, .source), name)
        }
    }

    /// ⌘D and Return act on the selection only while the tree has keyboard focus; with the editor
    /// focused they are the editor's keys.
    func testTreeKeysActOnlyWhileTheTreeHasFocus() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        try await fixture.click(rowNamed: "other")
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.editor))

        fixture.press("d", keyCode: 2, modifiers: .command)
        fixture.press("\r", keyCode: 36)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(fixture.listing().contains("other copy"), "⌘D in the editor duplicated the folder")
        XCTAssertNil(fixture.window.attachedSheet, "Return in the editor began a rename")

        try await fixture.click(rowNamed: "other")
        XCTAssertTrue(fixture.treeHasFocus())
        fixture.press("d", keyCode: 2, modifiers: .command)
        let duplicated = await waitUntil { fixture.listing().contains("other copy") && !fixture.store.isBusy }
        XCTAssertTrue(duplicated)
        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("other copy"), "The duplicate is selected")

        fixture.press("\r", keyCode: 36)
        let renaming = await waitUntil { fixture.window.attachedSheet != nil }
        XCTAssertTrue(renaming, "Return renames the selected item")
    }

    /// ⌘⌫ moves the selected folder to the Trash through the menu command's guards: a folder that
    /// holds an unsaved open document stays.
    func testMoveToTrashKeyUsesTheMenuCommandsGuards() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let a = fixture.path("docs/a.md")
        fixture.store.setOpenDocumentIDs([a])
        fixture.store.setDocumentText("# Unsaved")
        XCTAssertFalse(fixture.store.saveState(for: a).isClean)

        try await fixture.click(rowNamed: "docs")
        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("docs"))
        fixture.press("\u{7F}", keyCode: 51, modifiers: .command)

        XCTAssertEqual(fixture.store.errorMessage, "Save or close a.md before moving docs to the Trash.")
        XCTAssertTrue(fixture.listing().contains("docs/a.md"))
    }

    /// Holding ⌘⌫ on a selected folder trashes that folder alone: the key's repeats are ignored,
    /// and nothing is selected afterwards, so a second press finds nothing to trash rather than
    /// the folder above it.
    func testHoldingMoveToTrashTrashesOnlyTheSelectedFolder() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        try await fixture.click(rowNamed: "inner")
        XCTAssertEqual(fixture.store.selectedFolderID, fixture.path("docs/inner"))

        fixture.press("\u{7F}", keyCode: 51, modifiers: .command, repeats: 5)
        let trashed = await waitUntil { !fixture.listing().contains("docs/inner") && !fixture.store.isBusy }
        XCTAssertTrue(trashed)
        XCTAssertNil(fixture.store.selectedFolderID, "The folder above is not selected")
        XCTAssertNil(fixture.store.sidebarSelectionID)

        fixture.press("\u{7F}", keyCode: 51, modifiers: .command, repeats: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            fixture.listing().filter { !$0.hasPrefix(".") },
            ["docs", "docs/a.md", "docs/b.md", "other", "other/x.md", "top.md"]
        )
    }

    /// ⌘⌫ on the open document trashes it alone: the document shown next is not selected in the
    /// tree, so the next ⌘⌫ trashes nothing.
    func testMoveToTrashOfTheOpenDocumentLeavesNothingSelected() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        try await fixture.click(rowNamed: "b.md")
        XCTAssertEqual(fixture.store.sidebarSelectionID, fixture.path("docs/b.md"))
        XCTAssertTrue(fixture.treeHasFocus())

        fixture.press("\u{7F}", keyCode: 51, modifiers: .command, repeats: 5)
        let trashed = await waitUntil { !fixture.listing().contains("docs/b.md") && !fixture.store.isBusy }
        XCTAssertTrue(trashed)
        XCTAssertNil(fixture.store.selectedDocumentID, "No other document is opened in its place")
        XCTAssertNil(fixture.store.sidebarSelectionID)
        XCTAssertNil(fixture.store.sidebarTargetFolderURL, "New items go to the root")

        // The window's tabs show another document without selecting it in the tree.
        XCTAssertTrue(fixture.store.selectDocument(id: fixture.path("docs/a.md"), selectingInSidebar: false))
        XCTAssertNil(fixture.store.sidebarSelectionID)
        fixture.press("\u{7F}", keyCode: 51, modifiers: .command)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            fixture.listing().filter { !$0.hasPrefix(".") },
            ["docs", "docs/a.md", "docs/inner", "docs/inner/c.md", "other", "other/x.md", "top.md"]
        )

        // Choosing the document selects it again.
        XCTAssertTrue(fixture.store.selectDocument(id: fixture.path("docs/a.md")))
        XCTAssertEqual(fixture.store.sidebarSelectionID, fixture.path("docs/a.md"))
    }

    /// File ▸ New Folder asks for a name for the sidebar's target folder.
    func testNewFolderCommandAsksForANameInTheSidebar() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        try await fixture.click(rowNamed: "other")

        fixture.newItemRequest.value = .folder
        let prompted = await waitUntil { fixture.window.attachedSheet != nil }
        XCTAssertTrue(prompted)
        XCTAssertNil(fixture.newItemRequest.value, "The request is answered once")
    }

    /// The tree takes keyboard focus only when clicked, so a newly shown document still claims it.
    func testTreeDoesNotTakeFocusUntilClicked() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }

        XCTAssertFalse(fixture.treeHasFocus())
    }

    // MARK: - Helpers

    private func folder(_ name: String, in parent: URL, children: [SidebarNode]) -> SidebarNode {
        let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        return SidebarNode(id: url.path, url: url, name: name, relativePath: name, kind: .folder, children: children)
    }

    private func file(_ name: String, in parent: URL) -> SidebarNode {
        let url = parent.appendingPathComponent(name).standardizedFileURL
        return SidebarNode(id: url.path, url: url, name: name, relativePath: name, kind: .file)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    private func waitUntil(timeout: TimeInterval = 4, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeSidebarFixture() async throws -> SidebarFixture {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotSidebarDrag")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        for path in ["docs/a.md", "docs/b.md", "docs/inner/c.md", "other/x.md", "top.md"] {
            try "# \(path)".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: root.appendingPathComponent("docs/a.md"))
        let opened = await waitUntil { store.documents.count == 5 && !store.isBusy && store.rootNode != nil }
        XCTAssertTrue(opened)

        let defaults = UserDefaults(suiteName: "Monknot.SidebarDrag.\(UUID().uuidString)")!
        let newItemRequest = NewItemRequestBox()
        let library = WorkspaceLibraryStore(userDefaults: defaults)
        let search = WorkspaceSearchState()
        let view = SidebarFixtureRoot(requests: newItemRequest) { newItemRequest in
            SidebarView(
                store: store,
                workspaceLibrary: library,
                workspaceSearch: search,
                searchOptions: .constant(MonknotSearchOptions()),
                theme: .defaultDark,
                zoomScale: 1,
                openFolder: {},
                switchWorkspace: { _ in },
                removeWorkspace: { _ in },
                manageWorkspaces: {},
                newMarkdown: {},
                exportPDF: { _ in },
                openDocument: { id in _ = store.selectDocument(id: id) },
                openWorkspaceSearchResult: { _ in },
                showWorkspaceSearch: {},
                dismissWorkspaceSearch: {},
                workspaceSearchFocusChanged: { _ in },
                copyPath: { _ in },
                copyRelativePath: { _ in },
                newItemRequest: newItemRequest
            )
        }
        .frame(width: 280, height: 600)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        // The document beside the sidebar, holding keyboard focus as an open editor does.
        let editor = NSTextView(frame: NSRect(x: 280, y: 0, width: 200, height: 600))
        editor.identifier = .monknotDocumentFocusTarget
        editor.string = "Editor text"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        content.addSubview(host)
        content.addSubview(editor)
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        return SidebarFixture(
            window: window,
            host: host,
            editor: editor,
            store: store,
            workspaceURL: root,
            newItemRequest: newItemRequest
        )
    }
}

@MainActor
private final class NewItemRequestBox: ObservableObject {
    @Published var value: SidebarNewItemRequest?
}

/// Hosts the sidebar with its New File and New Folder request bound to `requests`.
private struct SidebarFixtureRoot: View {
    @ObservedObject var requests: NewItemRequestBox
    let sidebar: (Binding<SidebarNewItemRequest?>) -> SidebarView

    var body: some View {
        sidebar($requests.value)
    }
}

@MainActor
private struct SidebarFixture {
    let window: NSWindow
    let host: NSView
    let editor: NSTextView
    let store: WorkspaceStore
    let workspaceURL: URL
    let newItemRequest: NewItemRequestBox

    func close() {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
        window.contentView = nil
        UserDefaults.standard.removeObject(forKey: WorkspaceTreeExpansionPersistence().key(for: workspaceURL))
    }

    func path(_ relativePath: String) -> String {
        workspaceURL.appendingPathComponent(relativePath).standardizedFileURL.path
    }

    /// The folders the sidebar has open, as it saves them for the workspace.
    var expandedFolderIDs: Set<String> {
        WorkspaceTreeExpansionPersistence().load(for: workspaceURL) ?? []
    }

    /// The tree's hosting view, which holds keyboard focus while the sidebar has it.
    func treeHasFocus() -> Bool {
        guard let documentView = treeDocumentView() else { return false }
        return window.firstResponder === documentView
    }

    func click(rowNamed name: String) async throws {
        let frame = try XCTUnwrap(frameOfRow(labelPrefix: name), "No row named \(name)")
        let point = NSPoint(x: frame.midX, y: frame.midY)
        await drag(from: point, to: point)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Sends a key press to the window, as AppKit delivers it to the focused view; `repeats`
    /// adds the key-down repeats of a held key.
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], repeats: Int = 0) {
        let types = [NSEvent.EventType.keyDown] + Array(repeating: .keyDown, count: repeats) + [.keyUp]
        for (index, type) in types.enumerated() {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: type == .keyDown && index > 0,
                keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func treeDocumentView() -> NSView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil,
               String(describing: type(of: scroll)).contains("SidebarNativeScrollView") {
                return scroll
            }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host)?.documentView
    }

    func visibleRows() -> [VisibleSidebarNode] {
        SidebarTreePresentation.visibleNodes(
            from: store.rootNode?.children ?? [],
            expandedFolderIDs: expandedFolderIDs
        )
    }

    func listing() -> [String] {
        (FileManager.default.subpaths(atPath: workspaceURL.path) ?? []).sorted()
    }

    /// Window-coordinate frame of the row named `labelPrefix`, from the sidebar's row geometry.
    func frameOfRow(labelPrefix: String) -> NSRect? {
        guard let documentView = treeDocumentView(),
              let index = visibleRows().firstIndex(where: { $0.displayName == labelPrefix })
        else { return nil }
        let theme = AppTheme.defaultDark
        let rowHeight = MonknotMetrics.scale(MonknotMetrics.rowHeightBase, theme: theme, zoomScale: 1)
        let spacing = MonknotMetrics.scale(MonknotMetrics.rowGapBase, theme: theme, zoomScale: 1)
        let top = MonknotMetrics.scale(MonknotMetrics.listGutterBase, theme: theme, zoomScale: 1)
        let y = top + CGFloat(index) * (rowHeight + spacing)
        let local = NSRect(x: 20, y: y, width: documentView.bounds.width - 40, height: rowHeight)
        let flippedLocal = documentView.isFlipped
            ? local
            : NSRect(x: local.minX, y: documentView.bounds.height - local.maxY, width: local.width, height: local.height)
        return documentView.convert(flippedLocal, to: nil)
    }

    /// Mouse down at `start`, twelve drag steps, mouse up at `end`; equal points make a click.
    func drag(from start: NSPoint, to end: NSPoint) async {
        var timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent? {
            timestamp += 0.016
            return NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        guard let down = event(.leftMouseDown, start, 1) else { return }
        window.sendEvent(down)
        try? await Task.sleep(nanoseconds: 30_000_000)
        if start != end {
            let steps = 12
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                if let dragged = event(.leftMouseDragged, point, 1 + step) {
                    window.sendEvent(dragged)
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        if let up = event(.leftMouseUp, end, 100) {
            window.sendEvent(up)
        }
    }
}
