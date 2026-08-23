import Foundation
import XCTest
@testable import MonknotCore

final class SavedWorkspaceStoreTests: XCTestCase {
    func testAddAppendsAndDoesNotReorderExistingWorkspace() {
        let defaultsFixture = IsolatedUserDefaults(prefix: "SavedWorkspaceStoreTests")
        let store = SavedWorkspaceStore(
            userDefaults: defaultsFixture.userDefaults,
            key: "saved",
            lastActiveKey: "active",
            legacyRecentKey: "legacy"
        )
        let first = URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true)

        let firstEntry = store.add(first, bookmarkData: Data([1]))
        _ = store.add(second, bookmarkData: Data([2]))
        let updatedFirst = store.add(first, bookmarkData: Data([3]))

        XCTAssertEqual(store.entries().map(\.path), [first.path, second.path])
        XCTAssertEqual(updatedFirst.id, firstEntry.id)
        XCTAssertEqual(store.entries().first?.bookmarkData, Data([3]))
    }

    func testRenameReorderRemoveAndUndoPersistImmediately() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "SavedWorkspaceStoreTests")
        let store = SavedWorkspaceStore(
            userDefaults: defaultsFixture.userDefaults,
            key: "saved",
            lastActiveKey: "active",
            legacyRecentKey: "legacy"
        )
        let first = store.add(URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true))
        let second = store.add(URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true))

        store.rename(id: first.id, to: "Aurora Project")
        store.move(id: second.id, to: 0)
        store.markActive(id: first.id)

        XCTAssertEqual(store.entries().map(\.displayName), ["B", "Aurora Project"])
        let removal = try XCTUnwrap(store.remove(id: first.id))
        XCTAssertNil(store.lastActiveWorkspaceID())
        XCTAssertEqual(store.entries().map(\.id), [second.id])

        store.restore(removal)
        XCTAssertEqual(store.entries().map(\.id), [second.id, first.id])
        XCTAssertEqual(store.lastActiveWorkspaceID(), first.id)

        store.rename(id: first.id, to: "   ")
        XCTAssertEqual(store.entry(id: first.id)?.displayName, "A")
    }

    func testLocationUpdateKeepsIdentityAndRemovesDuplicatePath() throws {
        let defaultsFixture = IsolatedUserDefaults(prefix: "SavedWorkspaceStoreTests")
        let store = SavedWorkspaceStore(
            userDefaults: defaultsFixture.userDefaults,
            key: "saved",
            lastActiveKey: "active",
            legacyRecentKey: "legacy"
        )
        let first = store.add(URL(fileURLWithPath: "/tmp/Monknot/A", isDirectory: true))
        _ = store.add(URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true))

        let updated = try XCTUnwrap(store.updateLocation(
            id: first.id,
            url: URL(fileURLWithPath: "/tmp/Monknot/B", isDirectory: true),
            bookmarkData: Data([9])
        ))

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.path, "/tmp/Monknot/B")
        XCTAssertEqual(store.entries(), [updated])
    }

    func testLegacyRecentListMigratesOnceWithoutCreatingDuplicateState() throws {
        struct LegacyEntry: Codable {
            let path: String
            let displayName: String
        }

        let defaultsFixture = IsolatedUserDefaults(prefix: "SavedWorkspaceStoreTests")
        let defaults = defaultsFixture.userDefaults
        let legacyEntries = [
            LegacyEntry(path: "/tmp/Monknot/A", displayName: "A"),
            LegacyEntry(path: "/tmp/Monknot/B", displayName: "B")
        ]
        defaults.set(try JSONEncoder().encode(legacyEntries), forKey: SavedWorkspaceStore.legacyRecentKey)

        let store = SavedWorkspaceStore(userDefaults: defaults)
        XCTAssertEqual(store.entries().map(\.path), legacyEntries.map(\.path))
        XCTAssertNil(defaults.data(forKey: SavedWorkspaceStore.legacyRecentKey))
        XCTAssertNotNil(defaults.data(forKey: SavedWorkspaceStore.defaultKey))
    }
}
