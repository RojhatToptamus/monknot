import CoreServices
import XCTest
@testable import MonknotApp

final class WorkspaceFileWatcherTests: XCTestCase {
    func testDroppedEventsRequireFullRescanEvenWithoutContentFlags() {
        let event = WorkspaceFileWatcher.makeEvent(
            paths: ["/tmp/workspace"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)]
        )

        XCTAssertEqual(event?.changedPaths, [])
        XCTAssertEqual(event?.modifiedOnlyPaths, [])
        XCTAssertEqual(event?.requiresFullRescan, true)
    }

    func testModifiedOnlyEventsTrackPathWithoutFullRescan() {
        let event = WorkspaceFileWatcher.makeEvent(
            paths: ["/tmp/workspace/Note.md"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)]
        )

        XCTAssertEqual(event?.changedPaths, ["/tmp/workspace/Note.md"])
        XCTAssertEqual(event?.modifiedOnlyPaths, ["/tmp/workspace/Note.md"])
        XCTAssertEqual(event?.requiresFullRescan, false)
    }

    func testPathsUnderTheResolvedRootAreReportedUnderTheOpenedRoot() {
        let rebased = { (path: String) in
            WorkspaceFileWatcher.rebased(path, from: "/private/var/w", to: "/var/w")
        }
        XCTAssertEqual(rebased("/private/var/w/Note.md"), "/var/w/Note.md")
        XCTAssertEqual(rebased("/private/var/w"), "/var/w")
        XCTAssertEqual(rebased("/private/var/work/Note.md"), "/private/var/work/Note.md")
        XCTAssertEqual(
            WorkspaceFileWatcher.rebased("/Users/a/w/Note.md", from: "/Users/a/w", to: "/Users/a/w"),
            "/Users/a/w/Note.md"
        )
    }
}
