import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStoreReplaceUndoTests: XCTestCase {
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
