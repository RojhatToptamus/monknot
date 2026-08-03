import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

final class WorkspaceSearchPresentationTests: XCTestCase {
    func testUtilityPanelCapsExtremeDocumentZoom() {
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.effectiveZoomScale(WorkspaceZoomPolicy.maximum),
            WorkspaceSearchLayoutPolicy.maximumUtilityZoomScale
        )
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.effectiveZoomScale(WorkspaceZoomPolicy.minimum),
            WorkspaceZoomPolicy.minimum
        )
    }

    func testSearchFieldUsesTheBoundedUtilityZoomCurve() {
        let maximumHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .codexDark,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let ceilingHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .codexDark,
            zoomScale: WorkspaceSearchLayoutPolicy.maximumUtilityZoomScale
        )
        let normalHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .codexDark,
            zoomScale: 1
        )

        XCTAssertEqual(maximumHeight, ceilingHeight, accuracy: 0.001)
        XCTAssertGreaterThan(maximumHeight, normalHeight)
        XCTAssertLessThanOrEqual(maximumHeight, 40)
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
