import XCTest
@testable import MonknotCore

final class WorkspaceReplaceScopeTests: XCTestCase {
    func testSelectedSearchResultScopeUsesSystemImage() {
        XCTAssertEqual(WorkspaceReplaceScope.selectedSearchResult.systemImage, "doc")
        XCTAssertEqual(WorkspaceReplaceScope.selectedSearchResult.title, "Selected file")
    }
}
