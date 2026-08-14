import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreConflictTests: XCTestCase {
    func testVisualExternalChangeReviewPreferenceDefaultsOn() {
        XCTAssertEqual(
            VisualExternalChangeReviewPreference.key,
            "Monknot.visualExternalChangeReview"
        )
        XCTAssertTrue(VisualExternalChangeReviewPreference.defaultValue)
    }

    func testExternalReviewDoesNotReportConflictForProvenOneSidedChange() {
        let baseline = "head\nbody\n"
        let review = ExternalDocumentReconciliationService.review(
            baselineText: baseline,
            localText: "local head\nbody\n",
            diskRevision: WorkspaceTextRevision(
                text: baseline,
                signature: WorkspaceFileSignature(modificationDate: nil, fileSize: nil)
            )
        )
        let state = ExternalDocumentReviewState(
            documentID: "/workspace/Note.md",
            displayName: "Note.md",
            review: review,
            diskToMineDiff: nil
        )

        XCTAssertEqual(review.mergedText, review.localText)
        XCTAssertFalse(state.canMerge)
        XCTAssertFalse(state.hasMergeConflict)
    }

    func testExternalReviewReportsConflictOnlyForOverlappingChanges() {
        let review = ExternalDocumentReconciliationService.review(
            baselineText: "value\n",
            localText: "mine\n",
            diskRevision: WorkspaceTextRevision(
                text: "theirs\n",
                signature: WorkspaceFileSignature(modificationDate: nil, fileSize: nil)
            )
        )
        let state = ExternalDocumentReviewState(
            documentID: "/workspace/Note.md",
            displayName: "Note.md",
            review: review,
            diskToMineDiff: nil
        )

        XCTAssertNil(review.mergedText)
        XCTAssertFalse(state.canMerge)
        XCTAssertTrue(state.hasMergeConflict)
    }

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

    func testWorkspaceSearchSnapshotsIncludeActiveAndInactiveDirtyBuffersUntilSave() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "# A\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# B\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
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

    func testSaveDocumentsInOrderStopsAtFirstConflictAndKeepsRemainingDocumentsDirty() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        let thirdURL = root.appendingPathComponent("C.md")
        try "A disk\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "B disk\n".write(to: secondURL, atomically: true, encoding: .utf8)
        try "C disk\n".write(to: thirdURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoadWorkspace = await waitUntil { !store.isBusy && store.documents.count == 3 }
        XCTAssertTrue(didLoadWorkspace)
        let first = try XCTUnwrap(store.documents.first { $0.url == firstURL.standardizedFileURL })
        let second = try XCTUnwrap(store.documents.first { $0.url == secondURL.standardizedFileURL })
        let third = try XCTUnwrap(store.documents.first { $0.url == thirdURL.standardizedFileURL })
        store.setOpenDocumentIDs([first.id, second.id, third.id])

        for (document, text) in [
            (first, "A local\n"),
            (second, "B local\n"),
            (third, "C local\n")
        ] {
            store.selectDocument(id: document.id)
            let didLoad = await waitUntil {
                !store.isDocumentLoading && store.selectedDocumentID == document.id
            }
            XCTAssertTrue(didLoad)
            store.setDocumentText(text)
        }

        try "B external\n".write(to: secondURL, atomically: true, encoding: .utf8)
        let failedDocumentID = await store.saveDocumentsInOrder([first.id, second.id, third.id])

        XCTAssertEqual(failedDocumentID, second.id)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "A local\n")
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "B external\n")
        XCTAssertEqual(try String(contentsOf: thirdURL, encoding: .utf8), "C disk\n")
        XCTAssertTrue(store.saveState(for: first.id).isClean)
        XCTAssertFalse(store.saveState(for: second.id).isClean)
        XCTAssertFalse(store.saveState(for: third.id).isClean)
        XCTAssertTrue(store.errorMessage?.contains("B.md") == true)
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

    func testRevertingLocalEditsAfterExternalChangeAdoptsDiskAndClearsConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Revert.md")
        let baseline = "# Revert\n"
        let diskText = "# Revert\nexternal version\n"
        try baseline.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && store.selectedDocument != nil }

        guard let document = store.documents.first(where: { $0.url == fileURL.standardizedFileURL }) else {
            return XCTFail("Expected revert document")
        }

        store.selectDocument(id: document.id)
        _ = await waitUntil { !store.isDocumentLoading }
        store.setDocumentText("# Revert\nlocal version\n")

        try diskText.write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didDetectConflict)

        store.setDocumentText(baseline)

        let didAdoptDisk = await waitUntil {
            !store.isDocumentLoading
                && store.documentText == diskText
                && !store.hasUnsavedChanges
                && !store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didAdoptDisk)
        XCTAssertNil(store.externalDocumentReview)
        XCTAssertTrue(store.saveState(for: document.id).isClean)
    }

    func testKeepLocalExternalReviewKeepsDirtyBuffer() async throws {
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

        store.prepareExternalDocumentReview()
        let didPrepareReview = await waitUntil { store.externalDocumentReview != nil }
        XCTAssertTrue(didPrepareReview)
        store.resolveExternalDocumentReview(.keepLocal)
        let didResolveReview = await waitUntil {
            store.externalDocumentReview == nil && !store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didResolveReview)
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

    func testExternalReviewShowsExactVersionsAndAppliesSafeMergeWithoutWriting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Merge.md")
        let baseline = "head\nbody\ntail\n"
        let local = "local head\nbody\ntail\n"
        let disk = "head\nbody\ndisk tail\n"
        try baseline.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        store.setDocumentText(local)
        try disk.write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        _ = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }

        store.prepareExternalDocumentReview()
        let didReview = await waitUntil { store.externalDocumentReview != nil }
        XCTAssertTrue(didReview)
        XCTAssertEqual(store.externalDocumentReview?.review.baselineText, baseline)
        XCTAssertEqual(store.externalDocumentReview?.review.localText, local)
        XCTAssertEqual(store.externalDocumentReview?.review.diskText, disk)
        XCTAssertEqual(store.externalDocumentReview?.review.mergedText, "local head\nbody\ndisk tail\n")
        let diffLines = try XCTUnwrap(store.externalDocumentReview?.diskToMineDiff).hunks.flatMap(\.lines)
        XCTAssertTrue(diffLines.contains { $0.kind == .removal && $0.text == "disk tail" })
        XCTAssertTrue(diffLines.contains { $0.kind == .addition && $0.text == "local head" })

        store.resolveExternalDocumentReview(.merge)
        _ = await waitUntil { store.externalDocumentReview == nil }

        XCTAssertEqual(store.documentText, "local head\nbody\ndisk tail\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), disk)
    }

    func testExternalReviewRevalidatesDiskBeforeResolution() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Stale.md")
        try "baseline\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        store.setDocumentText("local\n")
        try "disk one\n".write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        _ = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }
        store.prepareExternalDocumentReview()
        _ = await waitUntil { store.externalDocumentReview?.review.diskText == "disk one\n" }

        try "disk two\n".write(to: fileURL, atomically: true, encoding: .utf8)
        store.resolveExternalDocumentReview(.keepLocal)
        let didRefresh = await waitUntil {
            store.externalDocumentReview?.review.diskText == "disk two\n"
        }

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(store.documentText, "local\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "disk two\n")
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("refreshed") == true)
    }

    func testSaveRejectsUnreviewedExternalChange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Protected Save.md")
        try "baseline\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        store.setDocumentText("local\n")
        try "external\n".write(to: fileURL, atomically: true, encoding: .utf8)

        store.saveSelectedFile()
        _ = await waitUntil { !store.isSaving }

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "external\n")
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testExternalReviewSaveCopyWritesLocalTextRefreshesWorkspaceAndKeepsConflictOpen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        store.prepareExternalDocumentReview()
        let didPrepareReview = await waitUntil { store.externalDocumentReview != nil }
        XCTAssertTrue(didPrepareReview)

        let destinationURL = root.appendingPathComponent("Note Local Copy.md")
        store.saveExternalDocumentCopy(to: destinationURL)

        let didRefreshWorkspace = await waitUntil(timeout: 8) {
            store.documents.contains { $0.url == destinationURL.standardizedFileURL }
        }
        XCTAssertTrue(didRefreshWorkspace)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "local\n")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk\n")
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertNotNil(store.externalDocumentReview)
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testExternalReviewSaveCopyRefreshesStaleDiskBeforeWritingDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        store.prepareExternalDocumentReview()
        let didPrepareReview = await waitUntil {
            store.externalDocumentReview?.review.diskText == "disk\n"
        }
        XCTAssertTrue(didPrepareReview)

        try "newer disk\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let destinationURL = root.appendingPathComponent("Should Not Exist.md")
        store.saveExternalDocumentCopy(to: destinationURL)

        let didRefreshReview = await waitUntil {
            store.externalDocumentReview?.review.diskText == "newer disk\n"
        }
        XCTAssertTrue(didRefreshReview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(store.documentText, "local\n")
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("refreshed") == true)
    }

    func testExternalReviewSaveCopyRejectsCanonicalSourcePath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        let canonicalAlias = root
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent)

        store.saveExternalDocumentCopy(to: canonicalAlias)

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk\n")
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("different location") == true)
    }

    func testExternalReviewSaveCopyRejectsSymlinkAliasToSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        let aliasURL = root.appendingPathComponent("Source Alias.md")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: sourceURL)

        store.saveExternalDocumentCopy(to: aliasURL)

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: aliasURL.path), sourceURL.path)
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("different location") == true)
    }

    func testExternalReviewSaveCopyRejectsHardLinkAliasToSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        let aliasURL = root.appendingPathComponent("Source Hard Link.md")
        try FileManager.default.linkItem(at: sourceURL, to: aliasURL)

        store.saveExternalDocumentCopy(to: aliasURL)

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk\n")
        XCTAssertEqual(try String(contentsOf: aliasURL, encoding: .utf8), "disk\n")
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("different location") == true)
    }

    func testMinimalExternalReviewKeepMineRebasesExpectationWithoutOpeningReview() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)

        store.resolveSelectedExternalDocumentWithoutReview(.keepLocal)
        let didResolve = await waitUntil {
            !store.selectedDocumentExternalChange && store.hasUnsavedChanges
        }

        XCTAssertTrue(didResolve)
        XCTAssertNil(store.externalDocumentReview)
        XCTAssertEqual(store.documentText, "local\n")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk\n")

        store.saveSelectedFile()
        let didSave = await waitForSave(store)
        XCTAssertTrue(didSave)
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "local\n")
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testMinimalExternalReviewUseDiskReadsLatestVersionWithoutOpeningReview() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, sourceURL) = try await makeConflictedStore(in: root)
        try "newest disk\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        store.resolveSelectedExternalDocumentWithoutReview(.useDisk)
        let didResolve = await waitUntil {
            !store.selectedDocumentExternalChange &&
                !store.hasUnsavedChanges &&
                !store.isDocumentLoading &&
                store.documentText == "newest disk\n"
        }

        XCTAssertTrue(didResolve)
        XCTAssertNil(store.externalDocumentReview)
        XCTAssertEqual(store.documentText, "newest disk\n")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "newest disk\n")
    }

    func testExternalRefreshStartedBeforeUseDiskDoesNotReloadResolvedText() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("Note.md")
        try "baseline\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let scanner = BlockingWorkspaceScanner(blockingCall: 3)
        defer { scanner.resume() }
        let store = WorkspaceStore(scanner: scanner)
        store.openWorkspace(root)
        let didOpen = await waitUntil {
            !store.isBusy && !store.isDocumentLoading && store.documentText == "baseline\n"
        }
        XCTAssertTrue(didOpen)
        store.testing_stopFileWatcher()

        store.setDocumentText("local\n")
        try "disk\n".write(to: sourceURL, atomically: false, encoding: .utf8)
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didDetectConflict)

        store.refresh()
        let didStartRefresh = await waitUntil { scanner.isBlocking }
        XCTAssertTrue(didStartRefresh)
        try "newest disk\n".write(to: sourceURL, atomically: false, encoding: .utf8)

        var observedTexts: [String] = []
        let observation = store.$documentText.sink { observedTexts.append($0) }
        defer { observation.cancel() }
        store.resolveSelectedExternalDocumentWithoutReview(.useDisk)
        let didResolve = await waitUntil {
            !store.selectedDocumentExternalChange &&
                !store.hasUnsavedChanges &&
                !store.isDocumentLoading &&
                store.documentText == "newest disk\n"
        }
        XCTAssertTrue(didResolve)

        observedTexts.removeAll()
        scanner.resume()
        let didFinishScan = await waitUntil { scanner.didCompleteBlockedCall }
        XCTAssertTrue(didFinishScan)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(store.isDocumentLoading)
        XCTAssertFalse(observedTexts.contains(""))
        XCTAssertEqual(store.documentText, "newest disk\n")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "newest disk\n")
    }

    func testCancellingExternalReviewLeavesLocalAndDiskVersionsUnchanged() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Cancel Review.md")
        try "baseline\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        _ = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        store.setDocumentText("local\n")
        try "disk\n".write(to: fileURL, atomically: true, encoding: .utf8)
        store.prepareExternalDocumentReview()
        let didPrepareReview = await waitUntil { store.externalDocumentReview != nil }
        XCTAssertTrue(didPrepareReview)

        store.cancelExternalDocumentReview()

        XCTAssertNil(store.externalDocumentReview)
        XCTAssertEqual(store.documentText, "local\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "disk\n")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testExternalReviewClearsAcrossDocumentAndWorkspaceChanges() async throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let alphaURL = firstRoot.appendingPathComponent("Alpha.md")
        let betaURL = firstRoot.appendingPathComponent("Beta.md")
        let otherURL = secondRoot.appendingPathComponent("Other.md")
        try "alpha baseline\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta baseline\n".write(to: betaURL, atomically: true, encoding: .utf8)
        try "other\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(firstRoot)
        _ = await waitUntil { !store.isBusy && !store.isDocumentLoading }

        guard let alpha = store.documents.first(where: { $0.url == alphaURL.standardizedFileURL }),
              let beta = store.documents.first(where: { $0.url == betaURL.standardizedFileURL })
        else {
            return XCTFail("Expected both documents in the first workspace")
        }

        XCTAssertTrue(store.selectDocument(id: alpha.id))
        _ = await waitUntil { !store.isDocumentLoading }
        store.setDocumentText("alpha local\n")
        try "alpha disk\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        store.prepareExternalDocumentReview()
        let didPrepareAlphaReview = await waitUntil {
            store.externalDocumentReview?.documentID == alpha.id
        }
        XCTAssertTrue(didPrepareAlphaReview)

        XCTAssertTrue(store.selectDocument(id: beta.id))
        XCTAssertNil(store.externalDocumentReview)
        _ = await waitUntil { !store.isDocumentLoading }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.externalDocumentReview)

        store.setDocumentText("beta local\n")
        try "beta disk\n".write(to: betaURL, atomically: true, encoding: .utf8)
        store.prepareExternalDocumentReview()
        let didPrepareBetaReview = await waitUntil {
            store.externalDocumentReview?.documentID == beta.id
        }
        XCTAssertTrue(didPrepareBetaReview)

        store.openWorkspace(secondRoot)
        XCTAssertNil(store.externalDocumentReview)
        let didOpenSecondWorkspace = await waitUntil {
            !store.isBusy && !store.isDocumentLoading
        }
        XCTAssertTrue(didOpenSecondWorkspace)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.externalDocumentReview)
        XCTAssertEqual(store.selectedDocument?.url, otherURL.standardizedFileURL)
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

    private func makeConflictedStore(
        in root: URL
    ) async throws -> (store: WorkspaceStore, sourceURL: URL) {
        let sourceURL = root.appendingPathComponent("Note.md")
        try "baseline\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didOpen = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        guard didOpen else {
            throw CocoaError(.fileReadUnknown)
        }
        store.setDocumentText("local\n")
        try "disk\n".write(to: sourceURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        guard didDetectConflict else {
            throw CocoaError(.fileReadUnknown)
        }
        return (store, sourceURL)
    }

    private func waitForSave(_ store: WorkspaceStore) async -> Bool {
        let didStart = await waitUntil { store.isSaving }
        guard didStart else { return false }
        return await waitUntil { !store.isSaving }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-store-conflict-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class BlockingWorkspaceScanner: WorkspaceDocumentScanning, @unchecked Sendable {
    private let condition = NSCondition()
    private let blockingCall: Int
    private var callCount = 0
    private var isReleased = false
    private var blocking = false
    private var completedBlockedCall = false

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    var isBlocking: Bool {
        condition.withLock { blocking }
    }

    var didCompleteBlockedCall: Bool {
        condition.withLock { completedBlockedCall }
    }

    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        condition.lock()
        callCount += 1
        let shouldBlock = callCount == blockingCall
        if shouldBlock {
            blocking = true
            while !isReleased {
                condition.wait()
            }
        }
        condition.unlock()

        let result = try WorkspaceDocumentScanner().scan(rootURL: rootURL)
        if shouldBlock {
            condition.withLock {
                completedBlockedCall = true
            }
        }
        return result
    }

    func resume() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
