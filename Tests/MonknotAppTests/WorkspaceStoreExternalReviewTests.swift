import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
final class WorkspaceStoreExternalReviewTests: WorkspaceStoreConflictTestCase {
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

    func testKeepLocalExternalReviewKeepsDirtyBuffer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Keep.md")
        try "# Keep\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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

    func testExternalReviewShowsExactVersionsAndAppliesSafeMergeWithoutWriting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Merge.md")
        let baseline = "head\nbody\ntail\n"
        let local = "local head\nbody\ntail\n"
        let disk = "head\nbody\ndisk tail\n"
        try baseline.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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
        let store = makeWorkspaceStore(scanner: scanner)
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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
}
