import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreLoadingTests: WorkspaceStoreConflictTestCase {
    func testStarterWorkspaceEligibilityWaitsForCompletedEmptyWorkspaceScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        XCTAssertFalse(WorkspaceSearchIndex.shared.hasIndexedDocument(fileURL.standardizedFileURL.path))
    }

    func testWorkspaceSearchSnapshotsIncludeActiveAndInactiveDirtyBuffersUntilSave() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "# A\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# B\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoadWorkspace = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoadWorkspace)
        let first = try XCTUnwrap(store.documents.first { $0.url == firstURL.standardizedFileURL })
        let second = try XCTUnwrap(store.documents.first { $0.url == secondURL.standardizedFileURL })
        store.setOpenDocumentIDs([first.id, second.id])

        store.selectDocument(id: first.id)
        let didLoadFirst = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        XCTAssertTrue(didLoadFirst)
        store.setDocumentText("# A\nactive unsaved\n")

        store.selectDocument(id: second.id)
        let didLoadSecond = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == second.id }
        XCTAssertTrue(didLoadSecond)
        store.setDocumentText("# B\ninactive later\n")

        XCTAssertEqual(store.dirtyTextByDocumentID[first.id], "# A\nactive unsaved\n")
        XCTAssertEqual(store.dirtyTextByDocumentID[second.id], "# B\ninactive later\n")

        let didSaveFirst = await store.saveDocument(id: first.id)
        XCTAssertTrue(didSaveFirst)
        XCTAssertNil(store.dirtyTextByDocumentID[first.id])
        XCTAssertEqual(store.dirtyTextByDocumentID[second.id], "# B\ninactive later\n")
    }

    func testReselectingCachedCleanTextDocumentDoesNotEnterLoadingState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "# A\ncached text\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# B\nother text\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

    func testReloadSelectedDocumentFromDiskDiscardsLocalEdits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Reload.md")
        try "# Reload\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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
}
