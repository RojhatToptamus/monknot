import AppKit
import MonknotCore
import XCTest
@testable import MonknotApp

/// Edit › Undo and Redo for the moves and copies made in the sidebar (design.md §10.4), on real
/// stores over temporary workspaces: each undo checks the disk still matches what the operation
/// left, and refuses rather than overwrite.
@MainActor
final class WorkspaceFileOperationUndoTests: FileOperationsTestCase {
    private func url(_ relativePath: String, in root: URL) -> URL {
        root.appendingPathComponent(relativePath).standardizedFileURL
    }

    private func text(_ relativePath: String, in root: URL) -> String? {
        try? String(contentsOf: url(relativePath, in: root), encoding: .utf8)
    }

    private func exists(_ relativePath: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath, in: root).path)
    }

    // MARK: - Moves

    func testUndoPutsAMovedFileBackAndRedoMovesItAgain() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let original = url("a.md", in: root).path
        let moved = url("Archive/a.md", in: root).path
        XCTAssertEqual(store.selectedDocumentID, original)
        XCTAssertFalse(store.canUndoFileOperation)

        XCTAssertTrue(store.moveItem(id: original, toDirectory: url("Archive", in: root)))
        await settle(store)
        XCTAssertEqual(names("Archive", in: root), ["a.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move “a.md”")
        XCTAssertTrue(store.canUndoFileOperation)
        XCTAssertEqual(store.selectedDocumentID, moved)

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(text("a.md", in: root), "# a\n")
        XCTAssertEqual(names("Archive", in: root), [])
        XCTAssertEqual(store.selectedDocumentID, original, "The open document follows its file back")
        XCTAssertEqual(store.documentIDRemapEvent?.itemSourcePath, moved, "Open tabs follow it too")
        XCTAssertEqual(store.documentIDRemapEvent?.itemDestinationPath, original)
        XCTAssertEqual(store.fileOperationLanding?.itemID, original, "It lands in the tree as a dropped item does")
        XCTAssertNil(store.fileOperationUndo.undoActionName)
        XCTAssertEqual(store.fileOperationUndo.redoActionName, "Move “a.md”")

        store.redoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Archive", in: root), ["a.md"])
        XCTAssertFalse(exists("a.md", in: root))
        XCTAssertEqual(store.selectedDocumentID, moved)
        XCTAssertEqual(store.fileOperationLanding?.itemID, moved)
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move “a.md”")
        XCTAssertNil(store.fileOperationUndo.redoActionName)
    }

    func testUnsavedTextGoesBackWithTheMovedDocument() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "a.md")
        _ = await wait { store.documentText == "# a\n" }
        store.setDocumentText("# a, edited\n")
        let original = url("a.md", in: root).path

        store.moveItem(id: original, toDirectory: url("Archive", in: root))
        await settle(store)
        store.undoFileOperation()
        await idle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedDocumentID, original)
        XCTAssertEqual(store.documentText, "# a, edited\n")
        XCTAssertFalse(store.saveState(for: original).isClean, "The edit is still unsaved")
        XCTAssertEqual(text("a.md", in: root), "# a\n", "Undo never writes the unsaved edit")
    }

    func testUndoingAMoveThatUpdatedLinksPutsTheLinksBack() async throws {
        let root = try makeRoot()
        try write("[a](a.md)\n", "Index.md", in: root)
        try write("[index](Index.md)\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        let reviewShown = await wait { !store.isBusy && store.pendingMarkdownLinkMoveReview != nil }
        XCTAssertTrue(reviewShown, "A move that rewrites links asks first")
        await settle(store)
        XCTAssertEqual(text("Index.md", in: root), "[a](Archive/a.md)\n")
        XCTAssertEqual(text("Archive/a.md", in: root), "[index](../Index.md)\n", "The moved note's own links follow it")
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move “a.md”")

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.pendingMarkdownLinkMoveReview, "Undo puts back exactly what the move wrote, without asking")
        XCTAssertEqual(text("Index.md", in: root), "[a](a.md)\n")
        XCTAssertEqual(text("a.md", in: root), "[index](Index.md)\n")
        XCTAssertFalse(exists("Archive/a.md", in: root))

        store.redoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(text("Index.md", in: root), "[a](Archive/a.md)\n")
        XCTAssertEqual(text("Archive/a.md", in: root), "[index](../Index.md)\n")
        XCTAssertFalse(exists("a.md", in: root))
    }

    func testRenameIsUndoneByName() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root)
        let document = try XCTUnwrap(doc(store, "a.md"))

        store.renameDocument(id: document.id, to: "b.md")
        await settle(store)
        XCTAssertEqual(names("", in: root), ["b.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Rename “a.md”")

        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(names("", in: root), ["a.md"])
    }

    func testCutAndPasteIsUndoneAsAMove() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("docs", in: root)
        let store = try await openStore(root)

        store.cutItem(at: url("a.md", in: root))
        store.pasteDocumentTransfer(into: url("docs", in: root))
        await settle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move “a.md”")

        store.undoFileOperation()
        await idle(store)
        XCTAssertTrue(exists("a.md", in: root))
        XCTAssertEqual(names("docs", in: root), [])
    }

    func testACutPastedFromAnotherWorkspaceGoesBackThere() async throws {
        let first = try makeRoot()
        try write("# a\n", "a.md", in: first)
        let second = try makeRoot()
        try mkdir("Inbox", in: second)
        let cutting = try await openStore(first)
        let pasting = try await openStore(second)

        cutting.cutItem(at: url("a.md", in: first))
        pasting.pasteCut(from: cutting, into: url("Inbox", in: second))
        await idle(pasting)
        XCTAssertEqual(names("Inbox", in: second), ["a.md"])
        XCTAssertEqual(pasting.fileOperationUndo.undoActionName, "Move “a.md”")

        pasting.undoFileOperation()
        await idle(pasting)
        XCTAssertNil(pasting.errorMessage)
        XCTAssertEqual(text("a.md", in: first), "# a\n")
        XCTAssertEqual(names("Inbox", in: second), [])
        XCTAssertNil(pasting.documents.first { $0.displayName == "a.md" }, "It left this workspace")

        pasting.redoFileOperation()
        await idle(pasting)
        XCTAssertEqual(names("Inbox", in: second), ["a.md"])
        XCTAssertFalse(exists("a.md", in: first))
    }

    func testADropOfSeveralItemsIsUndoneAsOneStep() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.dropFileURLs([url("a.md", in: root), url("b.md", in: root)], into: url("Archive", in: root))
        let dropped = await wait { !store.isBusy && store.canUndoFileOperation }
        XCTAssertTrue(dropped)
        XCTAssertEqual(names("Archive", in: root), ["a.md", "b.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move 2 Items")

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(exists("a.md", in: root))
        XCTAssertTrue(exists("b.md", in: root))
        XCTAssertEqual(names("Archive", in: root), [])
        XCTAssertEqual(store.documentIDRemapEvent?.itemMoves.count, 2, "One event names every item that moved back")
        XCTAssertNil(store.fileOperationUndo.undoActionName, "The whole drop was one step")
        XCTAssertEqual(store.fileOperationUndo.redoActionName, "Move 2 Items")

        store.redoFileOperation()
        await idle(store)
        XCTAssertEqual(names("Archive", in: root), ["a.md", "b.md"])
    }

    func testANewMoveEndsWhatRedoHeld() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(store.fileOperationUndo.redoActionName, "Move “a.md”")

        store.moveItem(id: url("b.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertNil(store.fileOperationUndo.redoActionName)
        XCTAssertFalse(store.canRedoFileOperation)
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Move “b.md”")
    }

    // MARK: - Copies

    func testUndoPutsADuplicateInTheTrashAndRedoMakesItAgain() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root, selecting: "a.md")

        store.duplicateItem(at: url("a.md", in: root))
        await idle(store)
        let copy = url("a copy.md", in: root).path
        XCTAssertEqual(text("a copy.md", in: root), "# a\n")
        XCTAssertEqual(store.selectedDocumentID, copy)
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Duplicate “a.md”")

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("", in: root), ["a.md"], "The copy went to the Trash")
        XCTAssertNotEqual(store.selectedDocumentID, copy)
        XCTAssertEqual(store.fileOperationUndo.redoActionName, "Duplicate “a.md”")

        store.redoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(text("a copy.md", in: root), "# a\n")
        XCTAssertEqual(store.selectedDocumentID, copy, "The copy made again is selected, as Duplicate selects it")
        XCTAssertEqual(store.fileOperationLanding?.itemID, copy)
    }

    func testACopyIntoAnotherFolderIsNamedCopy() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("docs", in: root)
        let store = try await openStore(root)

        // Option-drag onto another folder.
        store.duplicateItem(at: url("a.md", in: root), into: url("docs", in: root))
        await idle(store)
        XCTAssertEqual(names("docs", in: root), ["a.md"])
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Copy “a.md”")

        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(names("docs", in: root), [])
        XCTAssertEqual(text("a.md", in: root), "# a\n", "The original stays")
    }

    func testUndoRefusesToTrashACopyWithUnsavedChanges() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root)

        store.duplicateItem(at: url("a.md", in: root))
        await idle(store)
        _ = await wait { store.documentText == "# a\n" && store.selectedDocumentID == self.url("a copy.md", in: root).path }
        store.setDocumentText("# a, edited in the copy\n")

        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(store.errorMessage?.contains("Save or close a copy.md first"), true, store.errorMessage ?? "")
        XCTAssertTrue(exists("a copy.md", in: root))
        XCTAssertTrue(store.canUndoFileOperation, "Saving or closing it lets the undo go ahead")
    }

    // MARK: - Refusals

    func testUndoRefusesWhenSomethingTookTheOldName() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)

        try write("a newer a\n", "a.md", in: root)
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not undo Move “a.md”: Another item is now named “a.md” in “\(root.lastPathComponent)”.")
        XCTAssertEqual(text("a.md", in: root), "a newer a\n", "Nothing is overwritten")
        XCTAssertEqual(text("Archive/a.md", in: root), "# a\n")
        XCTAssertFalse(store.canUndoFileOperation, "The disk no longer matches the move, so it leaves the history")
    }

    func testUndoRefusesWhenTheMovedItemIsGone() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)

        try FileManager.default.removeItem(at: url("Archive/a.md", in: root))
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not undo Move “a.md”: “a.md” is no longer in “Archive”.")
        XCTAssertFalse(exists("a.md", in: root))
    }

    func testUndoRefusesWhenALinkedNoteChangedAndChangesNothing() async throws {
        let root = try makeRoot()
        try write("[a](a.md)\n", "Index.md", in: root)
        try write("[a again](a.md)\n", "Other.md", in: root)
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertEqual(text("Index.md", in: root), "[a](Archive/a.md)\n")
        XCTAssertEqual(text("Other.md", in: root), "[a again](Archive/a.md)\n")

        try write("[a](Archive/a.md)\nA line added since.\n", "Other.md", in: root)
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not undo Move “a.md”: “Other.md” changed after the move updated its links.")
        XCTAssertEqual(text("Index.md", in: root), "[a](Archive/a.md)\n", "No link is put back unless every one can be")
        XCTAssertEqual(text("Other.md", in: root), "[a](Archive/a.md)\nA line added since.\n")
        XCTAssertTrue(exists("Archive/a.md", in: root))
        XCTAssertFalse(exists("a.md", in: root))
    }

    func testUndoRefusesWhileALinkedNoteHasUnsavedChanges() async throws {
        let root = try makeRoot()
        try write("[a](a.md)\n", "Index.md", in: root)
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)

        let index = url("Index.md", in: root).path
        _ = store.selectDocument(id: index)
        _ = await wait { store.documentText == "[a](Archive/a.md)\n" }
        store.setDocumentText("[a](Archive/a.md)\nTyping.\n")
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not undo Move “a.md”: Save Index.md first: undoing this move updates the links in it.")
        XCTAssertTrue(exists("Archive/a.md", in: root))
        XCTAssertTrue(store.canUndoFileOperation, "Saving lets the undo go ahead")
    }

    func testRedoRefusesWhenTheNameIsTakenAgain() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        store.undoFileOperation()
        await idle(store)

        try write("another a\n", "Archive/a.md", in: root)
        store.redoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not redo Move “a.md”: Another item is now named “a.md” in “Archive”.")
        XCTAssertEqual(text("a.md", in: root), "# a\n")
        XCTAssertEqual(text("Archive/a.md", in: root), "another a\n")
    }

    func testOpeningAnotherWorkspaceEndsTheHistory() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let other = try makeRoot()
        try write("# o\n", "o.md", in: other)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertTrue(store.canUndoFileOperation)

        store.openWorkspace(other)
        _ = await wait { !store.isBusy && store.workspaceURL == other }
        XCTAssertFalse(store.canUndoFileOperation)
        XCTAssertNil(store.fileOperationUndo.undoActionName)
    }

    // MARK: - Order against a workspace Replace

    func testTheNewerOfAMoveAndAReplaceIsUndoneFirst() async throws {
        let root = try makeRoot()
        try write("alpha beta\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertTrue(store.fileOperationUndo.undoPrecedesWorkspaceReplace)

        store.replaceInWorkspace(find: "beta", replacement: "gamma")
        _ = await wait { !store.isBusy && store.canUndoWorkspaceReplace }
        XCTAssertFalse(store.fileOperationUndo.undoPrecedesWorkspaceReplace, "The Replace is newer")

        store.undoLastWorkspaceReplace()
        _ = await wait { !store.isBusy && !store.canUndoWorkspaceReplace }
        XCTAssertTrue(store.fileOperationUndo.undoPrecedesWorkspaceReplace)
        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(text("a.md", in: root), "alpha beta\n")
    }

    // MARK: - Edit menu routing

    func testEditUndoTakesFileOperationsOnlyFromTheSidebarOrAnUnfocusedWindow() {
        func destination(
            pdf: Bool = false,
            text: Bool = false,
            terminal: Bool = false,
            document: Bool = false,
            native: Bool = false,
            replace: Bool = false,
            file: Bool = true,
            fileIsNewer: Bool = true,
            pdfUndo: Bool = false
        ) -> MonknotUndoCommandDestination {
            monknotUndoCommandDestination(
                isPDFDocumentActive: pdf,
                hasNativeEditingFocus: text,
                terminalHasFocus: terminal,
                documentViewHasFocus: document,
                canPerformNative: native,
                canPerformWorkspaceReplace: replace,
                canPerformFileOperation: file,
                fileOperationIsNewer: fileIsNewer,
                canPerformPDF: pdfUndo
            )
        }

        // The sidebar, or the window with nothing focused.
        XCTAssertEqual(destination(), .fileOperation)
        XCTAssertEqual(destination(native: true), .fileOperation, "Newer than the window's own undo")
        XCTAssertEqual(destination(native: true, file: false), .native)
        XCTAssertEqual(destination(pdf: true, pdfUndo: true), .fileOperation, "The sidebar has focus beside a PDF")
        // Source and Preview keep ⌘Z, even with nothing left to undo.
        XCTAssertEqual(destination(text: true, native: true), .native)
        XCTAssertEqual(destination(text: true), .unavailable)
        XCTAssertEqual(destination(text: true, replace: true), .workspaceReplace, "Replace All's promise stands")
        // The terminal and a focused document keep theirs.
        XCTAssertEqual(destination(terminal: true), .unavailable)
        XCTAssertEqual(destination(pdf: true, document: true, pdfUndo: true), .pdf)
        XCTAssertEqual(destination(pdf: true, document: true), .unavailable)
        // The newer of a move and a Replace.
        XCTAssertEqual(destination(replace: true, fileIsNewer: true), .fileOperation)
        XCTAssertEqual(destination(replace: true, fileIsNewer: false), .workspaceReplace)
    }

    // MARK: - The sidebar

    func testAnUndoneMoveLandsBackInTheTreeWithItsFoldersOpen() async throws {
        let root = try makeRoot()
        try write("# deep\n", "other/inner/deep.md", in: root)
        try write("# top\n", "top.md", in: root)
        // With a root file open, the tree first shows its folders closed.
        let store = try await openStore(root, selecting: "top.md")
        let h = await harness(store, root)
        defer { h.close() }
        XCTAssertFalse(h.visibleRowPaths(maxRows: 20).contains("other/inner/deep.md"), "\(h.visibleRowPaths(maxRows: 20))")

        store.moveItem(id: url("other/inner/deep.md", in: root).path, toDirectory: nil)
        await settle(store)
        let movedOut = await wait { h.visibleRowPaths(maxRows: 20).contains("deep.md") }
        XCTAssertTrue(movedOut, "\(h.visibleRowPaths(maxRows: 20))")

        store.undoFileOperation()
        await idle(store)
        let shown = await wait { h.visibleRowPaths(maxRows: 20).contains("other/inner/deep.md") }
        XCTAssertTrue(shown, "The folders it goes back into open to show it: \(h.visibleRowPaths(maxRows: 20))")
        XCTAssertFalse(h.visibleRowPaths(maxRows: 20).contains("deep.md"))
    }
}
