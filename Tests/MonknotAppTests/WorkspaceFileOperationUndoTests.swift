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

    func testMovingANoteAReplaceChangedEndsTheReplacesUndo() async throws {
        let root = try makeRoot()
        try write("alpha beta\n", "a.md", in: root)
        try write("other text\n", "b.md", in: root)
        try write("# untouched\n", "c.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.replaceInWorkspace(find: "beta", replacement: "gamma")
        _ = await wait { !store.isBusy && store.canUndoWorkspaceReplace }
        store.moveItem(id: url("c.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertTrue(store.canUndoWorkspaceReplace, "A move of a note the Replace left alone keeps its undo")
        XCTAssertTrue(store.fileOperationUndo.undoPrecedesWorkspaceReplace)

        // Rename a.md away and b.md into its name: the Replace's undo would write the old a.md over b.
        store.renameDocument(id: try XCTUnwrap(doc(store, "a.md")).id, to: "moved.md")
        await settle(store)
        XCTAssertFalse(store.canUndoWorkspaceReplace, "Renaming a note the Replace changed ends its undo")
        store.renameDocument(id: try XCTUnwrap(doc(store, "b.md")).id, to: "a.md")
        await settle(store)
        store.undoLastWorkspaceReplace()
        await idle(store)
        XCTAssertEqual(text("a.md", in: root), "other text\n", "Nothing is written over the note now named a.md")
        XCTAssertEqual(text("moved.md", in: root), "alpha gamma\n")
    }

    func testTrashingANoteAReplaceChangedEndsTheReplacesUndo() async throws {
        let root = try makeRoot()
        try write("alpha beta\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        let store = try await openStore(root)
        store.replaceInWorkspace(find: "beta", replacement: "gamma")
        _ = await wait { !store.isBusy && store.canUndoWorkspaceReplace }

        store.deleteDocument(try XCTUnwrap(doc(store, "a.md")))
        await idle(store)
        XCTAssertFalse(store.canUndoWorkspaceReplace)
    }

    // MARK: - Unsaved text

    func testUndoWaitsWhileAnUnsavedNoteLinksToTheMovedItem() async throws {
        let root = try makeRoot()
        try write("# Index\n", "Index.md", in: root)
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)

        _ = store.selectDocument(id: url("Index.md", in: root).path)
        _ = await wait { store.documentText == "# Index\n" }
        store.setDocumentText("# Index\n[a](Archive/a.md)\n")
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(
            store.errorMessage,
            "Could not undo Move “a.md”: Save Index.md first: its unsaved links would no longer lead where they do after undoing this move."
        )
        XCTAssertTrue(exists("Archive/a.md", in: root))
        XCTAssertTrue(store.canUndoFileOperation, "Saving lets the undo go ahead")
    }

    func testAFolderMovedWithAnUnsavedNoteInsideGoesBackWithIt() async throws {
        let root = try makeRoot()
        try write("# e\n", "docs/e.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "docs/e.md")
        _ = await wait { store.documentText == "# e\n" }
        store.setDocumentText("# e, unsaved\n")
        let original = url("docs/e.md", in: root).path

        store.moveItem(id: url("docs", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)
        XCTAssertEqual(store.selectedDocumentID, url("Archive/docs/e.md", in: root).path)
        store.undoFileOperation()
        await idle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedDocumentID, original)
        XCTAssertEqual(store.documentText, "# e, unsaved\n")
        XCTAssertFalse(store.saveState(for: original).isClean)
        XCTAssertEqual(text("docs/e.md", in: root), "# e\n")
    }

    // MARK: - Failures part way

    func testAMultiStepUndoThatFailsPartWayPutsBackWhatItDid() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        store.dropFileURLs([url("a.md", in: root), url("b.md", in: root)], into: url("Archive", in: root))
        _ = await wait { !store.isBusy && store.canUndoFileOperation }

        // Undo takes b back first, then a, whose name is taken now.
        try write("a newer a\n", "a.md", in: root)
        store.undoFileOperation()
        await idle(store)

        XCTAssertEqual(store.errorMessage, "Could not undo Move 2 Items: Another item is now named “a.md” in “\(root.lastPathComponent)”.")
        XCTAssertEqual(names("Archive", in: root), ["a.md", "b.md"], "b went back into Archive when a could not follow")
        XCTAssertFalse(exists("b.md", in: root))
        XCTAssertEqual(text("a.md", in: root), "a newer a\n")
    }

    func testAWorkspaceChangeDuringAnUndoPutsTheDiskBack() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try mkdir("Archive", in: root)
        let other = try makeRoot()
        try write("# o\n", "o.md", in: other)
        let scanner = GatedWorkspaceScanner()
        let store = try await openStore(root, scanner: scanner)
        store.moveItem(id: url("a.md", in: root).path, toDirectory: url("Archive", in: root))
        await settle(store)

        scanner.hold()
        store.undoFileOperation()
        let undoneOnDisk = await wait { self.exists("a.md", in: root) && scanner.waitingScanCount > 0 }
        XCTAssertTrue(undoneOnDisk, "The undo moved the file, and its rescan waits")
        store.openWorkspace(other)
        scanner.release()
        _ = await wait { !store.isBusy && store.workspaceURL == other.standardizedFileURL }
        let putBack = await wait { self.exists("Archive/a.md", in: root) }
        XCTAssertTrue(putBack, "An undo the window never took is put back")
        XCTAssertFalse(exists("a.md", in: root))
    }

    func testAPartlyFailedDuplicateCanStillUndoWhatItMade() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        // After a.md in path order, so a.md is copied before the copy fails.
        try write("secret\n", "zLocked/secret.md", in: root)
        let secret = url("zLocked/secret.md", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let store = try await openStore(root)

        store.duplicateItems(at: [url("a.md", in: root), url("zLocked", in: root)])
        await idle(store)
        XCTAssertNotNil(store.errorMessage, "zLocked can't be copied")
        XCTAssertTrue(exists("a copy.md", in: root))
        XCTAssertEqual(store.fileOperationUndo.undoActionName, "Duplicate “a.md”", "What was made can be undone")

        store.undoFileOperation()
        await idle(store)
        XCTAssertFalse(exists("a copy.md", in: root))
    }

    func testAPartlyFailedCutFromAnotherWorkspaceEndsTheCut() async throws {
        let first = try makeRoot()
        try write("# a\n", "a.md", in: first)
        // After a.md in path order, so a moves before b fails.
        try write("# b\n", "zLocked/b.md", in: first)
        let locked = url("zLocked", in: first)
        let second = try makeRoot()
        let cutting = try await openStore(first)
        let pasting = try await openStore(second)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        cutting.putItemsOnPasteboard(at: [url("a.md", in: first), url("zLocked/b.md", in: first)], cutting: true, pasteboard: pasteboard)
        let stamp = try XCTUnwrap(cutting.pendingTransferPasteboardStamp)
        // b cannot leave its folder: the move fails after a has moved.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertTrue(pasting.pasteFromPasteboard(pasteboard, into: nil))
        await idle(pasting)

        XCTAssertNotNil(pasting.errorMessage)
        XCTAssertTrue(names("", in: second).contains("a.md"))
        XCTAssertTrue(names("zLocked", in: first).contains("b.md"))
        XCTAssertFalse(WorkspacePasteboardExportService.holdsTransfer(stamp, on: pasteboard), "The Cut ends, so a second Paste does not try a again")
        XCTAssertEqual(pasting.fileOperationUndo.undoActionName, "Move “a.md”")
    }

    // MARK: - Copies that changed, redo and the selection

    func testUndoRefusesToTrashACopyEditedSinceItWasMade() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root)
        store.duplicateItem(at: url("a.md", in: root))
        await idle(store)

        try write("# a, edited in the copy and saved\n", "a copy.md", in: root)
        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(store.errorMessage, "Could not undo Duplicate “a.md”: “a copy.md” changed after it was made.")
        XCTAssertTrue(exists("a copy.md", in: root))
    }

    func testACopyMadeAgainCanBeUndoneAgain() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root, selecting: "a.md")
        _ = await wait { store.documentText == "# a\n" }
        // The copy carries the unsaved text, so it is written after it is made.
        store.setDocumentText("# a, unsaved\n")
        store.duplicateItem(at: url("a.md", in: root))
        await idle(store)
        store.undoFileOperation()
        await idle(store)
        try await Task.sleep(nanoseconds: 20_000_000)
        store.redoFileOperation()
        await idle(store)
        XCTAssertEqual(text("a copy.md", in: root), "# a, unsaved\n")

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage, "The copy made again is the one undo knows")
        XCTAssertFalse(exists("a copy.md", in: root))
    }

    func testRedoOfSeveralCopiesSelectsThemAllAndOpensNone() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        let store = try await openStore(root, selecting: "a.md")
        store.duplicateItems(at: [url("a.md", in: root), url("b.md", in: root)])
        await idle(store)
        let copies = [url("a copy.md", in: root).path, url("b copy.md", in: root).path]
        XCTAssertEqual(store.sidebarSelectionIDs.sorted(), copies)
        XCTAssertEqual(store.selectedDocumentID, url("a.md", in: root).path)

        store.undoFileOperation()
        await idle(store)
        store.redoFileOperation()
        await idle(store)
        XCTAssertEqual(store.sidebarSelectionIDs.sorted(), copies, "As the copy did: every copy selected")
        XCTAssertEqual(store.selectedDocumentID, url("a.md", in: root).path, "None opened")
    }

    func testUndoKeepsTheSelectedItemsThatStay() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("# b\n", "b.md", in: root)
        let store = try await openStore(root)
        store.duplicateItems(at: [url("a.md", in: root), url("b.md", in: root)])
        await idle(store)
        let a = url("a.md", in: root).path
        // The lead, b copy, goes with the undo; a stays.
        store.selectSidebarItems(.items([a, url("a copy.md", in: root).path, url("b copy.md", in: root).path]))

        store.undoFileOperation()
        await idle(store)
        XCTAssertEqual(store.sidebarSelectionIDs, [a])
    }

    func testCaseOnlyRenameIsUndone() async throws {
        let fixtureRoot = try makeRoot()
        try write("# t\n", "Target.md", in: fixtureRoot)
        guard WorkspaceFileIdentity.isCaseOnlyRename(from: url("Target.md", in: fixtureRoot), to: url("target.md", in: fixtureRoot)) else {
            throw XCTSkip("The test volume is case-sensitive.")
        }
        let store = try await openStore(fixtureRoot)
        store.renameDocument(id: try XCTUnwrap(doc(store, "Target.md")).id, to: "target.md")
        await settle(store)
        XCTAssertEqual(names("", in: fixtureRoot), ["target.md"])

        store.undoFileOperation()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("", in: fixtureRoot), ["Target.md"])
        store.redoFileOperation()
        await idle(store)
        XCTAssertEqual(names("", in: fixtureRoot), ["target.md"])
    }

    // MARK: - The history's bounds

    func testAnOperationOverTheTextBoundEndsTheHistoryRatherThanBeingSkipped() {
        func move(_ name: String, keeping bytes: Int) -> WorkspaceFileOperation {
            let text = String(repeating: "x", count: bytes / 2)
            let revision = WorkspaceTextRevision(text: text, signature: WorkspaceFileSignature(modificationDate: nil, fileSize: nil))
            let url = URL(fileURLWithPath: "/w/\(name)")
            return WorkspaceFileOperation(
                verb: .move,
                steps: [.move(WorkspaceFileMoveStep(
                    sourceURL: url,
                    destinationURL: URL(fileURLWithPath: "/w/Archive/\(name)"),
                    isDirectory: false,
                    usedCaseOnlyRenameHop: false,
                    rewrittenFiles: [WorkspaceFileMoveRewrite(originalURL: url, finalURL: url, originalRevision: revision, writtenRevision: revision)]
                ))],
                workspaceURL: URL(fileURLWithPath: "/w"),
                serial: 0
            )
        }
        let bound = WorkspaceFileOperationHistory.maximumRetainedTextBytes
        var history = WorkspaceFileOperationHistory()
        history.record(move("a", keeping: bound / 2))
        history.record(move("b", keeping: bound / 2))
        XCTAssertEqual(history.undoStack.count, 2)
        history.record(move("c", keeping: bound / 4))
        XCTAssertEqual(history.undoStack.map(\.actionName), ["Move “b”", "Move “c”"], "The oldest goes to stay within the bound")
        XCTAssertLessThanOrEqual(history.undoStack.reduce(0) { $0 + $1.retainedTextByteCount }, bound)

        history.record(move("huge", keeping: bound + 2))
        XCTAssertTrue(history.undoStack.isEmpty, "Undo can't step past what it could not keep")
    }

    func testOutermostPathsLeaveOutNestedItemsInOnePass() {
        XCTAssertEqual(
            WorkspaceStore.outermostPaths(["/w/a", "/w/a b", "/w/a/c", "/w/a b/d", "/w/z.md", "/w/a/c/e"]),
            ["/w/a", "/w/a b", "/w/z.md"]
        )
        XCTAssertEqual(
            WorkspaceStore.outermostItems(["/w/z", "/w/a.md", "/w/z/x.md", "/w/a.md"].map { URL(fileURLWithPath: $0) }).map(\.path),
            ["/w/z", "/w/a.md"],
            "Items keep the order they came in: a drop moves them in that order"
        )
        let many = (0..<20_000).map { "/w/folder\($0 % 100)/note\($0).md" } + (0..<100).map { "/w/folder\($0)" }
        let start = Date()
        XCTAssertEqual(WorkspaceStore.outermostPaths(many).count, 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Linear in the paths, not quadratic")
    }

    // MARK: - Several items, one inside another

    func testAFileInsideASelectedFolderGoesWithTheFolder() async throws {
        let root = try makeRoot()
        try write("# e\n", "docs/e.md", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        store.selectSidebarItems(.items([url("docs", in: root).path, url("docs/e.md", in: root).path]))
        XCTAssertEqual(store.sidebarSelectionURLs.map(\.path), [url("docs", in: root).path])

        store.duplicateItems(at: store.sidebarSelectionURLs)
        await idle(store)
        XCTAssertEqual(names("", in: root), ["docs", "docs copy"])
        XCTAssertEqual(names("docs", in: root), ["e.md"], "No separate copy of e.md")

        store.putItemsOnPasteboard(at: [url("docs", in: root), url("docs/e.md", in: root)], cutting: false, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)

        store.deleteItems(at: [url("docs", in: root), url("docs/e.md", in: root)])
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("", in: root), ["docs copy"])
    }

    // MARK: - Edit menu routing

    func testEditUndoTakesFileOperationsFromAnyFocusButTextTheTerminalOrADocument() {
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
        XCTAssertEqual(destination(native: true), .fileOperation, "Before the window’s own undo")
        XCTAssertEqual(destination(native: true, file: false), .native)
        XCTAssertEqual(destination(pdf: true, pdfUndo: true), .fileOperation, "The sidebar has focus beside a PDF")
        // Source and Preview keep ⌘Z, even with nothing left to undo.
        XCTAssertEqual(destination(text: true, native: true), .native)
        XCTAssertEqual(destination(text: true), .unavailable)
        XCTAssertEqual(destination(text: true, replace: true, file: false, fileIsNewer: false), .workspaceReplace, "Replace All's promise stands")
        // …but an older Replace never runs past a newer move, even one that cannot run just now.
        XCTAssertEqual(destination(text: true, replace: true), .unavailable)
        XCTAssertEqual(destination(text: true, replace: true, file: false), .unavailable)
        XCTAssertEqual(destination(replace: true, file: false), .unavailable)
        XCTAssertEqual(destination(pdf: true, document: true, replace: true, pdfUndo: true), .pdf, "A focused PDF keeps its undo")
        XCTAssertEqual(destination(pdf: true, document: true, replace: true), .unavailable)
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
