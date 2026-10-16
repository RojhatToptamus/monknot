import AppKit
import MonknotCore
import XCTest
@testable import MonknotApp

/// Adversarial sweep of copy, cut, paste, duplicate, rename, create and drop at the
/// `WorkspaceStore` level, through the same entry points the sidebar and ⌘C/⌘X/⌘V use.
/// Every clipboard here is a private named pasteboard.
@MainActor
final class FileOperationsQASweepTests: FileOperationsQATestCase {

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

    /// Paste selects (opens) the pasted copy so it is revealed; every paste of the same Copy should
    /// behave the same.
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
        XCTExpectFailure("The second Paste of one Copy goes through the import path and neither selects nor reveals the new copy, unlike the first") {
            XCTAssertEqual(store.selectedDocument?.relativePath, "Sub/a copy.md")
        }
    }

    /// One Copy pasted twice should give two identical copies. The first Paste copies the live
    /// file (with its unsaved edits); later ones copy the hard-link snapshot taken at Copy time.
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
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)

        let first = try String(contentsOf: root.appendingPathComponent("a copy.txt"), encoding: .utf8)
        let second = try String(contentsOf: root.appendingPathComponent("a copy 2.txt"), encoding: .utf8)
        XCTAssertEqual(first, "unsaved edit\n")
        XCTExpectFailure("Second Paste of the same Copy pastes the on-disk snapshot, not the unsaved text the first Paste used") {
            XCTAssertEqual(second, first)
        }
    }

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
        XCTExpectFailure("First Paste copies the file as it is now (v2), the second pastes the snapshot from Copy time (v1)") {
            XCTAssertEqual(first, second)
        }
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
        XCTExpectFailure("A pending Copy is not remapped when Monknot renames the item: Paste fails with 'no such file'") {
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(names("Sub", in: root).count, 1)
        }
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
        XCTExpectFailure("A pending Cut is not remapped when Monknot renames the item: Paste fails and nothing moves") {
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(names("Sub", in: root), ["b.txt"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("Sub/b.txt").path),
            "The cut file was lost")
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

    func testCutFolderWithOpenUnsavedMarkdownIsRefusedWithAReason() async throws {
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
        XCTAssertNotNil(store.errorMessage, "Refused silently")
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.url.path))
        XCTAssertEqual(store.documentText, "# N edited\n", "Unsaved text lost")
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

    /// Two windows on two workspaces share one clipboard. Cut in one, Paste in the other moves in
    /// Finder; here the original stays put and the first window can still move it later.
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
        XCTAssertEqual(names("", in: rootB), ["a.txt"])
        XCTExpectFailure("Cut in one window then Paste in another window copies: the cut original stays, so the user ends with two") {
            XCTAssertFalse(FileManager.default.fileExists(atPath: rootA.appendingPathComponent("a.txt").path))
        }
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

    /// The prompt's validation promises the name works, then creation fails after the sheet closed.
    func testOverlongNamesAreRefusedByValidationBeforeTheSheetCloses() async throws {
        let root = try makeRoot()
        try write("x\n", "a.md", in: root)
        let store = try await openStore(root)
        let tooLong = String(repeating: "n", count: 260) + ".md"

        let createMessage = store.validationMessage(forNewItemNamed: tooLong, in: nil, isDirectory: false)
        let renameMessage = store.validationMessage(forRenaming: root.appendingPathComponent("a.md"), to: tooLong, isDirectory: false)
        store.createFile(named: tooLong)
        await idle(store)
        let createError = store.errorMessage
        XCTAssertNotNil(createError, "Creation of a 263-character name neither failed nor reported")

        XCTExpectFailure("Validation accepts a name longer than the 255-byte file-name limit; the sheet closes and creation fails afterwards") {
            XCTAssertNotNil(createMessage)
            XCTAssertNotNil(renameMessage)
        }
    }

    func testInvalidNewNamesAreRefusedWithoutTouchingDisk() async throws {
        let root = try makeRoot()
        try write("x\n", "Notes.md", in: root)
        try mkdir("Folder", in: root)
        let store = try await openStore(root)
        let before = names("", in: root)

        for name in ["", "   ", ".", "..", "a/b.md", "a:b.md", ".hidden.md", "notes.md", "NOTES.MD", "folder"] {
            XCTAssertNotNil(store.validationMessage(forNewItemNamed: name, in: nil, isDirectory: false), "File \(name)")
            XCTAssertNotNil(store.validationMessage(forNewItemNamed: name, in: nil, isDirectory: true), "Folder \(name)")
            store.createFile(named: name)
            await idle(store)
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
        XCTExpectFailure("Duplicate (and Copy/Paste) of a folder copies its open documents' saved text, dropping unsaved edits that Duplicate of the file keeps") {
            XCTAssertEqual(inFolderCopy, "unsaved\n")
        }
    }

    func testDuplicateWhileBusyIsReported() async throws {
        let root = try makeRoot()
        try write("x\n", "a.txt", in: root)
        let scanner = QAGatedScanner()
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
        let scanner = QAGatedScanner()
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
        XCTAssertFalse(applied.contains("new.txt") && applied.contains("New"), "Unexpectedly queued")
        XCTExpectFailure("New File, New Folder, Rename and Move are dropped without any message while busy (Paste, Duplicate and imports do report)") {
            XCTAssertEqual(silent, [])
        }
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
        XCTExpectFailure("A first line containing ':' or '/' loses the whole title: the note is named '<timestamp> Clipboard.md'") {
            XCTAssertTrue(second.relativePath.contains("Meeting"), second.relativePath)
        }
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

    /// Rich text copied from apps that publish only RTF or HTML has words in it; Paste should not
    /// end in a beep with nothing created. (RTF works through the pasteboard's own conversion.)
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
        XCTExpectFailure("A clipboard holding only HTML pastes nothing (Paste beeps); its text is never read") {
            XCTAssertTrue(htmlPasted, "HTML-only clipboard")
        }
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
        await settle(store)
        XCTExpectFailure("Dropping two or more workspace files from Finder with the Move cursor is refused: 'Move items that are already in the workspace one at a time.'") {
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(names("Sub", in: root), ["a.txt", "b.txt"])
        }
    }

    func testFinderDropWhileBusyIsReported() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("o\n", "o.txt", in: outside)
        try write("x\n", "x.txt", in: root)
        let scanner = QAGatedScanner()
        let store = try await openStore(root, scanner: scanner)

        scanner.hold()
        store.duplicateItem(at: root.appendingPathComponent("x.txt"))
        store.dropFileURLs([outside.appendingPathComponent("o.txt")], into: nil, copying: true)
        XCTAssertNotNil(store.errorMessage)
        scanner.release()
        await idle(store)
    }

    /// Paste (and Finder drop) of items the sidebar does not list copies them into the workspace
    /// and shows nothing, with no message; New File reports the same situation.
    func testPastingFinderItemsTheSidebarDoesNotListIsNotSilent() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("zip", "archive.zip", in: outside)
        try write("mp3", "song.mp3", in: outside)
        try write("# x\n", "dist/inner.md", in: outside)
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects(["archive.zip", "song.mp3", "dist"].map { outside.appendingPathComponent($0) as NSURL })
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertEqual(names("", in: root), ["archive.zip", "song.mp3", "dist"], "Not copied in")
        XCTAssertEqual(store.rootNode?.children?.map(\.name) ?? [], [], "Sidebar shows them")
        XCTExpectFailure("Pasted or dropped zip/mp3 files and a folder named 'dist' are copied into the workspace but never shown, and nothing says so") {
            XCTAssertNotNil(store.errorMessage)
        }
    }

    /// "Rename while dirty": an unrelated plain-text file cannot be renamed (or moved, cut/pasted,
    /// dragged) while any Markdown note anywhere in the workspace has unsaved edits.
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
        store.moveItem(id: b.id, toDirectory: nil)
        await settle(store)
        let moveError = store.errorMessage
        XCTAssertEqual(store.documentText, "# a typing\n")
        XCTExpectFailure("Rename and Move of any item are refused ('Save Markdown changes before renaming or moving workspace items.') while any note is unsaved, even one unrelated to the item") {
            XCTAssertNil(renameError)
            XCTAssertNil(moveError)
        }
    }

    /// Finder shortens a long name to fit " copy"; here Duplicate and the second Paste fail.
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
        XCTExpectFailure("Duplicate of a file or folder whose name is near the 255-byte limit fails with 'file name too long' instead of shortening the copy's name") {
            XCTAssertNil(fileError)
            XCTAssertNil(folderError)
            XCTAssertEqual(names("", in: root).count, 4)
        }
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
        XCTExpectFailure("Recents are not remapped on rename or move: the renamed document drops out of Recents") {
            XCTAssertTrue(store.recentDocuments().contains { $0.documentID == renamedID }, "\(store.recentDocuments().map(\.documentID))")
        }
    }
}
