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
}
