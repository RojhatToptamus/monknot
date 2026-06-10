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
}
