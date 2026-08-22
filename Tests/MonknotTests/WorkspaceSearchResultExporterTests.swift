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

    func testTabSeparatedTextEscapesEveryFreeTextFieldExactly() {
        let result = WorkspaceSearchResult(
            id: "1",
            documentID: "/tmp/note.md",
            relativePath: "notes\todd\nname.md",
            displayName: "name.md",
            kind: .pdf,
            line: 3,
            column: 0,
            preview: "first\tsecond\r\nthird"
        )

        XCTAssertEqual(
            WorkspaceSearchResultExporter.tabSeparatedText(
                results: [result],
                query: "  query\twith\nlines  "
            ),
            "path\tline\tpreview\tquery\nnotes odd name.md\tp3\tfirst second  third\tquery with lines"
        )
    }
}
