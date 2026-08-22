import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreExternalChangeTests: WorkspaceStoreConflictTestCase {
    func testVisualExternalChangeReviewPreferenceDefaultsOn() {
        XCTAssertEqual(
            VisualExternalChangeReviewPreference.key,
            "Monknot.visualExternalChangeReview"
        )
        XCTAssertTrue(VisualExternalChangeReviewPreference.defaultValue)
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

        let store = makeWorkspaceStore()
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

    func testDirtyDocumentReportsExternalDiskChange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

    func testDirtyOpenDocumentRemovedExternallyReportsConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Removed.md")
        try "# Removed\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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

    func testDeleteDirtyOpenDocumentIsBlocked() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Protected.md")
        try "# Protected\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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
}
