import Foundation
import XCTest
@testable import MonknotCore

final class RecentWorkspaceStoreTests: XCTestCase {
    func testRecordKeepsMostRecentWorkspaceFirstAndDeduplicatesPaths() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "RecentWorkspaceStoreTests")
        let userDefaults = defaultsFixture.userDefaults
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 3)
        let first = URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true)

        store.record(first)
        store.record(second)
        store.record(first)

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: first.path, displayName: "A"),
            RecentWorkspaceEntry(path: second.path, displayName: "B")
        ])
    }

    func testRecordLimitsStoredWorkspaces() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "RecentWorkspaceStoreTests")
        let userDefaults = defaultsFixture.userDefaults
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 2)

        store.record(URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Monknot/C", isDirectory: true))

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: "/tmp/Monknot/C", displayName: "C"),
            RecentWorkspaceEntry(path: "/tmp/Monknot/B", displayName: "B")
        ])
    }

    func testRemoveAndClearUpdateStoredWorkspaces() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "RecentWorkspaceStoreTests")
        let userDefaults = defaultsFixture.userDefaults
        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 3)

        store.record(URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true))
        store.record(URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true))
        store.remove(path: "/tmp/Monknot/A")

        XCTAssertEqual(store.entries(), [
            RecentWorkspaceEntry(path: "/tmp/Monknot/B", displayName: "B")
        ])

        store.clear()
        XCTAssertEqual(store.entries(), [])
    }
}
