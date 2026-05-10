import Foundation

public struct RecentWorkspaceEntry: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var displayName: String

    public init(path: String, displayName: String) {
        self.path = path
        self.displayName = displayName
    }
}

public struct RecentWorkspaceStore {
    public static let defaultKey = "Markprev.recentWorkspaces"

    private let userDefaults: UserDefaults
    private let key: String
    private let limit: Int

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = Self.defaultKey,
        limit: Int = 10
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.limit = max(1, limit)
    }

    public func entries() -> [RecentWorkspaceEntry] {
        guard let data = userDefaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([RecentWorkspaceEntry].self, from: data)
        else {
            return []
        }

        return entries
    }

    public func record(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let entry = RecentWorkspaceEntry(
            path: standardizedURL.path,
            displayName: standardizedURL.lastPathComponent
        )

        let updatedEntries = ([entry] + entries().filter { $0.path != entry.path })
            .prefix(limit)
        save(Array(updatedEntries))
    }

    public func remove(path: String) {
        save(entries().filter { $0.path != path })
    }

    public func clear() {
        userDefaults.removeObject(forKey: key)
    }

    private func save(_ entries: [RecentWorkspaceEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: key)
    }
}
