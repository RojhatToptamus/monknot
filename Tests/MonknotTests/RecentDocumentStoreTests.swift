import XCTest
@testable import MonknotCore

final class RecentDocumentStoreTests: XCTestCase {
    func testRecordsRecentDocumentsPerWorkspace() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "RecentDocumentStoreTests")
        let defaults = defaultsFixture.userDefaults

        let store = RecentDocumentStore(userDefaults: defaults, limit: 3)
        let workspace = URL(fileURLWithPath: "/tmp/workspace-a", isDirectory: true)
        let otherWorkspace = URL(fileURLWithPath: "/tmp/workspace-b", isDirectory: true)

        let alpha = WorkspaceDocument(
            url: workspace.appendingPathComponent("alpha.md"),
            rootURL: workspace
        )
        let beta = WorkspaceDocument(
            url: workspace.appendingPathComponent("beta.md"),
            rootURL: workspace
        )
        let gamma = WorkspaceDocument(
            url: otherWorkspace.appendingPathComponent("gamma.md"),
            rootURL: otherWorkspace
        )

        store.record(alpha, workspaceURL: workspace)
        store.record(beta, workspaceURL: workspace)
        store.record(gamma, workspaceURL: otherWorkspace)
        store.record(alpha, workspaceURL: workspace)

        XCTAssertEqual(store.entries(for: workspace).map(\.relativePath), ["alpha.md", "beta.md"])
        XCTAssertEqual(store.entries(for: otherWorkspace).map(\.relativePath), ["gamma.md"])
    }

    func testRemapFollowsRenamedDocumentsInPlace() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "RecentDocumentStoreTests")
        let store = RecentDocumentStore(userDefaults: defaultsFixture.userDefaults)
        let workspace = URL(fileURLWithPath: "/tmp/workspace-a", isDirectory: true)
        let alpha = WorkspaceDocument(url: workspace.appendingPathComponent("alpha.md"), rootURL: workspace)
        let beta = WorkspaceDocument(url: workspace.appendingPathComponent("beta.md"), rootURL: workspace)
        let renamed = WorkspaceDocument(url: workspace.appendingPathComponent("notes/renamed.md"), rootURL: workspace)
        store.record(alpha, workspaceURL: workspace)
        store.record(beta, workspaceURL: workspace)

        XCTAssertTrue(store.remap([alpha.id: renamed], workspaceURL: workspace))
        XCTAssertEqual(store.entries(for: workspace).map(\.documentID), [beta.id, renamed.id])
        XCTAssertEqual(store.entries(for: workspace).last?.relativePath, "notes/renamed.md")
        XCTAssertEqual(store.entries(for: workspace).last?.displayName, renamed.displayName)
        XCTAssertFalse(store.remap([alpha.id: renamed], workspaceURL: workspace))
    }
}
