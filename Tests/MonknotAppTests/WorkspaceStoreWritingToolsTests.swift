import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreWritingToolsTests: WorkspaceStoreConflictTestCase {
    func testWritingToolsCommitsOnceBeforeSaveCanPersistFinalText() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()

        store.setWritingToolsActive(true, documentID: documentID)
        XCTAssertTrue(store.testing_isWritingToolsActive)
        XCTAssertEqual(store.documentText, "Original\n")
        store.saveSelectedFile()
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "Original\n")

        store.commitWritingToolsText("Rewritten once\n", documentID: documentID)
        XCTAssertEqual(store.documentText, "Rewritten once\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        store.saveSelectedFile()
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "Original\n")

        store.setWritingToolsActive(false, documentID: documentID)
        XCTAssertFalse(store.testing_isWritingToolsActive)
        store.saveSelectedFile()
        let didSave = await waitUntil { !store.isSaving && store.saveState(for: documentID).isClean }
        let saveError = store.errorMessage ?? "none"
        XCTAssertTrue(
            didSave,
            "state=\(store.saveState(for: documentID)) error=\(saveError)"
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "Rewritten once\n")
    }

    func testWritingToolsDefersExternalModificationAndPreservesLocalFinalText() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()
        store.testing_clearWatcherSuppression()
        store.setWritingToolsActive(true, documentID: documentID)

        try "External\n".write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [fileURL.path],
            modifiedOnlyPaths: [fileURL.path],
            requiresFullRescan: false
        ))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)
        XCTAssertEqual(store.documentText, "Original\n")

        store.commitWritingToolsText("Local rewrite\n", documentID: documentID)
        store.setWritingToolsActive(false, documentID: documentID)
        let didDetectConflictAndRefresh = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
                && !store.testing_hasDeferredWritingToolsRefresh
        }

        XCTAssertFalse(store.testing_hasDeferredWritingToolsRefresh)
        XCTAssertEqual(store.documentText, "Local rewrite\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(didDetectConflictAndRefresh)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "External\n")
    }

    func testWritingToolsReturningToSavedBaselinePreservesExternalConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        let baseline = "Original\n"
        let diskText = "X\n"
        try baseline.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.setDocumentText("Local draft\n")
        try diskText.write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didDetectConflict)

        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))
        store.commitWritingToolsText(baseline, documentID: documentID)
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))

        let didPreserveLocalConflict = await waitUntil(timeout: 8) {
            !store.isDocumentLoading
                && store.documentText == baseline
                && store.hasUnsavedChanges
                && store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didPreserveLocalConflict)
        XCTAssertFalse(store.errorMessage?.contains("Finish Writing Tools") == true)
        XCTAssertEqual(store.saveState(for: documentID), .edited)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), diskText)
    }

    func testWritingToolsBlocksDocumentSwitchUntilFinalTextIsCommitted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "A original\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "B original\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)
        let first = try XCTUnwrap(store.documents.first { $0.url == firstURL.standardizedFileURL })
        let second = try XCTUnwrap(store.documents.first { $0.url == secondURL.standardizedFileURL })
        XCTAssertTrue(store.selectDocument(id: first.id))
        let didLoadFirst = await waitUntil {
            !store.isDocumentLoading && store.selectedDocumentID == first.id
        }
        XCTAssertTrue(didLoadFirst)
        store.testing_stopFileWatcher()
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: first.id))

        XCTAssertFalse(store.selectDocument(id: second.id))
        XCTAssertEqual(store.selectedDocumentID, first.id)
        XCTAssertEqual(store.documentText, "A original\n")

        store.commitWritingToolsText("A rewritten\n", documentID: first.id)
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: first.id))
        XCTAssertEqual(store.selectedDocumentID, first.id)
        XCTAssertEqual(store.documentText, "A rewritten\n")
        XCTAssertEqual(store.dirtyTextByDocumentID[first.id], "A rewritten\n")
        XCTAssertEqual(store.saveState(for: first.id), .edited)

        XCTAssertTrue(store.selectDocument(id: second.id))
        let didLoadSecond = await waitUntil {
            !store.isDocumentLoading && store.selectedDocumentID == second.id
        }
        XCTAssertTrue(didLoadSecond)

        XCTAssertEqual(store.selectedDocumentID, second.id)
        XCTAssertEqual(store.documentText, "B original\n")
        XCTAssertEqual(store.dirtyTextByDocumentID[first.id], "A rewritten\n")
        XCTAssertEqual(store.saveState(for: first.id), .edited)
    }

    func testWritingToolsBlocksDiscardAndIdentityChangingOperationsUntilItEnds() async throws {
        let root = try makeTemporaryDirectory()
        let otherRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let fileURL = root.appendingPathComponent("Flow.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.selectedDocument)
        store.testing_stopFileWatcher()

        XCTAssertTrue(store.setWritingToolsActive(true, documentID: document.id))
        XCTAssertEqual(store.activeWritingToolsDocumentID, document.id)
        XCTAssertEqual(store.saveState(for: document.id), .clean)

        store.renameDocument(id: document.id, to: "Renamed.md")
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.md").path))

        store.deleteDocument(document)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.openWorkspace(otherRoot)
        XCTAssertEqual(store.workspaceURL?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertNotNil(store.errorMessage)

        store.commitWritingToolsText("Rewritten\n", documentID: document.id)
        store.discardUnsavedChanges(for: document.id)
        XCTAssertEqual(store.documentText, "Rewritten\n")
        XCTAssertEqual(store.saveState(for: document.id), .edited)

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: document.id))
        XCTAssertNil(store.activeWritingToolsDocumentID)
    }

    func testCleanWritingToolsSessionBlocksWorkspaceCreation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        let createdFileURL = root.appendingPathComponent("Created.txt")
        let createdFolderURL = root.appendingPathComponent("Created Folder", isDirectory: true)
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()

        XCTAssertEqual(store.saveState(for: documentID), .clean)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))

        store.createFile(named: createdFileURL.lastPathComponent)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdFileURL.path))

        store.createFolder(named: createdFolderURL.lastPathComponent)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdFolderURL.path))

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))
    }

    func testCleanWritingToolsSessionBlocksWorkspacePDFAnnotationExport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flowURL = root.appendingPathComponent("Flow.md")
        let pdfURL = root.appendingPathComponent("Sample.pdf")
        try "Original\n".write(to: flowURL, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)
        let flowDocument = try XCTUnwrap(
            store.documents.first { $0.url == flowURL.standardizedFileURL }
        )
        XCTAssertTrue(store.selectDocument(id: flowDocument.id))
        let didSelectFlowDocument = await waitUntil {
            !store.isDocumentLoading && store.selectedDocumentID == flowDocument.id
        }
        XCTAssertTrue(didSelectFlowDocument)
        store.testing_stopFileWatcher()

        XCTAssertEqual(store.saveState(for: flowDocument.id), .clean)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: flowDocument.id))
        let selectedDocumentID = store.selectedDocumentID

        store.exportAllPDFAnnotationsToMarkdown()

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.selectedDocumentID, selectedDocumentID)
        XCTAssertEqual(store.documentText, "Original\n")
        XCTAssertTrue(store.errorMessage?.contains("Finish Writing Tools") == true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("notes/Workspace PDF Annotations.md").path
            )
        )
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: flowDocument.id))
    }

    func testCleanWritingToolsSessionBlocksWorkspaceReplaceAndDirectMutation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()

        XCTAssertEqual(store.saveState(for: documentID), .clean)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))

        store.replaceInWorkspace(find: "Original", replacement: "Replaced")
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "Original\n")

        let mutation = store.applyTextMutation(
            documentID: documentID,
            range: NSRange(location: 0, length: 8),
            expectedText: "Original",
            replacement: "Changed"
        )
        XCTAssertNil(mutation)
        XCTAssertEqual(store.documentText, "Original\n")
        XCTAssertEqual(store.saveState(for: documentID), .clean)

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))
    }

    func testWritingToolsStartIsRejectedForAStaleEditorDocument() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        try "A\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "B\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)
        let first = try XCTUnwrap(store.documents.first { $0.url == firstURL.standardizedFileURL })
        let second = try XCTUnwrap(store.documents.first { $0.url == secondURL.standardizedFileURL })
        XCTAssertTrue(store.selectDocument(id: second.id))
        let didSelectSecond = await waitUntil {
            !store.isDocumentLoading && store.selectedDocumentID == second.id
        }
        XCTAssertTrue(didSelectSecond)

        XCTAssertFalse(store.setWritingToolsActive(true, documentID: first.id))
        XCTAssertNil(store.activeWritingToolsDocumentID)
    }

    func testWritingToolsStartIsRejectedWhileWorkspaceMutationIsBusy() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Text\n".write(
            to: root.appendingPathComponent("Flow.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)

        store.createFolder(named: "Pending")
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.setWritingToolsActive(true, documentID: documentID))
        XCTAssertNil(store.activeWritingToolsDocumentID)

        let didFinish = await waitUntil { !store.isBusy }
        XCTAssertTrue(didFinish)
    }

    func testWritingToolsInvalidatesCanceledExternalRefreshCompletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Text\n".write(
            to: root.appendingPathComponent("Flow.md"),
            atomically: true,
            encoding: .utf8
        )
        let scanner = BlockingFailureWorkspaceScanner(blockingCall: 2)
        defer { scanner.resume() }
        let store = makeWorkspaceStore(scanner: scanner)
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()

        store.refresh()
        let didStartRefresh = await waitUntil { scanner.isBlocking }
        XCTAssertTrue(didStartRefresh)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))

        scanner.resume()
        let didCompleteCanceledRefresh = await waitUntil { scanner.didCompleteBlockedCall }
        XCTAssertTrue(didCompleteCanceledRefresh)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.errorMessage)

        let didRunDeferredRefresh = await waitUntil { scanner.callCount >= 3 }
        XCTAssertTrue(didRunDeferredRefresh)
    }

    func testWritingToolsDeferredFullRefreshSupersedesIncrementalEventBeforeDebounce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        let deferredURL = root.appendingPathComponent("Deferred.md")
        let incrementalURL = root.appendingPathComponent("Incremental.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()
        store.testing_clearWatcherSuppression()

        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))
        try "Deferred\n".write(to: deferredURL, atomically: true, encoding: .utf8)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [deferredURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)

        try "Incremental\n".write(to: incrementalURL, atomically: true, encoding: .utf8)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [incrementalURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)

        let didApplyFullRefresh = await waitUntil(timeout: 8) {
            store.document(id: deferredURL.standardizedFileURL.path) != nil
                && store.document(id: incrementalURL.standardizedFileURL.path) != nil
                && !store.testing_hasDeferredWritingToolsRefresh
        }
        XCTAssertTrue(didApplyFullRefresh)
    }

    func testWritingToolsDefersWatcherEventDuringInternalMutationSuppression() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        let externalURL = root.appendingPathComponent("Suppressed.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()

        store.setDocumentText("Saved before Writing Tools\n")
        store.saveSelectedFile()
        XCTAssertTrue(store.isSaving)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))

        try "External\n".write(to: externalURL, atomically: true, encoding: .utf8)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [externalURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))
        let didApplyDeferredRefresh = await waitUntil(timeout: 8) {
            !store.isSaving
                && store.document(id: externalURL.standardizedFileURL.path) != nil
                && !store.testing_hasDeferredWritingToolsRefresh
        }
        XCTAssertTrue(didApplyDeferredRefresh)
    }

    func testWritingToolsDeferredFullRefreshSurvivesBusyMutationSuppression() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Flow.md")
        let deferredURL = root.appendingPathComponent("Deferred.md")
        try "Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let scanner = BlockingWorkspaceScanner(blockingCall: 2)
        defer { scanner.resume() }
        let store = makeWorkspaceStore(scanner: scanner)
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()
        store.testing_clearWatcherSuppression()

        XCTAssertTrue(store.setWritingToolsActive(true, documentID: documentID))
        try "Deferred\n".write(to: deferredURL, atomically: true, encoding: .utf8)
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [deferredURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: false
        ))
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: documentID))

        store.createFolder(named: "Busy Mutation")
        XCTAssertTrue(store.isBusy)
        let didBlockMutationScan = await waitUntil { scanner.isBlocking }
        XCTAssertTrue(didBlockMutationScan)

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.testing_hasDeferredWritingToolsRefresh)
        scanner.resume()

        let didFinishMutation = await waitUntil(timeout: 8) {
            !store.isBusy && scanner.didCompleteBlockedCall
        }
        XCTAssertTrue(didFinishMutation)
        let didCompleteDeferredRefresh = await waitUntil(timeout: 8) {
            store.document(id: deferredURL.standardizedFileURL.path) != nil
                && !store.testing_hasDeferredWritingToolsRefresh
        }
        XCTAssertTrue(didCompleteDeferredRefresh)
    }

    func testWritingToolsBlocksConfirmationOfAPreviouslyPlannedMove() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let noteURL = root.appendingPathComponent("Note.md")
        let dataURL = root.appendingPathComponent("Data.txt")
        try "[data](Data.txt)\n".write(to: noteURL, atomically: true, encoding: .utf8)
        try "Data\n".write(to: dataURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)
        let data = try XCTUnwrap(store.documents.first { $0.url == dataURL.standardizedFileURL })
        XCTAssertTrue(store.selectDocument(id: data.id))
        let didSelect = await waitUntil {
            !store.isDocumentLoading && store.selectedDocumentID == data.id
        }
        XCTAssertTrue(didSelect)

        store.moveItem(id: data.id, toDirectory: archive)
        let didPlan = await waitUntil { !store.isBusy && store.pendingMarkdownLinkMoveReview != nil }
        XCTAssertTrue(didPlan)
        let review = try XCTUnwrap(store.pendingMarkdownLinkMoveReview)
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: data.id))

        store.confirmMarkdownLinkMoveReview(id: review.id)

        XCTAssertNotNil(store.pendingMarkdownLinkMoveReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: archive.appendingPathComponent("Data.txt").path
        ))
        XCTAssertTrue(store.errorMessage?.localizedCaseInsensitiveContains("Writing Tools") == true)

        XCTAssertTrue(store.setWritingToolsActive(false, documentID: data.id))
        store.cancelMarkdownLinkMoveReview(id: review.id)
    }
}
