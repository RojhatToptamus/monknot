import XCTest
import MarkprevCore

final class WorkspaceTabStatePersistenceTests: XCTestCase {
    func testPersistsOpenPinnedAndActiveTabsPerWorkspace() throws {
        let suiteName = "WorkspaceTabStatePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let root = URL(fileURLWithPath: "/tmp/MarkprevTabs", isDirectory: true)
        let readme = WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root)
        let guide = WorkspaceDocument(url: root.appendingPathComponent("Guide.pdf"), rootURL: root)

        var state = WorkspaceTabState()
        state.open(readme)
        state.open(guide)
        state.togglePin(documentID: guide.id)

        let persistence = WorkspaceTabStatePersistence(defaults: defaults)
        persistence.save(state, for: root)

        let restored = try XCTUnwrap(persistence.load(for: root))
        XCTAssertEqual(restored.tabs.map(\.documentID), [guide.id, readme.id])
        XCTAssertEqual(restored.tabs.map(\.isPinned), [true, false])
        XCTAssertEqual(restored.selectedDocumentID, guide.id)
        XCTAssertNil(persistence.load(for: root.appendingPathComponent("Other", isDirectory: true)))
    }
}
