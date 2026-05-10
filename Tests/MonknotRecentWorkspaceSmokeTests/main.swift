import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MonknotRecentWorkspaceSmokeTests {
    static func main() throws {
        let suiteName = "MonknotRecentWorkspaceSmokeTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL: could not create isolated defaults suite\n", stderr)
            exit(1)
        }
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let store = RecentWorkspaceStore(userDefaults: userDefaults, key: "recents", limit: 2)
        let first = URL(fileURLWithPath: "/tmp/Monknot/First", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/Second", isDirectory: true)
        let third = URL(fileURLWithPath: "/tmp/Monknot/Third", isDirectory: true)

        store.record(first)
        store.record(second)
        store.record(first)
        expect(
            store.entries() == [
                RecentWorkspaceEntry(path: first.path, displayName: "First"),
                RecentWorkspaceEntry(path: second.path, displayName: "Second")
            ],
            "recent workspace store should move duplicate entries to the front"
        )

        store.record(third)
        expect(
            store.entries() == [
                RecentWorkspaceEntry(path: third.path, displayName: "Third"),
                RecentWorkspaceEntry(path: first.path, displayName: "First")
            ],
            "recent workspace store should keep only the configured number of entries"
        )

        store.remove(path: third.path)
        expect(
            store.entries() == [
                RecentWorkspaceEntry(path: first.path, displayName: "First")
            ],
            "recent workspace store should remove stale entries by path"
        )

        print("Monknot recent workspace smoke tests passed")
    }
}
