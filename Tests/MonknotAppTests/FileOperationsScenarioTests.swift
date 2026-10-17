import AppKit
import MonknotCore
import XCTest
@testable import MonknotApp

/// Adversarial sweep of copy, cut, paste, duplicate, rename, create and drop at the
/// `WorkspaceStore` level, through the same entry points the sidebar and ⌘C/⌘X/⌘V use.
/// Every clipboard here is a private named pasteboard.
@MainActor
final class FileOperationsScenarioTests: FileOperationsTestCase {

    // MARK: - Copy → Paste

    func testCopyPastesIntoSameFolderOtherFolderRootAndEmptyFolderWithCopySuffixes() async throws {
        let root = try makeRoot()
        try write("# A\n", "docs/a.md", in: root)
        try mkdir("Empty", in: root)
        try mkdir("Other", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("docs/a.md"), cutting: false, pasteboard: pasteboard)
        for destination in ["docs", "docs", "docs", "Other", "", "Empty"] {
            let url = destination.isEmpty ? nil : root.appendingPathComponent(destination)
            XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: url), "Nothing pasted into \(destination)")
            await idle(store)
            XCTAssertNil(store.errorMessage, destination)
        }

        XCTAssertEqual(names("docs", in: root), ["a.md", "a copy.md", "a copy 2.md", "a copy 3.md"])
        XCTAssertEqual(names("Other", in: root), ["a.md"])
        XCTAssertEqual(names("Empty", in: root), ["a.md"])
        XCTAssertTrue(names("", in: root).contains("a.md"))
        XCTAssertNotNil(doc(store, "Empty/a.md"), "The sidebar does not list the pasted file")
    }

    /// Paste selects (opens) the pasted copy so it is revealed, every time the same Copy is pasted.
    func testEveryPasteOfOneCopySelectsItsNewCopy() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("# Z\n", "z.md", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root, selecting: "z.md")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.md"), cutting: false, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertEqual(store.selectedDocument?.relativePath, "Sub/a.md")

        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertEqual(names("Sub", in: root), ["a.md", "a copy.md"])
        XCTAssertEqual(store.selectedDocument?.relativePath, "Sub/a copy.md")
    }

    /// One Copy pasted twice gives two identical copies of the file as it was at Copy, its unsaved
    /// edits included; later edits do not reach them.
    func testRepeatedPastesOfOneCopyOfAnEditedFileProduceTheSameContent() async throws {
        let root = try makeRoot()
        try write("saved\n", "a.txt", in: root)
        let store = try await openStore(root, selecting: "a.txt")
        let a = try XCTUnwrap(doc(store, "a.txt"))
        _ = await wait { !store.isDocumentLoading && store.documentText == "saved\n" }
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("unsaved edit\n")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: a.url, cutting: false, pasteboard: pasteboard)
        // What another app pastes is the same file.
        let exported = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "unsaved edit\n")
        store.setDocumentText("edited after the Copy\n")
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)

        let first = try String(contentsOf: root.appendingPathComponent("a copy.txt"), encoding: .utf8)
        let second = try String(contentsOf: root.appendingPathComponent("a copy 2.txt"), encoding: .utf8)
        XCTAssertEqual(first, "unsaved edit\n")
        XCTAssertEqual(second, first)
    }

    /// A Paste copies the file as it was at Copy, as a Paste in another app does, even once the
    /// file has been saved over.
    func testRepeatedPastesAfterTheSourceWasSavedOverProduceTheSameContent() async throws {
        let root = try makeRoot()
        try write("v1\n", "a.txt", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: false, pasteboard: pasteboard)
        // Saved over (atomically, as editors and Monknot's own save do) between Copy and Paste.
        try "v2\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)

        let first = try String(contentsOf: root.appendingPathComponent("a copy.txt"), encoding: .utf8)
        let second = try String(contentsOf: root.appendingPathComponent("a copy 2.txt"), encoding: .utf8)
        XCTAssertEqual(first, "v1\n")
        XCTAssertEqual(second, first)
    }

    /// Monknot knows it renamed the copied item; the pending Copy should follow it.
    func testCopyThenRenameInMonknotThenPasteCopiesTheRenamedFile() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: false, pasteboard: pasteboard)
        let a = try XCTUnwrap(doc(store, "a.txt"))
        store.renameDocument(id: a.id, to: "b.txt")
        await settle(store)
        XCTAssertNotNil(doc(store, "b.txt"))

        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Sub", in: root), ["b.txt"])
    }

    func testCutThenRenameInMonknotThenPasteMovesTheRenamedFile() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        let a = try XCTUnwrap(doc(store, "a.txt"))
        store.renameDocument(id: a.id, to: "b.txt")
        await settle(store)

        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Sub", in: root), ["b.txt"])
        XCTAssertFalse(names("", in: root).contains("b.txt"))
    }

    // MARK: - Cut → Paste

    func testCutPasteMovesFollowsTheOpenTabAndUpdatesLinks() async throws {
        let root = try makeRoot()
        try write("# Target\n", "target.md", in: root)
        try write("See [t](target.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "target.md")
        let target = try XCTUnwrap(doc(store, "target.md"))
        store.setOpenDocumentIDs([target.id])
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: target.url, cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
        XCTAssertEqual(store.selectedDocument?.relativePath, "Archive/target.md")
        XCTAssertEqual(store.documentIDRemapEvent?.mappings.first?.destinationID, root.appendingPathComponent("Archive/target.md").path)
        let index = try String(contentsOf: root.appendingPathComponent("index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("Archive/target.md"), index)
    }

    func testCutPasteIntoItsOwnFolderLosesNothing() async throws {
        let root = try makeRoot()
        try write("x\n", "Sub/a.txt", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("Sub/a.txt"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await settle(store)
        XCTAssertEqual(names("Sub", in: root), ["a.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sub/a.txt"), encoding: .utf8), "x\n")
        XCTAssertNil(store.errorMessage)
    }

    func testCutThenCopyAnotherThenPastePastesTheCopyAndLeavesTheCutAlone() async throws {
        let root = try makeRoot()
        try write("a\n", "a.txt", in: root)
        try write("b\n", "b.txt", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        store.putItemOnPasteboard(at: root.appendingPathComponent("b.txt"), cutting: false, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertEqual(names("Sub", in: root), ["b.txt"])
        XCTAssertEqual(names("", in: root), ["a.txt", "b.txt", "Sub"])
    }

    /// Moving the folder would rewrite the relative link in the unsaved note, so it waits.
    func testCutFolderWithAnUnsavedNoteWhoseLinksTheMoveRewritesIsRefusedWithAReason() async throws {
        let root = try makeRoot()
        try write("# N\n[top](../top.md)\n", "Folder/n.md", in: root)
        try write("# Top\n", "top.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "Folder/n.md")
        let n = try XCTUnwrap(doc(store, "Folder/n.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([n.id])
        store.setDocumentText("# N edited\n")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("Folder"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settle(store)
        XCTAssertEqual(store.errorMessage, "Save n.md first: this move updates the links in it.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.url.path))
        XCTAssertEqual(store.documentText, "# N edited\n", "Unsaved text lost")
    }

    /// A link that exists only in a note's unsaved text would break as surely as one on disk, so
    /// moving its target waits until the note is saved.
    func testMovingAnItemLinkedOnlyFromUnsavedTextIsRefused() async throws {
        let root = try makeRoot()
        try write("# N\n", "n.md", in: root)
        try write("# A\n", "a.md", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root, selecting: "n.md")
        let n = try XCTUnwrap(doc(store, "n.md"))
        let a = try XCTUnwrap(doc(store, "a.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([n.id])
        store.setDocumentText("# N\n[a](a.md)\n")

        XCTAssertTrue(store.moveItem(id: a.id, toDirectory: root.appendingPathComponent("Sub")))
        await settle(store)
        XCTAssertEqual(store.errorMessage, "Save n.md first: this move updates the links in it.")
        XCTAssertEqual(names("", in: root), ["a.md", "n.md", "Sub"])
        XCTAssertEqual(store.documentText, "# N\n[a](a.md)\n")
    }

    /// A moved note's own relative links change with it, unsaved ones too.
    func testMovingANoteWhoseUnsavedTextHasARelativeLinkIsRefused() async throws {
        let root = try makeRoot()
        try write("# N\n", "Notes/n.md", in: root)
        try write("# Top\n", "top.md", in: root)
        try mkdir("Archive/Deep", in: root)
        let store = try await openStore(root, selecting: "Notes/n.md")
        let n = try XCTUnwrap(doc(store, "Notes/n.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([n.id])
        store.setDocumentText("# N\n[top](../top.md)\n")

        XCTAssertTrue(store.moveItem(id: n.id, toDirectory: root.appendingPathComponent("Archive/Deep")))
        await settle(store)
        XCTAssertEqual(store.errorMessage, "Save n.md first: this move updates the links in it.")
        XCTAssertEqual(names("Notes", in: root), ["n.md"])

        // Unsaved text with no link the move changes moves with the note.
        store.setDocumentText("# N\nNo links.\n")
        XCTAssertTrue(store.moveItem(id: n.id, toDirectory: root.appendingPathComponent("Archive/Deep")))
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Archive/Deep", in: root), ["n.md"])
        XCTAssertEqual(store.documentText, "# N\nNo links.\n")
    }

    func testCutFolderWithAnOpenUnsavedNoteMovesAndKeepsTheEdit() async throws {
        let root = try makeRoot()
        try write("# N\n", "Folder/n.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "Folder/n.md")
        let n = try XCTUnwrap(doc(store, "Folder/n.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([n.id])
        store.setDocumentText("# N edited\n")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("Folder"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedDocument?.relativePath, "Archive/Folder/n.md")
        XCTAssertEqual(store.documentText, "# N edited\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Archive/Folder/n.md"), encoding: .utf8), "# N\n")
    }

    func testCutFolderWithOpenUnsavedTextFileMovesAndKeepsTheEdit() async throws {
        let root = try makeRoot()
        try write("disk\n", "Folder/n.txt", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root, selecting: "Folder/n.txt")
        let n = try XCTUnwrap(doc(store, "Folder/n.txt"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([n.id])
        store.setDocumentText("edited\n")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("Folder"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedDocument?.relativePath, "Archive/Folder/n.txt")
        XCTAssertEqual(store.documentText, "edited\n")
        XCTAssertFalse(store.saveState(for: root.appendingPathComponent("Archive/Folder/n.txt").path).isClean)
    }

    /// Two windows on two workspaces share one clipboard. Cut in one and Paste in the other moves
    /// the item, as in Finder, and the moved item cannot be pasted again.
    func testCutInOneWindowPastedInAnotherWorkspaceMovesTheItem() async throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        try write("a\n", "a.txt", in: rootA)
        let windowA = try await openStore(rootA)
        let windowB = try await openStore(rootB)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        windowA.putItemOnPasteboard(at: rootA.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(windowB.pasteFromPasteboard(pasteboard, into: nil))
        await idle(windowB)
        XCTAssertNil(windowB.errorMessage)
        XCTAssertEqual(names("", in: rootB), ["a.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("a.txt").path))
        XCTAssertEqual(windowB.selectedDocument?.relativePath, "a.txt")

        XCTAssertFalse(windowA.pasteFromPasteboard(pasteboard, into: nil), "The moved item is still on the clipboard")
        XCTAssertFalse(windowB.pasteFromPasteboard(pasteboard, into: nil), "The moved item is still on the clipboard")
    }

    func testCutInOneWindowWithUnsavedEditsIsNotMovedByAnotherWindow() async throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        try write("disk\n", "a.txt", in: rootA)
        let windowA = try await openStore(rootA, selecting: "a.txt")
        let windowB = try await openStore(rootB)
        let a = try XCTUnwrap(doc(windowA, "a.txt"))
        _ = await wait { !windowA.isDocumentLoading }
        windowA.setOpenDocumentIDs([a.id])
        windowA.setDocumentText("unsaved\n")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        windowA.putItemOnPasteboard(at: a.url, cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(windowB.pasteFromPasteboard(pasteboard, into: nil))
        await idle(windowB)
        XCTAssertEqual(windowB.errorMessage, "Save or close a.txt in its window first.")
        XCTAssertEqual(names("", in: rootA), ["a.txt"])
        XCTAssertEqual(names("", in: rootB), [])
        XCTAssertEqual(windowA.documentText, "unsaved\n")

        let saved = await windowA.saveDocument(id: a.id)
        XCTAssertTrue(saved)
        XCTAssertTrue(windowB.pasteFromPasteboard(pasteboard, into: nil))
        await idle(windowB)
        XCTAssertNil(windowB.errorMessage)
        XCTAssertEqual(try String(contentsOf: rootB.appendingPathComponent("a.txt"), encoding: .utf8), "unsaved\n")
        XCTAssertEqual(names("", in: rootA), [])
    }

    /// Two windows on one workspace: a Cut in one and Paste in the other is a link-aware move.
    func testCutInOneWindowPastedInAnotherWindowOfTheSameWorkspaceUpdatesLinks() async throws {
        let root = try makeRoot()
        try write("# T\n", "target.md", in: root)
        try write("See [t](target.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let windowA = try await openStore(root)
        let windowB = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        windowA.putItemOnPasteboard(at: root.appendingPathComponent("target.md"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(windowB.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settle(windowB)
        XCTAssertNil(windowB.errorMessage)
        XCTAssertEqual(names("Archive", in: root), ["target.md"])
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("index.md"), encoding: .utf8).contains("Archive/target.md"))
    }

    // MARK: - Names

    func testCopyDuplicateAndRenameWithAwkwardNames() async throws {
        let root = try makeRoot()
        let long = String(repeating: "l", count: 200)
        try write("# r\n", "Résumé 📄 notes.MD", in: root)
        try write("t\n", "v1.2/read me.TXT", in: root)
        try write("t\n", "\(long).md", in: root)
        try mkdir("_drafts", in: root)
        let store = try await openStore(root)

        store.duplicateItem(at: root.appendingPathComponent("Résumé 📄 notes.MD"))
        await idle(store)
        store.duplicateItem(at: root.appendingPathComponent("v1.2"))
        await idle(store)
        store.duplicateItem(at: root.appendingPathComponent("v1.2/read me.TXT"))
        await idle(store)
        store.duplicateItem(at: root.appendingPathComponent("_drafts"))
        await idle(store)
        store.duplicateItem(at: root.appendingPathComponent("\(long).md"))
        await idle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(names("", in: root).isSuperset(of: ["Résumé 📄 notes copy.MD", "v1.2 copy", "_drafts copy", "\(long) copy.md"]))
        XCTAssertEqual(names("v1.2", in: root), ["read me.TXT", "read me copy.TXT"])
        XCTAssertNotNil(doc(store, "Résumé 📄 notes copy.MD"))
        XCTAssertNotNil(doc(store, "v1.2 copy/read me.TXT"))

        let folder = try XCTUnwrap(store.rootNode?.children?.first { $0.name == "v1.2" })
        store.renameFolder(id: folder.id, to: "v1.3 ☕️")
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(doc(store, "v1.3 ☕️/read me.TXT"))
    }

    /// A name longer than macOS allows is refused while the name sheet is still open.
    func testOverlongNamesAreRefusedByValidationBeforeTheSheetCloses() async throws {
        let root = try makeRoot()
        try write("x\n", "a.md", in: root)
        let store = try await openStore(root)
        let tooLong = String(repeating: "n", count: 260) + ".md"

        XCTAssertNotNil(store.validationMessage(forNewItemNamed: tooLong, in: nil, isDirectory: false))
        XCTAssertNotNil(store.validationMessage(forRenaming: root.appendingPathComponent("a.md"), to: tooLong, isDirectory: false))
        // 85 Hangul syllables fill the limit (3 each once decomposed); a rename's kept extension
        // takes the name past it.
        let longRename = String(repeating: "한", count: 85)
        XCTAssertNotNil(store.validationMessage(forRenaming: root.appendingPathComponent("a.md"), to: longRename, isDirectory: false))
        XCTAssertNil(store.validationMessage(forNewItemNamed: longRename, in: nil, isDirectory: true))
        store.createFile(named: tooLong)
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(names("", in: root), ["a.md"])
    }

    func testInvalidNewNamesAreRefusedWithoutTouchingDisk() async throws {
        let root = try makeRoot()
        try write("x\n", "Notes.md", in: root)
        try mkdir("Folder", in: root)
        let store = try await openStore(root)
        let before = names("", in: root)

        for name in ["", "   ", ".", "..", "a/b.md", "a:b.md", ".hidden.md", "notes.md", "NOTES.MD", "notes"] {
            XCTAssertNotNil(store.validationMessage(forNewItemNamed: name, in: nil, isDirectory: false), "File \(name)")
            store.createFile(named: name)
            await idle(store)
        }
        for name in ["", "   ", ".", "..", "a/b.md", "a:b.md", ".hidden.md", "notes.md", "NOTES.MD", "folder"] {
            XCTAssertNotNil(store.validationMessage(forNewItemNamed: name, in: nil, isDirectory: true), "Folder \(name)")
            store.createFolder(named: name)
            await idle(store)
        }
        XCTAssertEqual(names("", in: root), before)
    }

    // MARK: - Duplicate

    func testDuplicateFolderCarriesTheUnsavedEditsOfItsOpenDocumentsLikeDuplicateFileDoes() async throws {
        let root = try makeRoot()
        try write("disk\n", "Folder/a.txt", in: root)
        let store = try await openStore(root, selecting: "Folder/a.txt")
        let a = try XCTUnwrap(doc(store, "Folder/a.txt"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("unsaved\n")

        store.duplicateItem(at: a.url)
        await idle(store)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Folder/a copy.txt"), encoding: .utf8), "unsaved\n")

        store.selectDocument(id: a.id)
        _ = await wait { !store.isDocumentLoading }
        store.duplicateItem(at: root.appendingPathComponent("Folder"))
        await idle(store)
        let inFolderCopy = try String(contentsOf: root.appendingPathComponent("Folder copy/a.txt"), encoding: .utf8)
        XCTAssertEqual(inFolderCopy, "unsaved\n")
        XCTAssertEqual(try String(contentsOf: a.url, encoding: .utf8), "disk\n")
    }

    func testDuplicateWhileBusyIsReported() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        let scanner = GatedWorkspaceScanner()
        let store = try await openStore(root, scanner: scanner)

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        XCTAssertTrue(store.isBusy)
        store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        XCTAssertNotNil(store.errorMessage)
        scanner.release()
        await idle(store)
        XCTAssertEqual(names("", in: root), ["a.txt", "a copy.txt"])
    }

    // MARK: - Commands while busy

    func testNewFileNewFolderRenameMoveWhileBusyAreNotSilentlyDropped() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try mkdir("Sub", in: root)
        let scanner = GatedWorkspaceScanner()
        let store = try await openStore(root, scanner: scanner)
        let a = try XCTUnwrap(doc(store, "a.txt"))

        scanner.hold()
        store.duplicateItem(at: a.url)
        XCTAssertTrue(store.isBusy)
        var silent: [String] = []
        store.errorMessage = nil
        store.createFile(named: "new.txt")
        if store.errorMessage == nil { silent.append("New File") }
        store.errorMessage = nil
        store.createFolder(named: "New")
        if store.errorMessage == nil { silent.append("New Folder") }
        store.errorMessage = nil
        store.renameDocument(id: a.id, to: "b.txt")
        if store.errorMessage == nil { silent.append("Rename") }
        store.errorMessage = nil
        store.moveItem(id: a.id, toDirectory: root.appendingPathComponent("Sub"))
        if store.errorMessage == nil { silent.append("Move") }
        scanner.release()
        await idle(store)

        let applied = names("", in: root)
        XCTAssertFalse(applied.contains("new.txt") || applied.contains("New"), "Unexpectedly queued")
        XCTAssertEqual(silent, [])
    }

    // MARK: - Foreign clipboard contents

    func testPasteFinderFilesSingleMultipleAndFolder() async throws {
        let root = try makeRoot()
        try mkdir("Sub", in: root)
        let outside = try makeRoot()
        try write("1\n", "one.txt", in: outside)
        try write("2\n", "two.md", in: outside)
        try write("3\n", "Dir/three.md", in: outside)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("one.txt") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("one.txt") as NSURL, outside.appendingPathComponent("two.md") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("Dir") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        // Pasting the same Finder file again into the same folder.
        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("one.txt") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("", in: root), ["Sub", "one.txt", "one copy.txt"])
        XCTAssertEqual(names("Sub", in: root), ["one.txt", "two.md", "Dir"])
        XCTAssertNotNil(doc(store, "Sub/Dir/three.md"))
        XCTAssertEqual(names("", in: outside), ["one.txt", "two.md", "Dir"], "Finder originals changed")
    }

    func testPasteEmptyClipboardReportsNothingToPaste() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertFalse(store.pasteFromPasteboard(pasteboard, into: nil))
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(names("", in: root), [])
    }

    func testPastePlainTextCreatesANoteTitledFromItsFirstLine() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("Shopping list\nmilk\neggs", forType: .string)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        let first = try XCTUnwrap(store.selectedDocument)
        XCTAssertTrue(first.relativePath.hasPrefix("inbox/") && first.relativePath.hasSuffix(" Shopping list.md"), first.relativePath)
        _ = await wait { !store.isDocumentLoading }
        XCTAssertTrue(store.documentText.contains("milk\neggs"))

        pasteboard.clearContents()
        pasteboard.setString("Meeting: Q3 plan\nagenda", forType: .string)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        let second = try XCTUnwrap(store.selectedDocument)
        XCTAssertTrue(second.relativePath.hasSuffix(" Meeting - Q3 plan.md"), second.relativePath)
        _ = await wait { !store.isDocumentLoading }
        XCTAssertTrue(store.documentText.hasPrefix("# Meeting: Q3 plan\n"), store.documentText)

        pasteboard.clearContents()
        pasteboard.setString("A/B testing\nresults", forType: .string)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertTrue(store.selectedDocument?.relativePath.hasSuffix(" A-B testing.md") == true, store.selectedDocument?.relativePath ?? "")
    }

    func testPastePNGImageDataCreatesAnImageFile() async throws {
        let root = try makeRoot()
        try mkdir("Pics", in: root)
        let store = try await openStore(root)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(WorkspacePasteboardImportService.pngData(for: image))
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Pics")))
        await idle(store)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Pics")))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Pics", in: root), ["Pasted Image.png", "Pasted Image copy.png"])
        XCTAssertNotNil(doc(store, "Pics/Pasted Image.png"))
    }

    /// Rich text copied from apps that publish only RTF or HTML becomes a note of its text.
    func testPasteRichTextOnlyClipboardCreatesANote() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let rtf = try NSAttributedString(string: "Rich words here").data(
            from: NSRange(location: 0, length: 15),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        let rtfPasted = store.pasteFromPasteboard(pasteboard, into: nil)
        await idle(store)

        pasteboard.clearContents()
        pasteboard.setString("<p>Html words here</p>", forType: .html)
        let htmlPasted = store.pasteFromPasteboard(pasteboard, into: nil)
        await idle(store)

        XCTAssertTrue(rtfPasted, "RTF-only clipboard")
        XCTAssertTrue(htmlPasted, "HTML-only clipboard")
        XCTAssertNil(store.errorMessage)
        _ = await wait { !store.isDocumentLoading }
        XCTAssertTrue(store.selectedDocument?.relativePath.hasSuffix(" Html words here.md") == true, store.selectedDocument?.relativePath ?? "")
        XCTAssertTrue(store.documentText.contains("Html words here"), store.documentText)
        XCTAssertFalse(store.documentText.contains("<p>"), store.documentText)
    }

    // MARK: - Finder drops

    func testFinderDropOfSeveralWorkspaceFilesMovesThem() async throws {
        let root = try makeRoot()
        try write("a\n", "a.txt", in: root)
        try write("b\n", "b.txt", in: root)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)
        let urls = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]

        // A plain Finder drag of workspace items proposes Move (the drag cursor says move).
        XCTAssertFalse(SidebarFileDrop.copies(urls, workspaceURL: root, isOptionPressed: false))
        store.dropFileURLs(urls, into: root.appendingPathComponent("Sub"), copying: false)
        _ = await wait { self.names("Sub", in: root).count == 2 && !store.isBusy }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Sub", in: root), ["a.txt", "b.txt"])
        XCTAssertEqual(names("", in: root), ["Sub"])
    }

    /// Each moved item updates the links to it, after its own review; a folder and a file inside
    /// it dropped together move as the folder.
    func testFinderDropOfSeveralWorkspaceItemsUpdatesLinksAndFollowsEarlierMoves() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("# N\n", "Notes/n.md", in: root)
        try write("[a](a.md) [n](Notes/n.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        let urls = ["a.md", "Notes", "Notes/n.md"].map { root.appendingPathComponent($0) }

        store.dropFileURLs(urls, into: root.appendingPathComponent("Archive"), copying: false)
        for _ in 0..<3 {
            _ = await wait { !store.isBusy }
            if let review = store.pendingMarkdownLinkMoveReview {
                store.confirmMarkdownLinkMoveReview(id: review.id)
            }
        }
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Archive", in: root), ["a.md", "Notes"])
        XCTAssertEqual(names("Archive/Notes", in: root), ["n.md"])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("index.md"), encoding: .utf8),
            "[a](Archive/a.md) [n](Archive/Notes/n.md)\n"
        )
    }

    func testFinderDropOfWorkspaceAndOutsideItemsMovesOneAndCopiesTheOther() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("a\n", "a.txt", in: root)
        try write("o\n", "o.txt", in: outside)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)

        store.dropFileURLs([root.appendingPathComponent("a.txt"), outside.appendingPathComponent("o.txt")], into: root.appendingPathComponent("Sub"))
        _ = await wait { self.names("Sub", in: root).count == 2 && !store.isBusy }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Sub", in: root), ["a.txt", "o.txt"])
        XCTAssertEqual(names("", in: root), ["Sub"])
        XCTAssertEqual(names("", in: outside), ["o.txt"])
    }

    /// A drop of several items goes on past an item that cannot move, as Finder does, and says
    /// once at the end what did not move and why.
    func testFinderDropSkipsAnItemThatCannotMoveAndReportsIt() async throws {
        let root = try makeRoot()
        for name in ["a.txt", "b.txt", "c.txt", "Sub/b.txt"] {
            try write("\(name)\n", name, in: root)
        }
        let store = try await openStore(root)

        store.dropFileURLs(["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }, into: root.appendingPathComponent("Sub"))
        _ = await wait { self.names("Sub", in: root).count == 3 && !store.isBusy }
        await idle(store)
        XCTAssertEqual(names("Sub", in: root), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(names("", in: root), ["Sub", "b.txt"])
        XCTAssertEqual(store.errorMessage, "Moved 2 items. b.txt wasn't moved: An item named b.txt already exists.")
    }

    /// Cancelling the link review of one item of a drop stops the drop and says how many items
    /// stayed where they were.
    func testCancellingALinkReviewDuringADropStopsItAndSaysWhatWasLeft() async throws {
        let root = try makeRoot()
        try write("x\n", "x.txt", in: root)
        try write("# A\n", "a.md", in: root)
        try write("y\n", "y.txt", in: root)
        try write("[a](a.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.dropFileURLs(["x.txt", "a.md", "y.txt"].map { root.appendingPathComponent($0) }, into: root.appendingPathComponent("Archive"))
        _ = await wait { store.pendingMarkdownLinkMoveReview != nil }
        let review = try XCTUnwrap(store.pendingMarkdownLinkMoveReview)
        store.cancelMarkdownLinkMoveReview(id: review.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        await idle(store)

        XCTAssertEqual(names("Archive", in: root), ["x.txt"])
        XCTAssertEqual(names("", in: root), ["Archive", "a.md", "index.md", "y.txt"])
        XCTAssertEqual(store.errorMessage, "Moved 1 item. 2 items weren't moved.")
    }

    /// A drop's remaining moves belong to the drop: another operation that begins while one of its
    /// link reviews is open ends the drop, and finishing that operation moves nothing more.
    func testAnotherOperationEndsAPendingDropAndItsMovesNeverRun() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("b\n", "b.txt", in: root)
        try write("o\n", "other.txt", in: root)
        try write("[a](a.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)
        let other = try XCTUnwrap(doc(store, "other.txt"))

        store.dropFileURLs(["a.md", "b.txt"].map { root.appendingPathComponent($0) }, into: root.appendingPathComponent("Archive"))
        _ = await wait { store.pendingMarkdownLinkMoveReview != nil }
        XCTAssertNotNil(store.pendingMarkdownLinkMoveReview)

        store.renameDocument(id: other.id, to: "renamed.txt")
        await settle(store)
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle(store)

        XCTAssertNil(store.pendingMarkdownLinkMoveReview)
        XCTAssertEqual(names("Archive", in: root), [])
        XCTAssertEqual(names("", in: root), ["Archive", "a.md", "b.txt", "index.md", "renamed.txt"])
    }

    /// A drop made while an earlier drop waits for its link review replaces that drop.
    func testADropWhileALinkReviewIsOpenReplacesTheEarlierDrop() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("b\n", "b.txt", in: root)
        try write("c\n", "c.txt", in: root)
        try write("[a](a.md)\n", "index.md", in: root)
        try mkdir("Archive", in: root)
        let store = try await openStore(root)

        store.dropFileURLs(["a.md", "b.txt"].map { root.appendingPathComponent($0) }, into: root.appendingPathComponent("Archive"))
        _ = await wait { store.pendingMarkdownLinkMoveReview != nil }
        XCTAssertNotNil(store.pendingMarkdownLinkMoveReview)

        store.dropFileURLs([root.appendingPathComponent("c.txt")], into: root.appendingPathComponent("Archive"))
        _ = await wait { self.names("Archive", in: root) == ["c.txt"] && !store.isBusy }
        await settle(store)
        XCTAssertNil(store.pendingMarkdownLinkMoveReview)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Archive", in: root), ["c.txt"])
        XCTAssertEqual(names("", in: root), ["Archive", "a.md", "b.txt", "index.md"])
    }

    /// A drop that moves a workspace item and copies in an outside item the sidebar does not
    /// list still says the copy will not show.
    func testMixedDropStillSaysAnUnlistedCopyWillNotShow() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("a\n", "a.txt", in: root)
        try write("zip", "archive.zip", in: outside)
        try mkdir("Sub", in: root)
        let store = try await openStore(root)

        store.dropFileURLs([root.appendingPathComponent("a.txt"), outside.appendingPathComponent("archive.zip")], into: root.appendingPathComponent("Sub"))
        _ = await wait { self.names("Sub", in: root).count == 2 && !store.isBusy }
        await idle(store)
        XCTAssertEqual(names("Sub", in: root), ["a.txt", "archive.zip"])
        XCTAssertEqual(store.errorMessage, "Pasted archive.zip, but Monknot does not show this kind of item.")
    }

    func testFinderDropWhileBusyIsReported() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("o\n", "o.txt", in: outside)
        try write("x\n", "x.txt", in: root)
        let scanner = GatedWorkspaceScanner()
        let store = try await openStore(root, scanner: scanner)

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("x.txt"))
        store.dropFileURLs([outside.appendingPathComponent("o.txt")], into: nil, copying: true)
        XCTAssertNotNil(store.errorMessage)
        scanner.release()
        await idle(store)
    }

    /// Paste (and Finder drop) of items the sidebar does not list copies them in and says they
    /// will not show, as New File does.
    func testPastingFinderItemsTheSidebarDoesNotListIsNotSilent() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("zip", "archive.zip", in: outside)
        try write("doc", "report.docx", in: outside)
        try write("# x\n", "dist/inner.md", in: outside)
        try write("# shown\n", "shown.md", in: outside)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects(["archive.zip", "report.docx", "dist", "shown.md"].map { outside.appendingPathComponent($0) as NSURL })
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertEqual(names("", in: root), ["archive.zip", "report.docx", "dist", "shown.md"], "Not copied in")
        XCTAssertEqual(store.rootNode?.children?.map(\.name) ?? [], ["shown.md"])
        let message = try XCTUnwrap(store.errorMessage)
        for name in ["archive.zip", "report.docx", "dist", "does not show these kinds of items"] {
            XCTAssertTrue(message.contains(name), message)
        }
        XCTAssertFalse(message.contains("shown.md"), message)

        store.dropFileURLs([outside.appendingPathComponent("archive.zip")], into: nil)
        await idle(store)
        XCTAssertEqual(store.errorMessage, "Pasted archive copy.zip, but Monknot does not show this kind of item.")
    }

    /// An unsaved note does not stop renaming or moving items it does not link to.
    func testRenamingAnUnrelatedFileWhileANoteIsUnsavedWorks() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        try write("x\n", "Other/b.txt", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let a = try XCTUnwrap(doc(store, "a.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("# a typing\n")

        let b = try XCTUnwrap(doc(store, "Other/b.txt"))
        store.renameDocument(id: b.id, to: "c.txt")
        await settle(store)
        let renameError = store.errorMessage
        store.errorMessage = nil
        store.moveItem(id: root.appendingPathComponent("Other/c.txt").path, toDirectory: nil)
        await settle(store)
        let moveError = store.errorMessage
        XCTAssertEqual(store.documentText, "# a typing\n")
        XCTAssertNil(renameError)
        XCTAssertNil(moveError)
        XCTAssertEqual(names("", in: root), ["a.md", "Other", "c.txt"])
        XCTAssertFalse(store.saveState(for: a.id).isClean)
    }

    /// A move rewrites the links in the notes that link to the item; an unsaved one of those would
    /// lose its edits or its updated links, so the move waits until it is saved.
    func testMovingAnItemAnUnsavedNoteLinksToIsRefusedUntilTheNoteIsSaved() async throws {
        let root = try makeRoot()
        try write("[b](Other/b.txt)\n", "a.md", in: root)
        try write("x\n", "Other/b.txt", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let a = try XCTUnwrap(doc(store, "a.md"))
        _ = await wait { !store.isDocumentLoading }
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("[b](Other/b.txt) typing\n")

        let b = try XCTUnwrap(doc(store, "Other/b.txt"))
        store.renameDocument(id: b.id, to: "c.txt")
        await idle(store)
        XCTAssertNil(store.pendingMarkdownLinkMoveReview)
        XCTAssertEqual(store.errorMessage, "Save a.md first: this move updates the links in it.")
        XCTAssertEqual(names("Other", in: root), ["b.txt"])
        XCTAssertEqual(store.documentText, "[b](Other/b.txt) typing\n")

        let saved = await store.saveDocument(id: a.id)
        XCTAssertTrue(saved)
        store.renameDocument(id: b.id, to: "c.txt")
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names("Other", in: root), ["c.txt"])
        XCTAssertEqual(try String(contentsOf: a.url, encoding: .utf8), "[b](Other/c.txt) typing\n")
    }

    /// As Finder does, a long name is shortened to fit " copy".
    func testDuplicateOfALongNameFitsTheCopySuffix() async throws {
        let root = try makeRoot()
        let base = String(repeating: "d", count: 250)
        try write("x\n", "\(base).md", in: root)
        try mkdir(String(repeating: "f", count: 252), in: root)
        let store = try await openStore(root)

        store.duplicateItem(at: root.appendingPathComponent("\(base).md"))
        await idle(store)
        let fileError = store.errorMessage
        store.errorMessage = nil
        store.duplicateItem(at: root.appendingPathComponent(String(repeating: "f", count: 252)))
        await idle(store)
        let folderError = store.errorMessage
        XCTAssertNil(fileError)
        XCTAssertNil(folderError)
        XCTAssertTrue(names("", in: root).isSuperset(of: [
            String(repeating: "d", count: 247) + " copy.md",
            String(repeating: "f", count: 250) + " copy",
        ]), "\(names("", in: root))")
    }

    // MARK: - Concurrency and external changes

    /// The real watcher is on: another process adds and removes files while Monknot duplicates.
    func testExternalChangesDuringADuplicateAllReachTheSidebar() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try write("gone\n", "doomed.txt", in: root)
        let store = try await openStore(root, keepWatcher: true)
        defer { store.testing_stopFileWatcher() }

        store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        try write("ext\n", "ext.md", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("doomed.txt"))
        await idle(store)
        let converged = await wait(timeout: 6) {
            Set(store.documents.map(\.relativePath)) == ["a.txt", "a copy.txt", "ext.md"]
        }
        XCTAssertTrue(converged, "\(store.documents.map(\.relativePath))")
    }

    /// A deletion reported while Monknot's own change settles is replayed afterwards and removes
    /// the file from the sidebar.
    func testADeletionHeldDuringAFileOperationReachesTheSidebar() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try write("gone\n", "doomed.txt", in: root)
        let store = try await openStore(root)
        store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        await idle(store)

        let doomed = root.appendingPathComponent("doomed.txt").standardizedFileURL.path
        try FileManager.default.removeItem(atPath: doomed)
        store.testing_scheduleExternalWorkspaceRefresh(WorkspaceFileWatcher.Event(
            changedPaths: [doomed],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        let converged = await wait(timeout: 6) {
            Set(store.documents.map(\.relativePath)) == ["a.txt", "a copy.txt"]
        }
        XCTAssertTrue(converged, "\(store.documents.map(\.relativePath))")
    }

    /// A change reported while a file operation runs waits for it, so the operation's scan, which
    /// read the disk before the change, can't put a deleted file back.
    func testADeletionDuringAFileOperationOutlastsTheOperationsScan() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try write("gone\n", "doomed.txt", in: root)
        let scanner = GatedWorkspaceScanner(scansBeforeWaiting: true)
        let store = try await openStore(root, scanner: scanner)

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        let scanned = await wait(timeout: 6) { scanner.waitingScanCount == 1 }
        XCTAssertTrue(scanned)
        let doomed = root.appendingPathComponent("doomed.txt").standardizedFileURL.path
        try FileManager.default.removeItem(atPath: doomed)
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(WorkspaceFileWatcher.Event(
            changedPaths: [doomed],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        scanner.release()
        await idle(store)

        let converged = await wait(timeout: 6) {
            Set(store.documents.map(\.relativePath)) == ["a.txt", "a copy.txt"]
        }
        XCTAssertTrue(converged, "\(store.documents.map(\.relativePath))")
    }

    func testRapidRepeatedDuplicateRunsOnceAndReportsTheRest() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        let store = try await openStore(root)
        for _ in 0..<3 {
            store.duplicateItem(at: root.appendingPathComponent("a.txt"))
        }
        let message = store.errorMessage
        await idle(store)
        XCTAssertEqual(names("", in: root), ["a.txt", "a copy.txt"])
        XCTAssertEqual(message, "Wait for the current file operation to finish, then try again.")
    }

    func testNewFileInAFolderDeletedBehindMonknotsBackReportsAnError() async throws {
        let root = try makeRoot()
        try write("x\n", "Gone/a.txt", in: root)
        let store = try await openStore(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))

        store.createFile(named: "new.md", in: root.appendingPathComponent("Gone"))
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone").path))
    }

    func testCutSourceDeletedByAnotherProcessBeforePasteLosesNothingElse() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        try write("keep\n", "Sub/keep.txt", in: root)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await settle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(names("Sub", in: root), ["keep.txt"])
    }

    // MARK: - Recents

    func testRenamedDocumentStaysInRecents() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("# B\n", "b.md", in: root)
        let store = try await openStore(root, selecting: "b.md")
        let a = try XCTUnwrap(doc(store, "a.md"))
        store.selectDocument(id: a.id)
        _ = await wait(timeout: 3) { store.recentDocuments().contains { $0.documentID == a.id } }
        XCTAssertTrue(store.recentDocuments().contains { $0.documentID == a.id })

        store.renameDocument(id: a.id, to: "renamed")
        await settle(store)
        XCTAssertNotNil(doc(store, "renamed.md"))
        let renamedID = root.appendingPathComponent("renamed.md").path
        XCTAssertEqual(store.recentDocuments().first?.documentID, renamedID)
        XCTAssertEqual(store.recentDocuments().first?.relativePath, "renamed.md")
        XCTAssertFalse(store.recentDocuments().contains { $0.documentID == a.id })
    }
}
