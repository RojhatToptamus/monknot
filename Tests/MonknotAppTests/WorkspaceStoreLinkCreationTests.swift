import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStoreLinkCreationTests: WorkspaceStoreLinkTestCase {
    func testMissingWikilinkCreationCreatesAndSelectsCleanMarkdownDocument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreMissingLinkTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let source = notes.appendingPathComponent("Source.md")
        let destination = notes.appendingPathComponent("New Linked Note.md").standardizedFileURL
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "[[New Linked Note]]\n".write(to: source, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 1 }

        store.createMarkdownFile(at: destination)
        await assertEventually {
            !store.isBusy && store.selectedDocumentID == destination.path
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# New Linked Note\n\n")
        XCTAssertEqual(store.documentText, "# New Linked Note\n\n")
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.errorMessage)
    }

    func testMissingWikilinkCreationDoesNotOverwriteExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreExistingLinkTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.md")
        let destination = root.appendingPathComponent("Existing.md").standardizedFileURL
        try "[[Existing]]\n".write(to: source, atomically: true, encoding: .utf8)
        try "external content\n".write(to: destination, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }
        store.createMarkdownFile(at: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external content\n")
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("already exists") == true)
        XCTAssertFalse(store.isBusy)
    }

    func testMissingWikilinkCreationRefusesSymlinkedParentAndDanglingTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreSymlinkLinkTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreSymlinkOutside-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.md")
        try "# Source\n".write(to: source, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 1 }
        let escapedDestination = alias.appendingPathComponent("Escaped.md").standardizedFileURL
        store.createMarkdownFile(at: escapedDestination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Escaped.md").path))
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("symbolic link") == true)

        store.errorMessage = nil
        let danglingDestination = root.appendingPathComponent("Dangling.md").standardizedFileURL
        try FileManager.default.createSymbolicLink(
            at: danglingDestination,
            withDestinationURL: outside.appendingPathComponent("Created.md")
        )
        store.createMarkdownFile(at: danglingDestination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Created.md").path))
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("already exists") == true)
        XCTAssertFalse(store.isBusy)
    }
}
