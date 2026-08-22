import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStoreLinkMoveRollbackTests: WorkspaceStoreLinkTestCase {
    func testReplacedDestinationParentBlocksConfirmedMoveAsStale() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreMoveParentTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationFolder = root.appendingPathComponent("Archive", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let note = root.appendingPathComponent("Note.md").standardizedFileURL
        let source = root.appendingPathComponent("Data.txt").standardizedFileURL
        try "[data](Data.txt)\n".write(to: note, atomically: true, encoding: .utf8)
        try "data\n".write(to: source, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }
        store.moveItem(id: source.path, toDirectory: destinationFolder)
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        try FileManager.default.removeItem(at: destinationFolder)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        store.confirmMarkdownLinkMoveReview(id: review.id)

        await assertEventually {
            !store.isBusy && store.errorMessage?.localizedCaseInsensitiveContains("changed") == true
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationFolder.appendingPathComponent("Data.txt").path
            )
        )
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "[data](Data.txt)\n")
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testReplacedNonMarkdownSourceBlocksConfirmedMoveAsStale() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreNonMarkdownMoveTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = root.appendingPathComponent("Note.md").standardizedFileURL
        let source = root.appendingPathComponent("Data.txt").standardizedFileURL
        let destination = root.appendingPathComponent("Moved.txt").standardizedFileURL
        try "[data](Data.txt)\n".write(to: note, atomically: true, encoding: .utf8)
        try "original\n".write(to: source, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }
        guard let sourceDocument = store.documents.first(where: { $0.url == source }) else {
            return XCTFail("Expected text document")
        }

        store.renameDocument(id: sourceDocument.id, to: "Moved.txt")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        try "external replacement with a different size\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        store.confirmMarkdownLinkMoveReview(id: review.id)

        await assertEventually {
            !store.isBusy && store.errorMessage?.localizedCaseInsensitiveContains("changed") == true
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "external replacement with a different size\n"
        )
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "[data](Data.txt)\n")
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testCaseOnlyFileRenameUsesPreviewAndPublishesNewCasing() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("target.md").standardizedFileURL
        guard WorkspaceFileIdentity.isCaseOnlyRename(
            from: fixture.target,
            to: destination
        ) else {
            throw XCTSkip("The test volume is case-sensitive.")
        }

        let store = makeWorkspaceStore()
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }
        guard let target = store.documents.first(where: { $0.url == fixture.target }) else {
            return XCTFail("Expected target document")
        }

        store.renameDocument(id: target.id, to: "target.md")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.confirmMarkdownLinkMoveReview(id: review.id)
        await assertEventually {
            !store.isBusy && store.documentIDRemapEvent?.destinationID == destination.path
        }

        let names = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertTrue(names.contains("target.md"))
        XCTAssertFalse(names.contains("Target.md"))
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](target.md)\n"
        )
        XCTAssertEqual(store.documentIDRemapEvent?.sourceID, fixture.target.path)
    }

    func testCaseOnlyFolderRenameRollsBackThroughTemporaryHopAfterScanFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreCaseFolderTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes", isDirectory: true).standardizedFileURL
        let destination = root.appendingPathComponent("notes", isDirectory: true).standardizedFileURL
        let source = root.appendingPathComponent("Source.md").standardizedFileURL
        let target = folder.appendingPathComponent("Target.md").standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[target](Notes/Target.md)\n".write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: target, atomically: true, encoding: .utf8)
        guard WorkspaceFileIdentity.isCaseOnlyRename(from: folder, to: destination) else {
            throw XCTSkip("The test volume is case-sensitive.")
        }

        let store = makeWorkspaceStore(scanner: FailingWorkspaceScanner(failOnCall: 3))
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        store.renameFolder(id: folder.path, to: "notes")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.confirmMarkdownLinkMoveReview(id: review.id)
        await assertEventually {
            !store.isBusy && store.errorMessage?.localizedCaseInsensitiveContains("scan failure") == true
        }

        let names = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertTrue(names.contains("Notes"))
        XCTAssertFalse(names.contains("notes"))
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "[target](Notes/Target.md)\n"
        )
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testFolderRenameUpdatesInboundLinksAndContainedDocumentRemaps() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreLinkMoveFolderTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Notes", isDirectory: true).standardizedFileURL
        let source = root.appendingPathComponent("Source.md").standardizedFileURL
        let target = folder.appendingPathComponent("Target.md").standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[target](Notes/Target.md)\n".write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: target, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        store.renameFolder(id: folder.path, to: "Archive")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.confirmMarkdownLinkMoveReview(id: review.id)
        let destination = root
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("Target.md")
            .standardizedFileURL
        await assertEventually {
            !store.isBusy && FileManager.default.fileExists(atPath: destination.path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "[target](Archive/Target.md)\n"
        )
        XCTAssertEqual(store.documentIDRemapEvent?.sourceID, target.path)
        XCTAssertEqual(store.documentIDRemapEvent?.destinationID, destination.path)
    }

    func testRenamePreviewsAndUpdatesLinksBeforePublishingRemap() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = makeWorkspaceStore()
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        guard let target = store.documents.first(where: { $0.url == fixture.target }) else {
            return XCTFail("Expected target document")
        }
        let destination = fixture.root.appendingPathComponent("Moved.md").standardizedFileURL
        store.renameDocument(id: target.id, to: "Moved.md")

        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }
        XCTAssertEqual(review.plan.rewriteCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(store.documentIDRemapEvent)

        store.confirmMarkdownLinkMoveReview(id: review.id)
        let didCommit = await waitUntil {
            !store.isBusy &&
                FileManager.default.fileExists(atPath: destination.path) &&
                store.documentIDRemapEvent?.destinationID == destination.path
        }
        XCTAssertTrue(didCommit, store.errorMessage ?? "Move did not finish.")

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](Moved.md)\n"
        )
        XCTAssertEqual(store.documentIDRemapEvent?.sourceID, fixture.target.path)
    }

    func testMoveReviewCancellationLeavesFilesAndRemapUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let destinationFolder = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let store = makeWorkspaceStore()
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        store.moveItem(id: fixture.target.path, toDirectory: destinationFolder)
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.cancelMarkdownLinkMoveReview(id: review.id)

        XCTAssertNil(store.pendingMarkdownLinkMoveReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationFolder.appendingPathComponent("Target.md").path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](Target.md)\n"
        )
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testChangedMarkdownRevisionBlocksConfirmedMoveAsStale() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = makeWorkspaceStore()
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        guard let target = store.documents.first(where: { $0.url == fixture.target }) else {
            return XCTFail("Expected target document")
        }
        let destination = fixture.root.appendingPathComponent("Moved.md").standardizedFileURL
        store.renameDocument(id: target.id, to: "Moved.md")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        try "[target](Target.md)\nexternal change\n".write(
            to: fixture.source,
            atomically: false,
            encoding: .utf8
        )
        store.confirmMarkdownLinkMoveReview(id: review.id)

        await assertEventually {
            !store.isBusy && store.errorMessage?.localizedCaseInsensitiveContains("changed") == true
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](Target.md)\nexternal change\n"
        )
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testPostMoveScanFailureRollsBackMoveAndLinkWritesWithoutRemap() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let scanner = FailingWorkspaceScanner(failOnCall: 3)
        let store = makeWorkspaceStore(scanner: scanner)
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }

        guard let target = store.documents.first(where: { $0.url == fixture.target }) else {
            return XCTFail("Expected target document")
        }
        let destination = fixture.root.appendingPathComponent("Moved.md").standardizedFileURL
        store.renameDocument(id: target.id, to: "Moved.md")
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.confirmMarkdownLinkMoveReview(id: review.id)

        await assertEventually {
            !store.isBusy && store.errorMessage?.localizedCaseInsensitiveContains("scan failure") == true
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](Target.md)\n"
        )
        XCTAssertNil(store.documentIDRemapEvent)
    }

    func testCutPasteUsesTheSameReviewAndClearsTransferOnlyAfterSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let destinationFolder = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let store = makeWorkspaceStore()
        store.openWorkspace(fixture.root)
        await assertEventually { !store.isBusy && store.documents.count == 2 }
        guard let target = store.documents.first(where: { $0.url == fixture.target }) else {
            return XCTFail("Expected target document")
        }

        store.cutDocument(target)
        store.pasteDocumentTransfer(into: destinationFolder)
        await assertEventually {
            !store.isBusy && store.pendingMarkdownLinkMoveReview != nil
        }
        XCTAssertTrue(store.canPasteDocumentTransfer)
        guard let review = store.pendingMarkdownLinkMoveReview else {
            return XCTFail("Expected link move review")
        }

        store.confirmMarkdownLinkMoveReview(id: review.id)
        let destination = destinationFolder.appendingPathComponent("Target.md").standardizedFileURL
        await assertEventually {
            !store.isBusy && FileManager.default.fileExists(atPath: destination.path)
        }
        XCTAssertFalse(store.canPasteDocumentTransfer)
        XCTAssertEqual(
            try String(contentsOf: fixture.source, encoding: .utf8),
            "[target](Archive/Target.md)\n"
        )
        XCTAssertEqual(store.documentIDRemapEvent?.destinationID, destination.path)
    }
}
