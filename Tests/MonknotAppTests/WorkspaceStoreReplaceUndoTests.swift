import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStoreReplaceUndoTests: XCTestCase {
    func testTextMutationUndoAndRedoApplyExactTextSynchronously() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try "alpha beta".write(to: file, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil {
            !store.isBusy && !store.isDocumentLoading && store.documentText == "alpha beta"
        }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        let range = (store.documentText as NSString).range(of: "beta")
        let undoMutation = try XCTUnwrap(store.applyTextMutation(
            documentID: documentID,
            range: range,
            expectedText: "beta",
            replacement: "gamma"
        ))
        XCTAssertEqual(store.documentText, "alpha gamma")

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        WorkspaceTextMutationUndo.register(
            undoMutation,
            store: store,
            undoManager: undoManager,
            actionName: "Replace Word"
        )
        undoManager.endUndoGrouping()

        undoManager.undo()
        XCTAssertEqual(store.documentText, "alpha beta")
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(store.documentText, "alpha gamma")
        XCTAssertTrue(undoManager.canUndo)
    }

    func testLaterUserTextMutationInvalidatesWorkspaceReplaceUndo() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try "alpha beta".write(to: file, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil {
            !store.isBusy && !store.isDocumentLoading && store.documentText == "alpha beta"
        }
        XCTAssertTrue(didLoad)

        store.replaceInWorkspace(find: "beta", replacement: "gamma")
        let didReplace = await waitUntil {
            !store.isBusy && store.canUndoWorkspaceReplace && store.documentText == "alpha gamma"
        }
        XCTAssertTrue(didReplace)

        store.setDocumentText("alpha gamma!")

        XCTAssertFalse(store.canUndoWorkspaceReplace)
        store.undoLastWorkspaceReplace()
        XCTAssertEqual(store.documentText, "alpha gamma!")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha gamma")
    }

    func testReplaceThenUndoRestoresContent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)

        store.replaceInWorkspace(find: "beta", replacement: "gamma")

        let didReplace = await waitUntil { store.canUndoWorkspaceReplace }
        XCTAssertTrue(didReplace)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha gamma")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "gamma only")

        store.undoLastWorkspaceReplace()

        let didUndo = await waitUntil { !store.canUndoWorkspaceReplace && !store.isBusy }
        XCTAssertTrue(didUndo)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha beta")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "beta only")
    }

    func testSearchResultsScopeSkipsFilesOutsideResults() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)

        let firstID = store.documents.first(where: { $0.relativePath == "first.md" })!.id
        store.replaceInWorkspace(
            find: "beta",
            replacement: "gamma",
            scope: .searchResultsOnly,
            searchResultDocumentIDs: [firstID]
        )

        let didReplace = await waitUntil { !store.isBusy && store.workspaceReplaceSummary != nil }
        XCTAssertTrue(didReplace)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha gamma")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "beta only")
    }

    func testSelectedSearchResultScopeReplacesOnlySelectedFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)

        let didLoad = await waitUntil { !store.isBusy && store.documents.count == 2 }
        XCTAssertTrue(didLoad)

        let secondID = store.documents.first(where: { $0.relativePath == "second.md" })!.id
        store.replaceInWorkspace(
            find: "beta",
            replacement: "gamma",
            scope: .selectedSearchResult,
            searchResultDocumentIDs: [secondID]
        )

        let didReplace = await waitUntil { !store.isBusy && store.workspaceReplaceSummary != nil }
        XCTAssertTrue(didReplace)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha beta")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "gamma only")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-store-replace-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return condition()
    }
}
