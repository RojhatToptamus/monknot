import XCTest
@testable import MonknotCore

final class WorkspaceDocumentSupportTests: XCTestCase {
    func testDisplayNameForRelativePathUsesLastPathComponent() {
        XCTAssertEqual(
            WorkspaceDocumentSupport.displayName(forRelativePath: "notes/daily/2026-06-08.md"),
            "2026-06-08.md"
        )
        XCTAssertEqual(
            WorkspaceDocumentSupport.displayName(forRelativePath: "README.md"),
            "README.md"
        )
    }
}
