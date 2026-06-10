import XCTest
@testable import MonknotCore

final class DailyNotePlannerTests: XCTestCase {
    func testBuildsInboxPathAndDatedFilename() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC

        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let inbox = DailyNotePlanner.inboxDirectoryURL(workspaceURL: workspace)
        let noteURL = DailyNotePlanner.dailyNoteURL(workspaceURL: workspace, date: date, calendar: calendar)

        XCTAssertEqual(inbox.lastPathComponent, "inbox")
        XCTAssertEqual(noteURL.lastPathComponent, "2025-01-01.md")
        XCTAssertEqual(DailyNotePlanner.initialContent(for: date, calendar: calendar), "# 2025-01-01\n\n")
    }
}
