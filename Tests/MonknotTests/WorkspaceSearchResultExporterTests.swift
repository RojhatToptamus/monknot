import XCTest
@testable import MonknotCore

final class WorkspaceSearchResultExporterTests: XCTestCase {
    func testTabSeparatedTextIncludesHeaderAndRows() {
        let results = [
            WorkspaceSearchResult(
                id: "1",
                documentID: "/tmp/note.md",
                relativePath: "note.md",
                displayName: "note.md",
                kind: .text,
                line: 4,
                column: 2,
                preview: "matched line"
            )
        ]

        let exported = WorkspaceSearchResultExporter.tabSeparatedText(results: results, query: "match")

        XCTAssertTrue(exported.hasPrefix("path\tline\tpreview\tquery\n"))
        XCTAssertTrue(exported.contains("note.md\t4\tmatched line\tmatch"))
    }
}
