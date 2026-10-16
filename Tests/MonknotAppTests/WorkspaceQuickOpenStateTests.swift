import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceQuickOpenStateTests: XCTestCase {
    func testArrowSelectionClampsResetsOnQueryAndSurvivesWorkspaceRefresh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-quick-open-state-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.md", "beta.md", "gamma.md"] {
            try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let documents = try WorkspaceDocumentScanner().scan(rootURL: root).documents

        let state = WorkspaceQuickOpenState()
        state.present(documents: documents)
        XCTAssertEqual(state.matches.count, 3)
        XCTAssertEqual(state.selectedIndex, 0)

        state.moveSelection(by: -1)
        XCTAssertEqual(state.selectedIndex, 0)
        state.moveSelection(by: 1)
        state.moveSelection(by: 1)
        state.moveSelection(by: 1)
        XCTAssertEqual(state.selectedIndex, 2)
        let chosen = try XCTUnwrap(state.selectedMatch)

        // A file created while the list is open must not move the choice.
        try "new".write(to: root.appendingPathComponent("aardvark.md"), atomically: true, encoding: .utf8)
        state.refresh(documents: try WorkspaceDocumentScanner().scan(rootURL: root).documents)
        XCTAssertEqual(state.matches.count, 4)
        XCTAssertEqual(state.selectedMatch?.id, chosen.id)

        state.setQuery("be", documents: documents)
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.selectedMatch?.relativePath, "beta.md")

        state.dismiss()
        XCTAssertNil(state.selectedMatch)
        state.moveSelection(by: 1)
        XCTAssertEqual(state.selectedIndex, 0)
    }
}
