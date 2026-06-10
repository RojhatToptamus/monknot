import XCTest
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreConflictTests: XCTestCase {
    func testStarterWorkspaceEligibilityWaitsForCompletedEmptyWorkspaceScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore()
        XCTAssertFalse(store.canBootstrapStarterWorkspace)

        store.openWorkspace(root)

        XCTAssertTrue(store.isWorkspaceOpening)
        XCTAssertFalse(store.canBootstrapStarterWorkspace)

        let didLoad = await waitUntil { !store.isBusy && store.rootNode != nil }
        XCTAssertTrue(didLoad)
        XCTAssertFalse(store.isWorkspaceOpening)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.canBootstrapStarterWorkspace)
    }

    func testStarterWorkspaceEligibilityIsFalseForLoadedWorkspaceWithDocuments() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Existing\n".write(to: root.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        XCTAssertFalse(store.isWorkspaceOpening)
        XCTAssertFalse(store.documents.isEmpty)
        XCTAssertFalse(store.canBootstrapStarterWorkspace)
    }

    func testWorkspaceLoadDoesNotScheduleSearchPrewarmInBackground() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        WorkspaceTextContentCache.shared.invalidateAll()
        WorkspaceSearchIndex.shared.invalidateAll()

        let fileURL = root.appendingPathComponent("Prewarm.md")
        try "# Prewarm\nsearchable-token\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        XCTAssertFalse(WorkspaceSearchIndex.shared.hasIndexedDocument(fileURL.standardizedFileURL.path))
    }

    func testReselectingCachedCleanTextDocumentDoesNotEnterLoadingState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "# A\ncached text\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# B\nother text\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)

        guard let first = store.documents.first(where: { $0.url == firstURL.standardizedFileURL }),
              let second = store.documents.first(where: { $0.url == secondURL.standardizedFileURL }) else {
            return XCTFail("Expected both documents")
        }

        store.selectDocument(id: first.id)
        let didLoadFirst = await waitUntil {
            !store.isDocumentLoading &&
                store.selectedDocumentID == first.id &&
                store.documentText == "# A\ncached text\n"
        }
        XCTAssertTrue(didLoadFirst)

        store.selectDocument(id: second.id)
        let didLoadSecond = await waitUntil {
            !store.isDocumentLoading &&
                store.selectedDocumentID == second.id &&
                store.documentText == "# B\nother text\n"
        }
        XCTAssertTrue(didLoadSecond)

        store.selectDocument(id: first.id)

        XCTAssertEqual(store.selectedDocumentID, first.id)
        XCTAssertFalse(store.isDocumentLoading)
        XCTAssertEqual(store.documentText, "# A\ncached text\n")
    }

    func testOversizedCachedTextDocumentDoesNotOpenInEditor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Huge.md")
        let largeText = String(
            repeating: "x",
            count: Int(WorkspaceStore.interactiveTextOpenMaxBytes) + 1
        )
        try largeText.write(to: fileURL, atomically: true, encoding: .utf8)
        WorkspaceTextContentCache.shared.store(text: largeText, for: fileURL)
        defer { WorkspaceTextContentCache.shared.invalidate(paths: [fileURL.path]) }

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil {
            !store.isBusy &&
                store.selectedDocumentID == fileURL.standardizedFileURL.path &&
                !store.isDocumentLoading
        }
        XCTAssertTrue(didLoad)
        XCTAssertEqual(store.documentText, "")
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("too large") == true)
    }

    func testDirtyDocumentReportsExternalDiskChange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected draft document")
        }

        store.selectDocument(id: document.id)
        let didOpen = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == document.id }
        XCTAssertTrue(didOpen)

        store.setDocumentText("# Draft\nlocal edits\n")
        XCTAssertTrue(store.hasUnsavedChanges)

        try "# Draft\nexternal version\n".write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()

        let didDetectConflict = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }
        XCTAssertTrue(didDetectConflict)
        XCTAssertFalse(store.isSelectedDocumentRemovedExternally)
    }

    func testAcknowledgeExternalChangeKeepsDirtyBuffer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Keep.md")
        try "# Keep\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected keep document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setDocumentText("# Keep\nlocal\n")

        try "# Keep\nexternal\n".write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        _ = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }

        store.acknowledgeExternalChange()
        XCTAssertFalse(store.selectedDocumentExternalChange)
        XCTAssertEqual(store.documentText, "# Keep\nlocal\n")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testReloadSelectedDocumentFromDiskDiscardsLocalEdits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Reload.md")
        try "# Reload\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected reload document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setDocumentText("# Reload\nlocal\n")

        try "# Reload\nexternal\n".write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        _ = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }

        store.reloadSelectedDocumentFromDisk()
        _ = await waitUntil { !store.isDocumentLoading }

        XCTAssertFalse(store.selectedDocumentExternalChange)
        XCTAssertEqual(store.documentText, "# Reload\nexternal\n")
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testDirtyOpenDocumentRemovedExternallyReportsConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Removed.md")
        try "# Removed\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected removed document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setOpenDocumentIDs([document.id])
        store.setDocumentText("# Removed\nlocal edits\n")

        try FileManager.default.removeItem(at: fileURL)
        store.refresh()

        let didDetectRemoval = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange && store.isSelectedDocumentRemovedExternally
        }
        XCTAssertTrue(didDetectRemoval)
        XCTAssertEqual(store.selectedDocumentID, document.id)
        XCTAssertEqual(store.documentText, "# Removed\nlocal edits\n")
        XCTAssertFalse(store.documents.contains { $0.id == document.id })
        XCTAssertNotNil(store.document(id: document.id))
    }

    func testModificationOnlyExternalEventReloadsCleanDocument() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Incremental.md")
        try "# Incremental\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
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

        let store = WorkspaceStore()
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

        let store = WorkspaceStore()
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

        let store = WorkspaceStore()
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

        let store = WorkspaceStore()
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

    func testDeleteDirtyOpenDocumentIsBlocked() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Protected.md")
        try "# Protected\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected protected document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setOpenDocumentIDs([document.id])
        store.setDocumentText("# Protected\nedited\n")

        store.deleteDocument(document)

        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("Save or close") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-store-conflict-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
