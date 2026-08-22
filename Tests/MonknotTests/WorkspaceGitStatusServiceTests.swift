import XCTest
@testable import MonknotCore

final class WorkspaceGitStatusServiceTests: XCTestCase {
    func testParsesPorcelainStatuses() {
        let output = """
         M README.md
        ?? notes/draft.md
        A  new-file.md
        D  old-file.md
        """
        let service = WorkspaceGitStatusService { _ in output }
        let statuses = service.statusMap(workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))

        XCTAssertEqual(statuses["README.md"], .modified)
        XCTAssertEqual(statuses["notes/draft.md"], .untracked)
        XCTAssertEqual(statuses["new-file.md"], .added)
        XCTAssertEqual(statuses["old-file.md"], .deleted)
    }

    func testNonGitWorkspaceReturnsEmptyMap() {
        let service = WorkspaceGitStatusService { _ in nil }
        let statuses = service.statusMap(workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))
        XCTAssertTrue(statuses.isEmpty)
    }

    func testParsesRenamedDestinationsAndGitQuotedPaths() {
        let output = #"""
        R  old-name.md -> new-name.md
         M "notes/space name.md"
        ?? "notes/line\nname.md"
        """#
        let statuses = WorkspaceGitStatusService { _ in output }
            .statusMap(workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))

        XCTAssertEqual(statuses["new-name.md"], .renamed)
        XCTAssertEqual(statuses["notes/space name.md"], .modified)
        XCTAssertEqual(statuses["notes/line\nname.md"], .untracked)
        XCTAssertNil(statuses["old-name.md -> new-name.md"])
    }
}
