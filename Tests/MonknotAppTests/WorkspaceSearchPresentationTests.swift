import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

final class WorkspaceSearchPresentationTests: XCTestCase {
    func testUtilityPanelUsesTheCompleteWorkspaceZoom() {
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.densityZoomScale(WorkspaceZoomPolicy.maximum),
            WorkspaceZoomPolicy.maximum
        )
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.densityZoomScale(WorkspaceZoomPolicy.minimum),
            WorkspaceZoomPolicy.minimum
        )
    }

    func testSearchFieldFollowsWorkspaceControlZoom() {
        let maximumHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .defaultDark,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let normalHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .defaultDark,
            zoomScale: 1
        )

        XCTAssertGreaterThan(maximumHeight, normalHeight)
        XCTAssertEqual(
            maximumHeight,
            MonknotMetrics.interfaceControl(
                28,
                theme: .defaultDark,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            accuracy: 0.001
        )
    }

    func testGroupingPreservesFirstFileOrderAndGlobalSelectionIndices() {
        let results = [
            result(id: "notes-1", documentID: "/Notes.md", relativePath: "Notes.md", line: 4),
            result(id: "brief-1", documentID: "/Brief.pdf", relativePath: "Reference/Brief.pdf", kind: .pdf, line: 2),
            result(id: "notes-2", documentID: "/Notes.md", relativePath: "Notes.md", line: 18)
        ]

        let groups = WorkspaceSearchResultGrouping.groups(from: results)

        XCTAssertEqual(groups.map(\.documentID), ["/Notes.md", "/Brief.pdf"])
        XCTAssertEqual(groups[0].matches.map(\.index), [0, 2])
        XCTAssertEqual(groups[1].matches.map(\.index), [1])
        XCTAssertEqual(groups[0].relativePath, "Notes.md")
        XCTAssertEqual(groups[1].kind, .pdf)
    }

    func testGroupingReturnsNoPlaceholderGroupForAnEmptySearch() {
        XCTAssertTrue(WorkspaceSearchResultGrouping.groups(from: []).isEmpty)
    }

    private func result(
        id: String,
        documentID: String,
        relativePath: String,
        kind: WorkspaceSearchResultKind = .text,
        line: Int
    ) -> WorkspaceSearchResult {
        WorkspaceSearchResult(
            id: id,
            documentID: documentID,
            relativePath: relativePath,
            displayName: URL(fileURLWithPath: relativePath).lastPathComponent,
            kind: kind,
            line: line,
            column: 1,
            preview: "A matching workspace result"
        )
    }
}
