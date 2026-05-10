import XCTest
@testable import MarkprevCore

final class WorkspaceTabStateTests: XCTestCase {
    func testOpeningExistingTabActivatesWithoutMovingIt() {
        let root = URL(fileURLWithPath: "/tmp/MarkprevWorkspace", isDirectory: true)
        let readme = WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root)
        let guide = WorkspaceDocument(url: root.appendingPathComponent("Guide.pdf"), rootURL: root)
        let notes = WorkspaceDocument(url: root.appendingPathComponent("Notes.md"), rootURL: root)

        var state = WorkspaceTabState()
        state.open(readme)
        state.open(guide)
        state.open(notes)
        state.moveTab(documentID: notes.id, before: readme.id)

        let reorderedIDs = state.tabs.map(\.documentID)
        XCTAssertEqual(reorderedIDs, [notes.id, readme.id, guide.id])

        state.open(readme)

        XCTAssertEqual(state.tabs.map(\.documentID), reorderedIDs)
        XCTAssertEqual(state.selectedDocumentID, readme.id)
    }
}
