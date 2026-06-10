import XCTest
@testable import MonknotCore

final class WorkspaceContextOrderingTests: XCTestCase {
    func testOrderedContextPathsPrefersRelatedNotesFirst() {
        let ordered = WorkspaceContextOrdering.orderedContextPaths(
            from: ["other.md", "related.md", "other.md"],
            preferredRelativePaths: ["related.md", "missing.md"]
        )

        XCTAssertEqual(ordered, ["related.md", "other.md"])
    }
}
