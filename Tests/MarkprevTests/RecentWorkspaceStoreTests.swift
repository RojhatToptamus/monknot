import Foundation
import XCTest
@testable import MarkprevCore

final class RecentWorkspaceStoreTests: XCTestCase {
    func testRecordKeepsMostRecentWorkspaceFirstAndDeduplicatesPaths() throws {
        let userDefaults = try makeUserDefaults()
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 3)
        let first = URL(fileURLWithPath: "/tmp/Markprev/A", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Markprev/B", isDirectory: true)

        store.record(first)
        store.record(second)
        store.record(first)

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: first.path, displayName: "A"),
            RecentWorkspaceEntry(path: second.path, displayName: "B")
        ])
    }

    func testRecordLimitsStoredWorkspaces() throws {
        let userDefaults = try makeUserDefaults()
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 2)

        store.record(URL(fileURLWithPath: "/tmp/Markprev/A", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Markprev/B", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Markprev/C", isDirectory: true))

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: "/tmp/Markprev/C", displayName: "C"),
            RecentWorkspaceEntry(path: "/tmp/Markprev/B", displayName: "B")
        ])
    }

    func testRemoveAndClearUpdateStoredWorkspaces() throws {
        let userDefaults = try makeUserDefaults()
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 3)

        store.record(URL(fileURLWithPath: "/tmp/Markprev/A", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Markprev/B", isDirectory: true))
        store.remove(path: "/tmp/Markprev/A")

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: "/tmp/Markprev/B", displayName: "B")
        ])

        store.clear()
        XCTAssertEqual(store.entries(), [])
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "RecentWorkspaceStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
