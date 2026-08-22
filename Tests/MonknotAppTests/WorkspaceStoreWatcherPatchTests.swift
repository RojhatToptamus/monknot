import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreWatcherPatchTests: WorkspaceStoreConflictTestCase {
    func testModificationOnlyExternalEventReloadsCleanDocument() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Incremental.md")
        try "# Incremental\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected incremental document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == document.id }
        let searchSerialBeforeChange = store.workspaceSearchContentChangeSerial

        try "# Incremental\nexternal version\n".write(to: fileURL, atomically: false, encoding: .utf8)
        let path = fileURL.standardizedFileURL.path
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [path],
            modifiedOnlyPaths: [path],
            requiresFullRescan: false
        ))

        let didReload = await waitUntil { store.documentText == "# Incremental\nexternal version\n" }
        XCTAssertTrue(didReload)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertFalse(store.isBusy)
        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, searchSerialBeforeChange)
    }

    func testExternalFileCreateEventPatchesWorkspaceWithoutFullRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Existing.md")
        try "# Existing\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        let searchSerialBeforeChange = store.workspaceSearchContentChangeSerial
        let newURL = root.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent("New.md")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# New\n".write(to: newURL, atomically: true, encoding: .utf8)

        let path = newURL.standardizedFileURL.path
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))

        XCTAssertTrue(store.documents.contains { $0.relativePath == "Inbox/New.md" })
        XCTAssertFalse(store.isBusy)
        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, searchSerialBeforeChange)
    }

    func testExternalFileDeleteEventPatchesWorkspaceWithoutFullRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let keepURL = root.appendingPathComponent("Keep.md")
        let deleteURL = root.appendingPathComponent("Delete.md")
        try "# Keep\n".write(to: keepURL, atomically: true, encoding: .utf8)
        try "# Delete\n".write(to: deleteURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.documents.count == 2 }

        let searchSerialBeforeChange = store.workspaceSearchContentChangeSerial
        let path = deleteURL.standardizedFileURL.path
        try FileManager.default.removeItem(at: deleteURL)

        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))

        XCTAssertEqual(store.documents.map(\.relativePath), ["Keep.md"])
        XCTAssertFalse(store.isBusy)
        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, searchSerialBeforeChange)
    }

    func testExternalDirectoryChangePatchesSubtreeWithoutFullRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folderURL = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "# Existing\n".write(to: folderURL.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)
        try "# Remove\n".write(to: folderURL.appendingPathComponent("Remove.md"), atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.documents.count == 2 }

        let searchSerialBeforeChange = store.workspaceSearchContentChangeSerial
        try FileManager.default.removeItem(at: folderURL.appendingPathComponent("Remove.md"))
        try "# Added\n".write(to: folderURL.appendingPathComponent("Added.md"), atomically: true, encoding: .utf8)

        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [folderURL.standardizedFileURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))

        XCTAssertEqual(store.documents.map(\.relativePath).sorted(), ["Folder/Added.md", "Folder/Existing.md"])
        XCTAssertFalse(store.isBusy)
        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, searchSerialBeforeChange)
    }

    func testExternalDirectoryDeletePatchesSubtreeWithoutFullRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folderURL = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "# Nested\n".write(to: folderURL.appendingPathComponent("Nested.md"), atomically: true, encoding: .utf8)
        try "# Keep\n".write(to: root.appendingPathComponent("Keep.md"), atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.documents.count == 2 }

        let searchSerialBeforeChange = store.workspaceSearchContentChangeSerial
        try FileManager.default.removeItem(at: folderURL)

        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [folderURL.standardizedFileURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))

        XCTAssertEqual(store.documents.map(\.relativePath), ["Keep.md"])
        XCTAssertFalse(store.isBusy)
        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, searchSerialBeforeChange)
    }
}
