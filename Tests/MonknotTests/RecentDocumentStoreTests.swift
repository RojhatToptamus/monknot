import XCTest
@testable import MonknotCore

final class RecentDocumentStoreTests: XCTestCase {
    func testRecordsRecentDocumentsPerWorkspace() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

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
}
