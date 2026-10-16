import AppKit
import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

/// Workspace file and folder operations at the `WorkspaceStore` level.
///
/// No test here runs a successful `deleteDocument` / `deleteFolder`: those call
/// `FileManager.trashItem` and would put test files into the user's real Trash.
@MainActor
final class WorkspaceFileOperationsTests: WorkspaceStoreTestCase {

    // MARK: - Helpers

    private func wait(
        timeout: TimeInterval = 6,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeRoot() throws -> URL {
        try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOps").standardizedFileURL
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Exact on-disk names of a directory (case-sensitive listing, unlike `fileExists`).
    private func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func openStore(_ root: URL) async throws -> WorkspaceStore {
        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let loaded = await wait { !store.isBusy && store.rootNode != nil && store.workspaceURL != nil }
        XCTAssertTrue(loaded, "Workspace did not load")
        // Keep the real FSEvents watcher from racing the assertions; tests drive events directly.
        store.testing_stopFileWatcher()
        return store
    }

    private func idle(_ store: WorkspaceStore) async {
        _ = await wait { !store.isBusy }
    }

    /// Waits for a rename/move to plan; confirms the link review if one appears.
    private func settleMove(_ store: WorkspaceStore) async {
        _ = await wait { !store.isBusy }
        if let review = store.pendingMarkdownLinkMoveReview {
            store.confirmMarkdownLinkMoveReview(id: review.id)
            _ = await wait { !store.isBusy }
        }
    }

    private func node(_ store: WorkspaceStore, _ relativePath: String) -> SidebarNode? {
        func find(_ node: SidebarNode) -> SidebarNode? {
            if node.relativePath == relativePath { return node }
            for child in node.children ?? [] {
                if let match = find(child) { return match }
            }
            return nil
        }
        return store.rootNode.flatMap(find)
    }

    private func document(_ store: WorkspaceStore, _ relativePath: String) -> WorkspaceDocument? {
        store.documents.first { $0.relativePath == relativePath }
    }

    private func select(_ store: WorkspaceStore, _ relativePath: String) async throws -> WorkspaceDocument {
        let document = try XCTUnwrap(self.document(store, relativePath), "Missing \(relativePath)")
        store.selectDocument(id: document.id)
        _ = await wait { !store.isDocumentLoading && store.selectedDocumentID == document.id }
        return document
    }

    // MARK: - Create folder

    func testCreateNestedFoldersAppearInTreeWithoutAddingDocuments() async throws {
        let root = try makeRoot()
        try write("# Note\n", to: root.appendingPathComponent("Note.md"))
        let store = try await openStore(root)
        let documentsBefore = store.documents

        let revision0 = store.rootNodeRevision
        store.createFolder(named: "Parent")
        await idle(store)
        XCTAssertNotNil(node(store, "Parent"))
        XCTAssertGreaterThan(store.rootNodeRevision, revision0)

        let revision1 = store.rootNodeRevision
        store.createFolder(named: "Child", in: root.appendingPathComponent("Parent", isDirectory: true))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(node(store, "Parent/Child")?.kind, .folder)
        XCTAssertEqual(node(store, "Parent/Child")?.children ?? [], [])
        XCTAssertGreaterThan(store.rootNodeRevision, revision1)
        XCTAssertEqual(store.documents, documentsBefore)
        XCTAssertEqual(store.selectedDocumentID, documentsBefore.first?.id, "Selection is kept")
    }

    func testCreateFolderAcceptsSpacesUnicodeAndDotsAndTrimsWhitespace() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        for (proposed, expected) in [
            ("My Folder", "My Folder"),
            ("Ünïcødé 文件 📁", "Ünïcødé 文件 📁"),
            ("v1.2", "v1.2"),
            ("  Padded  ", "Padded"),
        ] {
            store.createFolder(named: proposed)
            await idle(store)
            XCTAssertNil(store.errorMessage, "\(proposed): \(store.errorMessage ?? "")")
            XCTAssertTrue(names(in: root).contains(expected), "\(expected) not on disk")
            XCTAssertEqual(node(store, expected)?.kind, .folder, "\(expected) not in tree")
        }
    }

    func testCreateFolderRejectsInvalidNamesWithoutTouchingDisk() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let before = names(in: root)

        for invalid in ["", "   ", ".", "..", "a/b", "a:b", "\n"] {
            store.errorMessage = nil
            store.createFolder(named: invalid)
            XCTAssertFalse(store.isBusy, "\(invalid.debugDescription) started an operation")
            XCTAssertNotNil(store.errorMessage, "\(invalid.debugDescription) was not refused")
        }
        XCTAssertEqual(names(in: root), before)
    }

    func testCreateFolderRejectsDuplicatesIncludingCaseVariantsAndFileCollisions() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Docs"))
        try write("x", to: root.appendingPathComponent("Note.md"))
        let store = try await openStore(root)

        for name in ["Docs", "docs", "Note.md", "note.MD"] {
            store.errorMessage = nil
            store.createFolder(named: name)
            await idle(store)
            XCTAssertNotNil(store.errorMessage, "\(name) collision not refused")
        }
        XCTAssertEqual(names(in: root), ["Docs", "Note.md"])
    }

    /// A folder name the scanner hides ("dist", "node_modules", dot-folders) would never appear.
    func testCreatingFolderWithNameTheScannerHidesIsVisibleOrRefused() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        for name in ["dist", "node_modules", ".config"] {
            store.errorMessage = nil
            store.createFolder(named: name)
            await idle(store)
            let visible = node(store, name) != nil
            let refused = store.errorMessage != nil && !exists(root.appendingPathComponent(name))
            XCTAssertTrue(
                visible || refused,
                "\(name): created on disk=\(exists(root.appendingPathComponent(name))), visible=\(visible), error=\(store.errorMessage ?? "nil")"
            )
        }
    }

    func testSuggestedNamesSkipExistingItems() async throws {
        let root = try makeRoot()
        try write("", to: root.appendingPathComponent("Untitled.txt"))
        try makeFolder(root.appendingPathComponent("New Folder"))
        try makeFolder(root.appendingPathComponent("New Folder 2"))
        let store = try await openStore(root)

        XCTAssertEqual(store.suggestedNewFileName(), "Untitled 2.txt")
        XCTAssertEqual(store.suggestedNewFolderName(), "New Folder 3")
    }

    // MARK: - Create file

    func testCreateFileInSubfolderAppearsAndIsSelected() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)

        store.createFile(named: "  Ünïcødé note.md ", in: root.appendingPathComponent("Sub", isDirectory: true))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        let created = try XCTUnwrap(document(store, "Sub/Ünïcødé note.md"))
        XCTAssertEqual(store.selectedDocumentID, created.id)
        XCTAssertEqual(store.documentText, "")
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNotNil(node(store, "Sub/Ünïcødé note.md"))
    }

    func testCreateFileRejectsInvalidAndDuplicateNames() async throws {
        let root = try makeRoot()
        try write("x", to: root.appendingPathComponent("Note.md"))
        try makeFolder(root.appendingPathComponent("Folder"))
        let store = try await openStore(root)
        let before = names(in: root)

        for name in ["", " ", ".", "..", "a/b.md", "x:y.md", "Note.md", "note.md", "Folder", "folder"] {
            store.errorMessage = nil
            store.createFile(named: name)
            await idle(store)
            XCTAssertNotNil(store.errorMessage, "\(name.debugDescription) was not refused")
        }
        XCTAssertEqual(names(in: root), before)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8), "x")
    }

    /// A file the scanner skips (dotfile, unsupported type) is refused before it is created, so
    /// the current document stays selected and loaded.
    func testCreatingFileTheScannerSkipsKeepsSelectionOrIsVisible() async throws {
        let root = try makeRoot()
        try write("# Keep\n", to: root.appendingPathComponent("Keep.md"))
        let store = try await openStore(root)
        let keep = try await select(store, "Keep.md")

        for name in [".env", "archive.xyz", "Buildfile"] {
            store.errorMessage = nil
            store.createFile(named: name)
            await idle(store)
            XCTAssertNotNil(store.errorMessage, name)
            XCTAssertFalse(exists(root.appendingPathComponent(name)), name)
            XCTAssertEqual(store.selectedDocumentID, keep.id)
            XCTAssertEqual(store.documentText, "# Keep\n")
        }
    }

    func testNameValidationMatchesCreateAndRename() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("Sub/A.md"))
        try write("# B\n", to: root.appendingPathComponent("Sub/B.md"))
        let store = try await openStore(root)
        let sub = root.appendingPathComponent("Sub", isDirectory: true)
        let a = root.appendingPathComponent("Sub/A.md")

        XCTAssertNil(store.validationMessage(forNewItemNamed: "Notes.md", in: sub, isDirectory: false))
        XCTAssertNil(store.validationMessage(forNewItemNamed: "Drafts", in: sub, isDirectory: true))
        XCTAssertNil(store.validationMessage(forNewItemNamed: "Drafts", in: nil, isDirectory: true))
        for (name, isDirectory) in [("", false), ("..", true), ("a/b", false), ("B.md", false), (".git", true),
                                    ("node_modules", true), (".notes.md", false), ("data.xyz", false)] {
            XCTAssertNotNil(
                store.validationMessage(forNewItemNamed: name, in: sub, isDirectory: isDirectory),
                name.debugDescription
            )
        }
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        XCTAssertNotNil(store.validationMessage(forNewItemNamed: "x.md", in: outside, isDirectory: false))

        XCTAssertNil(store.validationMessage(forRenaming: a, to: "Release 1.2", isDirectory: false))
        XCTAssertNil(store.validationMessage(forRenaming: a, to: "A", isDirectory: false), "Unchanged name")
        XCTAssertNil(store.validationMessage(forRenaming: a, to: "a.md", isDirectory: false), "Case-only rename")
        XCTAssertNotNil(store.validationMessage(forRenaming: a, to: "b", isDirectory: false))
        XCTAssertNotNil(store.validationMessage(forRenaming: a, to: ".hidden", isDirectory: false))
        XCTAssertNotNil(store.validationMessage(forRenaming: sub, to: "dist", isDirectory: true))
        XCTAssertNil(store.validationMessage(forRenaming: sub, to: "v1.2", isDirectory: true))
        for package in ["Release.app", "X.bundle", "Notes.rtfd"] {
            XCTAssertNotNil(store.validationMessage(forNewItemNamed: package, in: sub, isDirectory: true), package)
            XCTAssertNotNil(store.validationMessage(forRenaming: sub, to: package, isDirectory: true), package)
        }
    }

    /// A folder named like a package would vanish from the sidebar, so it is refused.
    func testCreatingAPackageNamedFolderIsRefused() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        store.createFolder(named: "Notes.rtfd")
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(names(in: root), [])
    }

    func testRenameKeepsTheExtensionUnlessANewDocumentExtensionIsTyped() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)

        for (proposed, expected) in [
            ("Release 1.2", "Release 1.2.md"),
            ("archive.tar", "archive.tar.md"),
            ("Plain.txt", "Plain.txt"),
            ("Back.md", "Back.md"),
        ] {
            let current = try XCTUnwrap(store.documents.first)
            store.renameDocument(id: current.id, to: proposed)
            await settleMove(store)
            XCTAssertNil(store.errorMessage, proposed)
            XCTAssertEqual(names(in: root), [expected], proposed)
        }
    }

    /// A typed extension changes the type only between text documents or names of one file type;
    /// otherwise the file keeps its extension, so an image never turns into a Markdown file.
    func testRenameNeverChangesAFileIntoAnotherKindOfDocument() async throws {
        let root = try makeRoot()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("photo.png"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("shot.jpg"))
        try write("%PDF-1.7\n", to: root.appendingPathComponent("paper.pdf"))
        try Data("RIFF".utf8).write(to: root.appendingPathComponent("tone.wav"))
        try Data("FORM".utf8).write(to: root.appendingPathComponent("loop.aif"))
        try Data([0x00, 0x00, 0x00, 0x14]).write(to: root.appendingPathComponent("clip.mov"))
        let store = try await openStore(root)

        for (source, proposed, expected) in [
            ("photo.png", "photo.md", "photo.md.png"),
            ("photo.md.png", "diagram.jpg", "diagram.jpg.png"),
            ("shot.jpg", "shot.jpeg", "shot.jpeg"),
            ("paper.pdf", "paper.txt", "paper.txt.pdf"),
            ("tone.wav", "tone.mp3", "tone.mp3.wav"),
            ("loop.aif", "loop.aiff", "loop.aiff"),
            ("clip.mov", "Clip Final", "Clip Final.mov"),
            ("Clip Final.mov", "Clip Final.md", "Clip Final.md.mov"),
        ] {
            let document = try XCTUnwrap(self.document(store, source), source)
            store.renameDocument(id: document.id, to: proposed)
            await settleMove(store)
            XCTAssertNil(store.errorMessage, proposed)
            XCTAssertTrue(names(in: root).contains(expected), "\(proposed): \(names(in: root))")
        }
    }

    func testCreateFileAndFolderRefuseDirectoriesOutsideWorkspace() async throws {
        let root = try makeRoot()
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let store = try await openStore(root)

        store.createFile(named: "escape.md", in: outside)
        await idle(store)
        store.createFolder(named: "EscapeFolder", in: outside)
        await idle(store)

        XCTAssertFalse(exists(outside.appendingPathComponent("escape.md")), "File created outside the workspace")
        XCTAssertFalse(exists(outside.appendingPathComponent("EscapeFolder")), "Folder created outside the workspace")
    }

    func testCreateWhileBusyIsIgnored() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        store.createFolder(named: "First")
        XCTAssertTrue(store.isBusy)
        store.createFolder(named: "Second")
        store.createFile(named: "Third.md")
        await idle(store)

        XCTAssertNotNil(node(store, "First"))
        XCTAssertFalse(exists(root.appendingPathComponent("Second")))
        XCTAssertFalse(exists(root.appendingPathComponent("Third.md")))
    }

    // MARK: - Rename

    func testRenameFileKeepsExtensionWhenOmitted() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "A.md"))

        store.renameDocument(id: a.id, to: "  Renamed  ")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Renamed.md"])
        XCTAssertNotNil(document(store, "Renamed.md"))
    }

    func testRenameFileWithDotInNewNameKeepsMarkdownExtension() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "A.md"))

        store.renameDocument(id: a.id, to: "Meeting 10.30")
        await settleMove(store)
        XCTAssertEqual(
            names(in: root), ["Meeting 10.30.md"],
            "on disk: \(names(in: root)), documents: \(store.documents.map(\.relativePath))"
        )
    }

    /// A dot-name would hide the file from the sidebar and from any open tab.
    func testRenameFileToDotNameIsRefused() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("B.md"))
        let store = try await openStore(root)

        let a = try XCTUnwrap(document(store, "A.md"))
        store.renameDocument(id: a.id, to: ".")
        await settleMove(store)
        let b = try XCTUnwrap(document(store, "B.md"))
        store.renameDocument(id: b.id, to: ".hidden")
        await settleMove(store)

        XCTAssertEqual(names(in: root), ["A.md", "B.md"], "on disk: \(names(in: root))")
    }

    /// A name the scanner hides would make the folder and every document inside it vanish.
    func testRenamingFolderToHiddenNameIsVisibleOrRefused() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("Folder/N.md"))
        let store = try await openStore(root)

        store.renameFolder(id: root.appendingPathComponent("Folder").path, to: "node_modules")
        await settleMove(store)
        let visible = node(store, "node_modules") != nil
        let refused = store.errorMessage != nil && exists(root.appendingPathComponent("Folder"))
        XCTAssertTrue(visible || refused, "on disk: \(names(in: root)), documents: \(store.documents.map(\.relativePath))")
    }

    func testRenameFolderRejectsInvalidNames() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("Folder/N.md"))
        let store = try await openStore(root)
        let folderID = root.appendingPathComponent("Folder").path

        for name in ["", "  ", ".", "..", "a/b", "a:b"] {
            store.errorMessage = nil
            store.renameFolder(id: folderID, to: name)
            await settleMove(store)
            XCTAssertNotNil(store.errorMessage, "\(name.debugDescription) was not refused")
        }
        XCTAssertEqual(names(in: root), ["Folder"])
        XCTAssertEqual(names(in: root.appendingPathComponent("Folder")), ["N.md"])

        store.errorMessage = nil
        store.renameFolder(id: root.path, to: "Other")
        XCTAssertNotNil(store.errorMessage, "Workspace root rename refused")
    }

    func testRenameToExistingNameIsRefusedForFilesAndFolders() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("B.md"))
        try makeFolder(root.appendingPathComponent("X"))
        try makeFolder(root.appendingPathComponent("Y"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "A.md"))

        store.renameDocument(id: a.id, to: "b")
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)

        store.errorMessage = nil
        store.renameFolder(id: root.appendingPathComponent("X").path, to: "y")
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["A.md", "B.md", "X", "Y"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("B.md"), encoding: .utf8), "# B\n")
    }

    func testCaseOnlyRenameOfFileAndFolderChangesCasingOnDisk() async throws {
        let root = try makeRoot()
        try write("# Note\n", to: root.appendingPathComponent("folder/note.md"))
        let store = try await openStore(root)
        let note = try XCTUnwrap(document(store, "folder/note.md"))

        store.renameDocument(id: note.id, to: "NOTE.md")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("folder")), ["NOTE.md"])

        store.renameFolder(id: root.appendingPathComponent("folder").path, to: "Folder")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Folder"])
        XCTAssertNotNil(document(store, "Folder/NOTE.md"))
        XCTAssertNotNil(node(store, "Folder"))
        XCTAssertNil(node(store, "folder"))
    }

    func testRenameDirtyMarkdownDocumentCarriesUnsavedText() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)
        let a = try await select(store, "A.md")
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("# A\nedited\n")
        XCTAssertTrue(store.hasUnsavedChanges)

        store.renameDocument(id: a.id, to: "B")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["B.md"])
        let renamedID = root.appendingPathComponent("B.md").path
        XCTAssertEqual(store.selectedDocumentID, renamedID)
        XCTAssertEqual(store.documentText, "# A\nedited\n")
        XCTAssertFalse(store.saveState(for: renamedID).isClean)
    }

    func testRenameIsRefusedWhileADirtyDocumentWouldHaveItsLinksRewritten() async throws {
        let root = try makeRoot()
        try write("# A\n[b](B.md)\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("B.md"))
        let store = try await openStore(root)
        let a = try await select(store, "A.md")
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("# A\n[b](B.md)\nedited\n")
        let b = try XCTUnwrap(document(store, "B.md"))

        store.renameDocument(id: b.id, to: "C")
        await settleMove(store)
        XCTAssertEqual(store.errorMessage, "Save A.md first: this move updates the links in it.")
        XCTAssertEqual(names(in: root), ["A.md", "B.md"])
        XCTAssertEqual(store.documentText, "# A\n[b](B.md)\nedited\n")

        // Renaming the unsaved note itself rewrites no other file, so its text moves with it.
        store.renameDocument(id: a.id, to: "Renamed")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Renamed.md", "B.md"])
        XCTAssertEqual(store.documentText, "# A\n[b](B.md)\nedited\n")
    }

    func testRenameDirtyPlainTextDocumentCarriesUnsavedTextAndSelection() async throws {
        let root = try makeRoot()
        try write("original\n", to: root.appendingPathComponent("notes.txt"))
        let store = try await openStore(root)
        let notes = try await select(store, "notes.txt")
        store.setOpenDocumentIDs([notes.id])
        store.setDocumentText("edited\n")

        store.renameDocument(id: notes.id, to: "renamed")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        let renamedID = root.appendingPathComponent("renamed.txt").path
        XCTAssertEqual(store.selectedDocumentID, renamedID)
        XCTAssertEqual(store.documentText, "edited\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.saveState(for: renamedID).isClean)
        XCTAssertEqual(store.documentIDRemapEvent?.mappings.first?.sourceID, notes.id)
        XCTAssertEqual(store.documentIDRemapEvent?.mappings.first?.destinationID, renamedID)

        let saved = await store.saveDocument(id: renamedID)
        XCTAssertTrue(saved, store.errorMessage ?? "")
        XCTAssertEqual(try String(contentsOfFile: renamedID, encoding: .utf8), "edited\n")
        XCTAssertFalse(exists(root.appendingPathComponent("notes.txt")))
    }

    func testRenameFolderContainingSelectedDocumentRemapsSelectionAndChildren() async throws {
        let root = try makeRoot()
        try write("# Doc\n", to: root.appendingPathComponent("A/Doc.md"))
        try write("# Deep\n", to: root.appendingPathComponent("A/Inner/Deep.md"))
        try write("# AB\n", to: root.appendingPathComponent("AB/Other.md"))
        let store = try await openStore(root)
        let doc = try await select(store, "A/Doc.md")
        store.setOpenDocumentIDs([doc.id])

        store.renameFolder(id: root.appendingPathComponent("A").path, to: "Renamed")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)

        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("Renamed/Doc.md").path)
        XCTAssertEqual(store.documentText, "# Doc\n")
        let mappings = store.documentIDRemapEvent?.mappings ?? []
        XCTAssertEqual(Set(mappings.map(\.destinationID)), [
            root.appendingPathComponent("Renamed/Doc.md").path,
            root.appendingPathComponent("Renamed/Inner/Deep.md").path,
        ], "Sibling folder AB (shared prefix) must not be remapped")
        XCTAssertNotNil(node(store, "Renamed/Inner"))
        XCTAssertNil(node(store, "A"))
        XCTAssertNotNil(document(store, "AB/Other.md"))
    }

    // MARK: - Markdown link updates on move

    func testMovingLinkedFileRewritesInboundAndOutboundRelativeLinks() async throws {
        let root = try makeRoot()
        try write("[t](Target.md)\n", to: root.appendingPathComponent("Source.md"))
        try write("# T\n[s](Source.md)\n", to: root.appendingPathComponent("Target.md"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)

        store.moveItem(id: root.appendingPathComponent("Target.md").path, toDirectory: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Source.md"), encoding: .utf8), "[t](Sub/Target.md)\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sub/Target.md"), encoding: .utf8), "# T\n[s](../Source.md)\n")
    }

    func testRenamingFolderRewritesLinksIntoIt() async throws {
        let root = try makeRoot()
        try write("[d](Docs/Guide%20One.md) and [x](Docs/Guide%20One.md#intro)\n", to: root.appendingPathComponent("Index.md"))
        try write("# Guide\n", to: root.appendingPathComponent("Docs/Guide One.md"))
        let store = try await openStore(root)

        store.renameFolder(id: root.appendingPathComponent("Docs").path, to: "Manual")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8),
            "[d](Manual/Guide%20One.md) and [x](Manual/Guide%20One.md#intro)\n"
        )
    }

    // MARK: - Move

    func testMoveFileIntoSubfolderAndBackToRoot() async throws {
        let root = try makeRoot()
        try write("plain\n", to: root.appendingPathComponent("a.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)

        store.moveItem(id: root.appendingPathComponent("a.txt").path, toDirectory: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "Sub/a.txt"))
        XCTAssertNil(document(store, "a.txt"))

        store.moveItem(id: root.appendingPathComponent("Sub/a.txt").path, toDirectory: nil)
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "a.txt"))
        XCTAssertEqual(node(store, "Sub")?.children ?? [], [], "Emptied folder stays in the tree")
    }

    func testMoveFolderIntoItselfOrDescendantIsRefused() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("A/B/C/x.txt"))
        let store = try await openStore(root)
        let a = root.appendingPathComponent("A")

        for target in [a, a.appendingPathComponent("B"), a.appendingPathComponent("B/C")] {
            store.errorMessage = nil
            store.moveItem(id: a.path, toDirectory: target)
            await settleMove(store)
            if target == a {
                // Moving into its own folder is "already there"; must still be harmless.
                XCTAssertTrue(exists(a.appendingPathComponent("B/C/x.txt")))
            } else {
                XCTAssertNotNil(store.errorMessage, "Move into \(target.lastPathComponent) not refused")
            }
        }
        XCTAssertEqual(names(in: root), ["A"])
        XCTAssertTrue(exists(a.appendingPathComponent("B/C/x.txt")))
    }

    func testMoveOntoFileCollisionAndOutsideWorkspaceAreRefused() async throws {
        let root = try makeRoot()
        try write("root\n", to: root.appendingPathComponent("Note.txt"))
        try write("sub\n", to: root.appendingPathComponent("Sub/note.TXT"))
        try write("other\n", to: root.appendingPathComponent("Other.txt"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let store = try await openStore(root)

        // Onto a file row.
        store.moveItem(id: root.appendingPathComponent("Other.txt").path, toDirectory: root.appendingPathComponent("Note.txt"))
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)

        // Case-variant collision in the destination.
        store.errorMessage = nil
        store.moveItem(id: root.appendingPathComponent("Note.txt").path, toDirectory: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)

        // Outside the workspace.
        store.errorMessage = nil
        store.moveItem(id: root.appendingPathComponent("Other.txt").path, toDirectory: outside)
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)

        XCTAssertEqual(names(in: root), ["Note.txt", "Sub", "Other.txt"])
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["note.TXT"])
        XCTAssertEqual(names(in: outside), [])
    }

    func testMoveIntoSameFolderIsNoop() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("Sub/a.txt"))
        let store = try await openStore(root)
        let revision = store.rootNodeRevision

        store.moveItem(id: root.appendingPathComponent("Sub/a.txt").path, toDirectory: root.appendingPathComponent("Sub"))
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.rootNodeRevision, revision)
    }

    func testMoveFolderContainingSelectedDirtyTextDocumentRemapsSelection() async throws {
        let root = try makeRoot()
        try write("v1\n", to: root.appendingPathComponent("Proj/todo.txt"))
        try makeFolder(root.appendingPathComponent("Archive"))
        let store = try await openStore(root)
        let todo = try await select(store, "Proj/todo.txt")
        store.setOpenDocumentIDs([todo.id])
        store.setDocumentText("v2\n")

        store.moveItem(id: root.appendingPathComponent("Proj").path, toDirectory: root.appendingPathComponent("Archive"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        let newID = root.appendingPathComponent("Archive/Proj/todo.txt").path
        XCTAssertEqual(store.selectedDocumentID, newID)
        XCTAssertEqual(store.documentText, "v2\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNotNil(node(store, "Archive/Proj"))
    }

    // MARK: - Copy / cut / paste inside the workspace

    func testCopyPasteCreatesCopySuffixesAndCarriesUnsavedText() async throws {
        let root = try makeRoot()
        try write("disk\n", to: root.appendingPathComponent("a.txt"))
        try write("make\n", to: root.appendingPathComponent("Makefile"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let a = try await select(store, "a.txt")
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("unsaved\n")

        store.copyItem(at: a.url)
        XCTAssertTrue(store.canPasteDocumentTransfer)
        store.pasteDocumentTransfer()
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a copy.txt"), encoding: .utf8), "unsaved\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "disk\n")
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("a copy.txt").path)
        XCTAssertTrue(store.canPasteDocumentTransfer, "A Copy can be pasted again")

        // The original's unsaved text survives the selection change.
        XCTAssertFalse(store.saveState(for: a.id).isClean)

        let makefile = try XCTUnwrap(document(store, "Makefile"))
        store.copyItem(at: makefile.url)
        store.pasteDocumentTransfer()
        await idle(store)
        store.copyItem(at: makefile.url)
        store.pasteDocumentTransfer()
        await idle(store)
        store.copyItem(at: makefile.url)
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertTrue(names(in: root).isSuperset(of: ["Makefile copy", "Makefile copy 2"]))
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["Makefile"])
    }

    func testCopyPasteRefusesTargetOutsideWorkspace() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("a.txt"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "a.txt"))

        store.copyItem(at: a.url)
        store.pasteDocumentTransfer(into: outside)
        await idle(store)
        XCTAssertEqual(names(in: outside), [], "Copied outside the workspace")
    }

    func testCutPasteMovesAndSameFolderPasteIsNoop() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("a.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "a.txt"))

        store.cutItem(at: a.url)
        store.pasteDocumentTransfer() // same folder
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(exists(root.appendingPathComponent("a.txt")))
        XCTAssertFalse(store.canPasteDocumentTransfer)

        store.cutItem(at: a.url)
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["a.txt"])
        XCTAssertFalse(exists(root.appendingPathComponent("a.txt")))
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("Sub/a.txt").path)
        XCTAssertFalse(store.canPasteDocumentTransfer)
    }

    func testCutPasteOntoExistingNameRenamesWithCopySuffix() async throws {
        let root = try makeRoot()
        try write("root\n", to: root.appendingPathComponent("a.txt"))
        try write("sub\n", to: root.appendingPathComponent("Sub/a.txt"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "a.txt"))

        store.cutItem(at: a.url)
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["a.txt", "a copy.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sub/a.txt"), encoding: .utf8), "sub\n")
    }

    func testCutSourceRenamedBeforePasteReportsErrorWithoutDamage() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("a.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let a = try XCTUnwrap(document(store, "a.txt"))
        store.cutItem(at: a.url)

        try FileManager.default.moveItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("b.txt"))
        store.refresh()
        _ = await wait { self.document(store, "b.txt") != nil }

        store.pasteDocumentTransfer(into: root.appendingPathComponent("Sub"))
        await settleMove(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), [])
        XCTAssertTrue(exists(root.appendingPathComponent("b.txt")))
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MonknotFileOps-\(UUID().uuidString)"))
    }

    /// ⌘X then ⌘V (and the Paste menu items) move the file. The moved item then leaves the
    /// clipboard, so a second ⌘V has nothing to paste instead of copying the stale snapshot back.
    func testCutThenPasteMovesTheFileAndClearsTheClipboard() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("a.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        let stamp = try XCTUnwrap(store.pendingTransferPasteboardStamp)
        XCTAssertTrue(WorkspacePasteboardExportService.holdsTransfer(stamp, on: pasteboard))
        XCTAssertEqual(
            WorkspacePasteboardExportService.workspaceFileURLs(on: pasteboard)?.map(\.lastPathComponent),
            ["a.txt"]
        )
        XCTAssertEqual(try WorkspacePasteboardImportService.importItems(from: pasteboard).count, 1)

        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["a.txt"])
        XCTAssertFalse(exists(root.appendingPathComponent("a.txt")))
        XCTAssertNil(pasteboard.pasteboardItems?.first, "The moved item is still on the clipboard")

        XCTAssertFalse(store.pasteFromPasteboard(pasteboard, into: nil), "A second Paste found something")
        await idle(store)
        XCTAssertEqual(names(in: root), ["Sub"])
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["a.txt"])
    }

    /// A folder has no snapshot, so a second ⌘V after moving it would fail on the old location.
    func testCutPasteOfAFolderClearsTheClipboard() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("Folder/N.md"))
        try makeFolder(root.appendingPathComponent("Archive"))
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.putItemOnPasteboard(at: root.appendingPathComponent("Folder"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Archive")))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.pasteFromPasteboard(pasteboard, into: nil))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Archive"])
    }

    /// Each window has its own store. A Cut in one window followed by a Copy in another leaves the
    /// clipboard holding the Copy, so Paste in the first window copies that item and moves nothing.
    func testPasteAfterAnotherWindowCopiedUsesTheClipboardNotTheEarlierCut() async throws {
        let root = try makeRoot()
        try write("a\n", to: root.appendingPathComponent("a.txt"))
        try write("b\n", to: root.appendingPathComponent("b.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let windowA = try await openStore(root)
        let windowB = try await openStore(root)
        let pasteboard = makePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        windowA.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        windowB.putItemOnPasteboard(at: root.appendingPathComponent("b.txt"), cutting: false, pasteboard: pasteboard)

        XCTAssertTrue(windowA.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(windowA)
        XCTAssertNil(windowA.errorMessage)
        XCTAssertTrue(exists(root.appendingPathComponent("a.txt")), "Window A moved its cut file")
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["b.txt"])
        XCTAssertFalse(windowA.canPasteDocumentTransfer)
        XCTAssertTrue(windowB.canPasteDocumentTransfer)
    }

    /// Any other copy replaces the item a Cut wrote, so Paste imports the new clipboard contents.
    func testPasteAfterTheClipboardChangedDropsThePendingCut() async throws {
        let root = try makeRoot()
        try write("a\n", to: root.appendingPathComponent("a.txt"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Plain words", forType: .string)

        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertTrue(exists(root.appendingPathComponent("a.txt")))
        XCTAssertFalse(exists(root.appendingPathComponent("Sub/a.txt")))
        XCTAssertFalse(store.canPasteDocumentTransfer)
    }

    /// A Copy or Cut that fails ends the earlier one, whose item the clipboard may no longer hold.
    func testFailedCopyEndsTheEarlierCut() async throws {
        let root = try makeRoot()
        try write("a\n", to: root.appendingPathComponent("a.txt"))
        let store = try await openStore(root)
        let pasteboard = makePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        store.putItemOnPasteboard(at: root.appendingPathComponent("a.txt"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.canPasteDocumentTransfer)
        store.putItemOnPasteboard(at: root.appendingPathComponent("missing.txt"), cutting: false, pasteboard: pasteboard)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.canPasteDocumentTransfer)
    }

    func testPasteFromAForeignClipboardImportsItsFiles() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Sub"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        try write("o\n", to: outside.appendingPathComponent("o.txt"))
        let store = try await openStore(root)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotFileOps-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        XCTAssertFalse(store.pasteFromPasteboard(pasteboard, into: nil), "Nothing to paste")
        pasteboard.writeObjects([outside.appendingPathComponent("o.txt") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: root.appendingPathComponent("Sub")))
        await idle(store)
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["o.txt"])
    }

    /// Video and audio are workspace documents, so they copy, duplicate and import like any other.
    func testMediaFilesCopyDuplicateAndImportFromFinder() async throws {
        let root = try makeRoot()
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsMediaOutside")
        try makeFolder(root.appendingPathComponent("Sub"))
        try Data("RIFF".utf8).write(to: root.appendingPathComponent("tone.wav"))
        try Data([0x00, 0x00, 0x00, 0x14]).write(to: outside.appendingPathComponent("Trip.MOV"))
        let store = try await openStore(root)
        let tone = try XCTUnwrap(document(store, "tone.wav"))
        XCTAssertEqual(tone.kind, .media)

        store.duplicateItem(at: tone.url)
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(document(store, "tone copy.wav")?.kind, .media)
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("tone copy.wav").path)

        store.copyItem(at: tone.url)
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(document(store, "Sub/tone.wav")?.kind, .media)

        store.dropFileURLs([outside.appendingPathComponent("Trip.MOV")], into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(document(store, "Sub/Trip.MOV")?.kind, .media)
    }

    func testCopyCutAndDuplicateFolders() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("Folder/N.md"))
        try makeFolder(root.appendingPathComponent("Archive"))
        let store = try await openStore(root)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let selected = store.selectedDocumentID

        store.duplicateItem(at: folder)
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "Folder copy/N.md"))
        XCTAssertEqual(store.selectedDocumentID, selected, "Copying a folder keeps the selection")

        store.copyItem(at: folder)
        store.pasteDocumentTransfer(into: folder.appendingPathComponent("Inner"))
        XCTAssertNotNil(store.errorMessage, "A folder cannot be pasted into itself")
        store.errorMessage = nil
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Archive"))
        await idle(store)
        XCTAssertNotNil(document(store, "Archive/Folder/N.md"))
        XCTAssertNotNil(document(store, "Folder/N.md"))

        store.cutItem(at: folder)
        store.pasteDocumentTransfer(into: folder)
        XCTAssertNotNil(store.errorMessage, "A folder cannot be moved into itself")
        store.errorMessage = nil
        store.cutItem(at: folder)
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Archive"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Archive")), ["Folder", "Folder copy"])
        XCTAssertFalse(exists(folder))
    }

    /// Moving a folder never selects some other document: the selection stays, and a selection
    /// inside the moved folder follows it to its new path.
    func testCutPasteOfAFolderKeepsAndRemapsTheSelection() async throws {
        let root = try makeRoot()
        try write("# O\n", to: root.appendingPathComponent("Other.md"))
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# N\n", to: root.appendingPathComponent("Folder/N.md"))
        try makeFolder(root.appendingPathComponent("Archive"))
        let store = try await openStore(root)
        _ = try await select(store, "Other.md")

        store.cutItem(at: root.appendingPathComponent("Folder"))
        store.pasteDocumentTransfer(into: root.appendingPathComponent("Archive"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "Archive/Folder/N.md"))
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("Other.md").path)

        _ = try await select(store, "Archive/Folder/N.md")
        store.cutItem(at: root.appendingPathComponent("Archive/Folder"))
        store.pasteDocumentTransfer(into: nil)
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("Folder/N.md").path)
        XCTAssertEqual(store.documentText, "# N\n")
    }

    func testDuplicateFolderWithADotKeepsItsWholeName() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("v1.2/N.md"))
        let store = try await openStore(root)

        store.duplicateItem(at: root.appendingPathComponent("v1.2"))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["v1.2", "v1.2 copy"])
        XCTAssertNotNil(document(store, "v1.2 copy/N.md"))
    }

    /// Whatever a failed folder copy left on disk shows in the sidebar right away.
    func testPartiallyFailedFolderCopyShowsWhatWasCopied() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("Folder/A.md"))
        let unreadable = root.appendingPathComponent("Folder/Z.md")
        try write("# Z\n", to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let store = try await openStore(root)

        store.duplicateItem(at: root.appendingPathComponent("Folder"))
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(exists(root.appendingPathComponent("Folder copy")))
        XCTAssertNotNil(node(store, "Folder copy"), "The partial copy is missing from the sidebar")
    }

    func testDuplicateFileCarriesUnsavedTextAndSelectsTheCopy() async throws {
        let root = try makeRoot()
        try write("disk\n", to: root.appendingPathComponent("Sub/a.txt"))
        let store = try await openStore(root)
        let a = try await select(store, "Sub/a.txt")
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("unsaved\n")

        store.duplicateItem(at: a.url)
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sub/a copy.txt"), encoding: .utf8), "unsaved\n")
        XCTAssertEqual(store.selectedDocumentID, root.appendingPathComponent("Sub/a copy.txt").path)
        XCTAssertFalse(store.saveState(for: a.id).isClean)
    }

    // MARK: - Import (external paste / drop)

    func testImportExternalFilesAndFolderIntoRootAndSubfolder() async throws {
        let root = try makeRoot()
        try write("# Existing\n", to: root.appendingPathComponent("Doc.md"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let externalFile = outside.appendingPathComponent("Doc.md")
        try write("# External\n", to: externalFile)
        let externalFolder = outside.appendingPathComponent("Bundle")
        try write("# Inner\n", to: externalFolder.appendingPathComponent("Inner.md"))
        try makeFolder(externalFolder.appendingPathComponent("EmptyChild"))
        let store = try await openStore(root)
        let selectedBefore = store.selectedDocumentID

        store.importPasteboardItems([.fileURL(externalFile), .fileURL(externalFolder)])
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "Doc copy.md"))
        XCTAssertNotNil(document(store, "Bundle/Inner.md"))
        XCTAssertNotNil(node(store, "Bundle/EmptyChild"))
        XCTAssertEqual(store.selectedDocumentID, selectedBefore, "File imports keep selection")

        store.importPasteboardItems([.fileURL(externalFile)], into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertNotNil(document(store, "Sub/Doc.md"))
        XCTAssertTrue(exists(externalFile), "Import copies, never moves")
    }

    func testImportFolderIntoItselfOrOutsideWorkspaceIsRefused() async throws {
        let root = try makeRoot()
        try write("x\n", to: root.appendingPathComponent("Sub/a.txt"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let store = try await openStore(root)

        store.importPasteboardItems([.fileURL(root.appendingPathComponent("Sub"))], into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertNotNil(store.errorMessage)

        store.errorMessage = nil
        store.importPasteboardItems([.fileURL(root)])
        await idle(store)
        XCTAssertNotNil(store.errorMessage, "Workspace root dropped onto itself must be refused")

        store.errorMessage = nil
        try write("o\n", to: outside.appendingPathComponent("o.txt"))
        store.importPasteboardItems([.fileURL(outside.appendingPathComponent("o.txt"))], into: outside)
        XCTAssertNotNil(store.errorMessage)

        XCTAssertEqual(names(in: root), ["Sub"])
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), ["a.txt"])
    }

    /// A Finder drop of an item that is already in the workspace moves it instead of copying it.
    func testDroppingWorkspaceFileFromFinderMovesIt() async throws {
        let root = try makeRoot()
        try write("[a](Sub/a.md)\n", to: root.appendingPathComponent("Index.md"))
        try write("# A\n", to: root.appendingPathComponent("Sub/a.md"))
        try makeFolder(root.appendingPathComponent("Other"))
        let store = try await openStore(root)

        store.dropFileURLs([root.appendingPathComponent("Sub/a.md")], into: root.appendingPathComponent("Other"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Other")), ["a.md"])
        XCTAssertEqual(names(in: root.appendingPathComponent("Sub")), [])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8), "[a](Other/a.md)\n")

        // Several items move one after another to the root; a.md is already there.
        try makeFolder(root.appendingPathComponent("Other/Deeper"))
        store.dropFileURLs([root.appendingPathComponent("Other/a.md"), root.appendingPathComponent("Other/Deeper")])
        for _ in 0..<2 {
            await settleMove(store)
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Index.md", "Sub", "Other", "a.md", "Deeper"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Index.md"), encoding: .utf8), "[a](a.md)\n")
    }

    /// An Option-drop copies a workspace item, leaving the original and its links in place.
    func testCopyingDropOfAWorkspaceItemCopiesIt() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("Sub/a.md"))
        try write("# B\n", to: root.appendingPathComponent("b.md"))
        try makeFolder(root.appendingPathComponent("Other"))
        let store = try await openStore(root)

        store.dropFileURLs(
            [root.appendingPathComponent("Sub/a.md"), root.appendingPathComponent("b.md")],
            into: root.appendingPathComponent("Other"),
            copying: true
        )
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root.appendingPathComponent("Other")), ["a.md", "b.md"])
        XCTAssertTrue(exists(root.appendingPathComponent("Sub/a.md")))
        XCTAssertTrue(exists(root.appendingPathComponent("b.md")))
    }

    func testFinderDropImportsIntoTheTargetFolder() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Sub"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        try write("o\n", to: outside.appendingPathComponent("o.txt"))
        let store = try await openStore(root)

        store.dropFileURLs([outside.appendingPathComponent("o.txt")], into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(document(store, "Sub/o.txt"))
        XCTAssertTrue(exists(outside.appendingPathComponent("o.txt")))
    }

    func testDroppingSeveralFoldersWithoutAWorkspaceIsRefused() throws {
        let first = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsFirst")
        let second = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsSecond")
        let store = makeWorkspaceStore()

        store.dropFileURLs([first, second])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.workspaceURL)
        XCTAssertFalse(store.isWorkspaceOpening)
    }

    /// Files copied before an import fails stay on disk, and the sidebar shows them.
    func testPartiallyFailedImportStillShowsFilesThatWereCopied() async throws {
        let root = try makeRoot()
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        let good = outside.appendingPathComponent("Good.md")
        try write("# Good\n", to: good)
        let missing = outside.appendingPathComponent("Missing.md")
        let store = try await openStore(root)

        store.importPasteboardItems([.fileURL(good), .fileURL(missing)])
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        let onDisk = exists(root.appendingPathComponent("Good.md"))
        XCTAssertTrue(
            !onDisk || document(store, "Good.md") != nil,
            "Good.md on disk=\(onDisk) but in documents=\(document(store, "Good.md") != nil)"
        )
    }

    func testPastedTextLandsInInboxOfTargetAndIsSelected() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)
        let item = try XCTUnwrap(WorkspacePasteboardImportService.capturedTextItem(from: "Hello world\nbody", isURL: false))

        store.importPasteboardItems([item])
        await idle(store)
        XCTAssertNil(store.errorMessage)
        let selected = try XCTUnwrap(store.selectedDocument)
        XCTAssertTrue(selected.relativePath.hasPrefix("inbox/"), selected.relativePath)
        XCTAssertTrue(selected.relativePath.hasSuffix("Hello world.md"), selected.relativePath)
        _ = await wait { !store.isDocumentLoading }
        XCTAssertEqual(store.documentText, "# Hello world\n\nHello world\nbody\n")

        store.importPasteboardItems([item], into: root.appendingPathComponent("Sub"))
        await idle(store)
        XCTAssertTrue(store.selectedDocument?.relativePath.hasPrefix("Sub/inbox/") == true)
    }

    func testPastedImagesLandInTargetDirectoryWithCopySuffixes() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(WorkspacePasteboardImportService.pngData(for: image))

        store.importPasteboardItems([.pngImageData(png), .pngImageData(png)])
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(names(in: root), ["Pasted Image.png", "Pasted Image copy.png"])
        XCTAssertEqual(store.documents.count, 2, "\(store.documents.map(\.relativePath))")

        store.importPasteboardItems([.pngImageData(png, suggestedName: "../escape.png")])
        await idle(store)
        XCTAssertFalse(exists(root.deletingLastPathComponent().appendingPathComponent("escape.png")))
    }

    func testImportWhileBusyIsNotSilentlyDropped() async throws {
        let root = try makeRoot()
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        try write("x\n", to: outside.appendingPathComponent("drop.txt"))
        let store = try await openStore(root)

        store.createFolder(named: "Busy")
        XCTAssertTrue(store.isBusy)
        store.importPasteboardItems([.fileURL(outside.appendingPathComponent("drop.txt"))])
        let messageWhileBusy = store.errorMessage
        await idle(store)
        XCTAssertTrue(
            exists(root.appendingPathComponent("drop.txt")) || messageWhileBusy != nil,
            "Dropped file neither imported nor reported"
        )
    }

    // MARK: - Delete (guard paths only) and post-delete refresh

    func testDeleteGuardsRefuseWithoutTouchingDisk() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("Folder/B.md"))
        let store = try await openStore(root)
        let a = try await select(store, "A.md")
        store.setOpenDocumentIDs([a.id])
        store.setDocumentText("# A\nedited\n")

        store.deleteDocument(a)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.errorMessage, "Save or close A.md before moving it to the Trash.")

        // A document that is not part of the workspace is ignored.
        let foreign = WorkspaceDocument(
            url: URL(fileURLWithPath: "/nonexistent/Foreign.md"),
            rootURL: URL(fileURLWithPath: "/nonexistent")
        )
        store.errorMessage = nil
        store.deleteDocument(foreign)
        XCTAssertFalse(store.isBusy)

        // Root, outside, and prefix-sibling folders are refused.
        store.deleteFolder(at: root)
        XCTAssertFalse(store.isBusy)
        store.deleteFolder(at: root.deletingLastPathComponent())
        XCTAssertFalse(store.isBusy)
        store.deleteFolder(at: URL(fileURLWithPath: root.path + "-sibling"))
        XCTAssertFalse(store.isBusy)

        XCTAssertTrue(exists(root.appendingPathComponent("A.md")))
        XCTAssertTrue(exists(root.appendingPathComponent("Folder/B.md")))
    }

    func testRefreshAfterExternalRemovalUpdatesTreeAndSelection() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("Folder/B.md"))
        let store = try await openStore(root)
        let b = try await select(store, "Folder/B.md")
        XCTAssertEqual(store.selectedDocumentID, b.id)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder"))
        store.refresh()
        let refreshed = await wait { self.node(store, "Folder") == nil }
        XCTAssertTrue(refreshed)
        XCTAssertNil(document(store, "Folder/B.md"))
        XCTAssertEqual(store.selectedDocumentID, document(store, "A.md")?.id)
    }

    func testRemovingOpenDirtyDocumentKeepsItsUnsavedText() async throws {
        let root = try makeRoot()
        try write("one\n", to: root.appendingPathComponent("keep.txt"))
        try write("x\n", to: root.appendingPathComponent("other.txt"))
        let store = try await openStore(root)
        let keep = try await select(store, "keep.txt")
        store.setOpenDocumentIDs([keep.id])
        store.setDocumentText("two\n")

        try FileManager.default.removeItem(at: keep.url)
        store.refresh()
        _ = await wait { self.document(store, "keep.txt") == nil }
        XCTAssertEqual(store.selectedDocumentID, keep.id)
        XCTAssertEqual(store.documentText, "two\n")
        XCTAssertTrue(store.removedDirtyOpenDocumentIDs.contains(keep.id))
        XCTAssertTrue(store.selectedDocumentExternalChange)
    }

    // MARK: - External changes (FSEvents patching)

    func testExternalEmptyFolderCreateAndRemoveArePatchedIntoTree() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)

        let folder = root.appendingPathComponent("Fresh/Nested", isDirectory: true)
        try makeFolder(folder)
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [root.appendingPathComponent("Fresh").path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertNotNil(node(store, "Fresh/Nested"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("Fresh"))
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [root.appendingPathComponent("Fresh").path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertNil(node(store, "Fresh"))
    }

    func testPatchedTreeMatchesFullScanAfterMixedExternalChanges() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        try write("# B\n", to: root.appendingPathComponent("Docs/B.md"))
        let store = try await openStore(root)

        try FileManager.default.moveItem(at: root.appendingPathComponent("Docs"), to: root.appendingPathComponent("Manual"))
        try write("# C\n", to: root.appendingPathComponent("Manual/Sub/C.md"))
        try write("ignored", to: root.appendingPathComponent("dist/x.md"))
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [
                root.appendingPathComponent("Docs").path,
                root.appendingPathComponent("Manual").path,
                root.appendingPathComponent("dist/x.md").path,
            ],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        _ = await wait { !store.isBusy && self.document(store, "Manual/Sub/C.md") != nil }

        let full = try WorkspaceDocumentScanner().scan(rootURL: root)
        XCTAssertEqual(Set(store.documents.map(\.id)), Set(full.documents.map(\.id)))
        XCTAssertEqual(store.rootNode, full.root)
    }

    /// An external change within the watcher's quiet window after an in-app change is applied
    /// when the window ends.
    func testExternalChangeRightAfterInternalOperationIsNotLost() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        store.createFolder(named: "Mine")
        await idle(store)

        let external = root.appendingPathComponent("FromTerminal.md")
        try write("# T\n", to: external)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [external.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        let seen = await wait(timeout: 3) { self.document(store, "FromTerminal.md") != nil }
        XCTAssertTrue(seen, "External file created during the watcher suppression window never appeared")
    }

    /// Monknot's own change, reported by the watcher during the quiet window, is already in the
    /// sidebar, so the replay after the window does not rebuild the tree for it.
    func testReplayAfterTheQuietWindowSkipsMonknotsOwnChanges() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("A.md"))
        let store = try await openStore(root)

        store.createFolder(named: "Mine")
        await idle(store)
        store.testing_stopFileWatcher()
        let revision = store.rootNodeRevision
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [root.appendingPathComponent("Mine").path, root.appendingPathComponent("A.md").path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        try await Task.sleep(nanoseconds: UInt64((store.suppressWatcherInterval + 0.6) * 1_000_000_000))

        XCTAssertEqual(store.rootNodeRevision, revision, "The replay rebuilt the tree for Monknot's own folder")
        XCTAssertNotNil(node(store, "Mine"))
    }

    func testExternalPatchDuringBusyOperationIsConsistentAfterwards() async throws {
        let root = try makeRoot()
        let store = try await openStore(root)

        store.createFolder(named: "Mine")
        XCTAssertTrue(store.isBusy)
        try write("# E\n", to: root.appendingPathComponent("External.md"))
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [root.appendingPathComponent("External.md").path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        await idle(store)
        _ = await wait { self.document(store, "External.md") != nil }
        XCTAssertNotNil(node(store, "Mine"))
        XCTAssertNotNil(document(store, "External.md"))
    }

    func testExternalRenameWhileLinkReviewIsPendingMakesConfirmStale() async throws {
        let root = try makeRoot()
        try write("[t](Target.md)\n", to: root.appendingPathComponent("Source.md"))
        try write("# T\n", to: root.appendingPathComponent("Target.md"))
        try makeFolder(root.appendingPathComponent("Sub"))
        let store = try await openStore(root)

        store.moveItem(id: root.appendingPathComponent("Target.md").path, toDirectory: root.appendingPathComponent("Sub"))
        _ = await wait { !store.isBusy && store.pendingMarkdownLinkMoveReview != nil }
        let review = try XCTUnwrap(store.pendingMarkdownLinkMoveReview)
        try write("[t](Target.md)\nmore\n", to: root.appendingPathComponent("Source.md"))

        store.confirmMarkdownLinkMoveReview(id: review.id)
        await idle(store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(exists(root.appendingPathComponent("Target.md")))
        XCTAssertFalse(exists(root.appendingPathComponent("Sub/Target.md")))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Source.md"), encoding: .utf8), "[t](Target.md)\nmore\n")
    }

    // MARK: - Sidebar selection

    /// One selection: a folder, or else the open document. Opening a document (even the one already
    /// open) moves it there; closing every document keeps a selected folder.
    func testSidebarSelectionIsAFolderOrTheOpenDocument() async throws {
        let root = try makeRoot()
        try write("# A\n", to: root.appendingPathComponent("Notes/A.md"))
        try write("# T\n", to: root.appendingPathComponent("Top.md"))
        let store = try await openStore(root)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let top = try await select(store, "Top.md")
        XCTAssertEqual(store.sidebarTargetFolderURL?.standardizedFileURL.path, root.path, "A root file's folder")
        XCTAssertEqual(store.sidebarSelectionURL?.path, top.url.path)

        store.selectFolder(id: notes.path)
        XCTAssertEqual(store.selectedFolderID, notes.path)
        XCTAssertEqual(store.selectedDocumentID, top.id, "Selecting a folder keeps the document open")
        XCTAssertEqual(store.sidebarSelectionURL?.path, notes.path)
        XCTAssertEqual(store.sidebarTargetFolderURL?.path, notes.path)

        store.selectFolder(id: root.path)
        store.selectFolder(id: top.id)
        store.selectFolder(id: root.appendingPathComponent("Missing").path)
        XCTAssertEqual(store.selectedFolderID, notes.path, "Only folders of the tree below the root are selected")

        XCTAssertTrue(store.selectDocument(id: top.id))
        XCTAssertNil(store.selectedFolderID, "Opening the open document moves the selection to it")

        store.selectFolder(id: notes.path)
        let a = try await select(store, "Notes/A.md")
        XCTAssertNil(store.selectedFolderID)
        XCTAssertEqual(store.sidebarTargetFolderURL?.path, notes.path, "A document's folder is the target")

        store.selectFolder(id: notes.path)
        XCTAssertTrue(store.selectDocument(id: nil))
        XCTAssertEqual(store.selectedFolderID, notes.path)
        XCTAssertNotEqual(store.selectedDocumentID, a.id)
    }

    func testNewItemsAndPastesGoIntoTheSelectedFolderAndAreSelected() async throws {
        let root = try makeRoot()
        try write("# T\n", to: root.appendingPathComponent("Top.md"))
        try makeFolder(root.appendingPathComponent("Box"))
        let store = try await openStore(root)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        let top = try await select(store, "Top.md")
        let pasteboard = makePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        store.selectFolder(id: box.path)
        store.createFolder(named: "Inner", in: store.sidebarTargetFolderURL)
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedFolderID, box.appendingPathComponent("Inner").path, "The new folder is selected")
        XCTAssertEqual(store.selectedDocumentID, top.id)

        store.selectFolder(id: box.path)
        store.putItemOnPasteboard(at: top.url, cutting: false, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: store.sidebarTargetFolderURL))
        await idle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(exists(box.appendingPathComponent("Top.md")))
        XCTAssertEqual(store.selectedDocumentID, box.appendingPathComponent("Top.md").path, "A pasted file opens")
        XCTAssertNil(store.selectedFolderID)

        store.selectFolder(id: box.appendingPathComponent("Inner").path)
        store.putItemOnPasteboard(at: box.appendingPathComponent("Inner"), cutting: true, pasteboard: pasteboard)
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: nil))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Inner").path, "A pasted folder is selected")

        store.duplicateItem(at: root.appendingPathComponent("Inner"))
        await idle(store)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Inner copy").path)

        store.selectFolder(id: box.path)
        store.createFile(named: "new.txt", in: store.sidebarTargetFolderURL)
        await idle(store)
        XCTAssertEqual(store.selectedDocumentID, box.appendingPathComponent("new.txt").path)
        XCTAssertNil(store.selectedFolderID, "The new file opens and takes the selection")
    }

    /// Pasting files from another app into a folder asks the sidebar to open that folder.
    func testImportedItemsRevealTheirFolder() async throws {
        let root = try makeRoot()
        try makeFolder(root.appendingPathComponent("Box"))
        let outside = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileOpsOutside")
        try write("o\n", to: outside.appendingPathComponent("o.txt"))
        let store = try await openStore(root)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        store.selectFolder(id: box.path)
        pasteboard.clearContents()
        pasteboard.writeObjects([outside.appendingPathComponent("o.txt") as NSURL])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: store.sidebarTargetFolderURL))
        await idle(store)
        XCTAssertEqual(names(in: box), ["o.txt"])
        XCTAssertEqual(store.revealedFolder?.folderID, box.path)
        XCTAssertEqual(store.selectedFolderID, box.path)
    }

    func testSelectedFolderFollowsRenameAndMove() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("Projects/Plans/N.md"))
        try makeFolder(root.appendingPathComponent("Archive"))
        let store = try await openStore(root)

        store.selectFolder(id: root.appendingPathComponent("Projects/Plans").path)
        store.renameFolder(id: root.appendingPathComponent("Projects/Plans").path, to: "Ideas")
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Projects/Ideas").path)

        store.renameFolder(id: root.appendingPathComponent("Projects").path, to: "Work")
        await settleMove(store)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Work/Ideas").path, "It follows its parent")

        store.moveItem(id: root.appendingPathComponent("Work/Ideas").path, toDirectory: root.appendingPathComponent("Archive"))
        await settleMove(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Archive/Ideas").path)

        store.moveItem(id: root.appendingPathComponent("Work").path, toDirectory: root.appendingPathComponent("Archive"))
        await settleMove(store)
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("Archive/Ideas").path, "Other moves leave it")
    }

    func testRemovedFolderSelectionMovesUpAndClearsOnWorkspaceSwitch() async throws {
        let root = try makeRoot()
        try write("# N\n", to: root.appendingPathComponent("A/B/C/N.md"))
        let store = try await openStore(root)

        store.selectFolder(id: root.appendingPathComponent("A/B/C").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("A/B/C"))
        store.refresh()
        _ = await wait { self.node(store, "A/B/C") == nil }
        XCTAssertEqual(store.selectedFolderID, root.appendingPathComponent("A/B").path, "The nearest remaining folder")

        try FileManager.default.removeItem(at: root.appendingPathComponent("A"))
        store.refresh()
        _ = await wait { self.node(store, "A") == nil }
        XCTAssertNil(store.selectedFolderID, "Nothing above it but the root")

        let other = try makeRoot()
        try makeFolder(other.appendingPathComponent("A"))
        try makeFolder(root.appendingPathComponent("A"))
        store.refresh()
        _ = await wait { self.node(store, "A") != nil }
        store.selectFolder(id: root.appendingPathComponent("A").path)
        XCTAssertNotNil(store.selectedFolderID)
        store.openWorkspace(other)
        _ = await wait { store.workspaceURL == other && !store.isBusy }
        XCTAssertNil(store.selectedFolderID)
    }
}
