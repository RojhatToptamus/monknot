import Foundation
@testable import MonknotCore
import XCTest

final class WorkspaceScanResultPatcherTests: XCTestCase {
    func testAddsNewFileAndCreatesAncestorFolder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Existing", to: root.appendingPathComponent("Existing.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let newFile = notes.appendingPathComponent("New.md")
        try write("# New", to: newFile)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [newFile.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath).sorted(), ["Existing.md", "Notes/New.md"])
        let notesNode = try XCTUnwrap(patched.root.children?.first { $0.name == "Notes" })
        XCTAssertEqual(notesNode.kind, .folder)
        XCTAssertEqual(notesNode.children?.map(\.name), ["New.md"])
    }

    func testSkipsUnsupportedNewFileChange() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Existing", to: root.appendingPathComponent("Existing.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        let image = root.appendingPathComponent("image.png")
        try write("not a workspace document", to: image)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [image.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath), ["Existing.md"])
        XCTAssertEqual(patched.root.children?.map(\.name), ["Existing.md"])
    }

    func testDirectoryRefreshSkipsUnsupportedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("# Nested", to: folder.appendingPathComponent("Nested.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        try write("# Added", to: folder.appendingPathComponent("Added.md"))
        try write("not a workspace document", to: folder.appendingPathComponent("image.png"))

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [folder.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath).sorted(), ["Folder/Added.md", "Folder/Nested.md"])
        let folderNode = try XCTUnwrap(patched.root.children?.first { $0.name == "Folder" })
        XCTAssertEqual(folderNode.children?.map(\.name), ["Added.md", "Nested.md"])
    }

    func testRemovesDeletedFileWithoutFullScan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = root.appendingPathComponent("Keep.md")
        let delete = root.appendingPathComponent("Delete.md")
        try write("# Keep", to: keep)
        try write("# Delete", to: delete)
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        try FileManager.default.removeItem(at: delete)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [delete.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath), ["Keep.md"])
        XCTAssertEqual(patched.root.children?.map(\.name), ["Keep.md"])
    }

    func testExistingDirectoryChangeRefreshesSubtreeWithoutFullScan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("# Nested", to: folder.appendingPathComponent("Nested.md"))
        try write("# Remove", to: folder.appendingPathComponent("Remove.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("Remove.md"))
        try write("# Added", to: folder.appendingPathComponent("Added.md"))

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [folder.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath).sorted(), ["Folder/Added.md", "Folder/Nested.md"])
        let folderNode = try XCTUnwrap(patched.root.children?.first { $0.name == "Folder" })
        XCTAssertEqual(folderNode.children?.map(\.name), ["Added.md", "Nested.md"])
    }

    func testDeletedDirectoryRemovesSubtreeWithoutFullScan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("# Nested", to: folder.appendingPathComponent("Nested.md"))
        try write("# Keep", to: root.appendingPathComponent("Keep.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        try FileManager.default.removeItem(at: folder)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [folder.standardizedFileURL.path]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath), ["Keep.md"])
        XCTAssertEqual(patched.root.children?.map(\.name), ["Keep.md"])
    }

    func testDirectoryRenamePairPatchesRemovedAndCreatedSubtrees() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFolder = root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try write("# Nested", to: oldFolder.appendingPathComponent("Nested.md"))
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        let newFolder = root.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [
                oldFolder.standardizedFileURL.path,
                newFolder.standardizedFileURL.path
            ]
        ))

        XCTAssertEqual(patched.documents.map(\.relativePath), ["New/Nested.md"])
        XCTAssertEqual(patched.root.children?.map(\.name), ["New"])
    }

    func testIgnoredDirectoryEventRemovesExistingSubtree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let visible = root.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try write("# Nested", to: visible.appendingPathComponent("Nested.md"))
        let initial = try WorkspaceDocumentScanner(ignoredDirectoryNames: []).scan(rootURL: root)

        let ignored = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.moveItem(at: visible, to: ignored)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [
                visible.standardizedFileURL.path,
                ignored.standardizedFileURL.path
            ]
        ))

        XCTAssertTrue(patched.documents.isEmpty)
        XCTAssertTrue(patched.root.children?.isEmpty == true)
    }

    func testSymlinkFileChangeRemovesExistingDocument() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let linkedPath = root.appendingPathComponent("Linked.md")
        try write("# Original", to: linkedPath)
        let initial = try WorkspaceDocumentScanner().scan(rootURL: root)

        try FileManager.default.removeItem(at: linkedPath)
        let outsideFile = outside.appendingPathComponent("Outside.md")
        try write("# Outside", to: outsideFile)
        try FileManager.default.createSymbolicLink(at: linkedPath, withDestinationURL: outsideFile)

        let patched = try XCTUnwrap(WorkspaceScanResultPatcher.applyingFileChanges(
            to: initial,
            rootURL: root,
            changedPaths: [linkedPath.standardizedFileURL.path]
        ))

        XCTAssertTrue(patched.documents.isEmpty)
        XCTAssertTrue(patched.root.children?.isEmpty == true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
