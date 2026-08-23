import Foundation

public struct SavedWorkspaceEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var path: String
    public var customName: String?
    public var bookmarkData: Data?

    public init(
        id: UUID = UUID(),
        path: String,
        customName: String? = nil,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        self.customName = Self.normalizedCustomName(customName)
        self.bookmarkData = bookmarkData
    }

    public var displayName: String {
        customName ?? URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    fileprivate static func normalizedCustomName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

public struct SavedWorkspaceRemoval: Equatable, Sendable {
    public let entry: SavedWorkspaceEntry
    public let index: Int
    public let wasLastActive: Bool

    public init(entry: SavedWorkspaceEntry, index: Int, wasLastActive: Bool) {
        self.entry = entry
        self.index = index
        self.wasLastActive = wasLastActive
    }
}

/// The single persisted owner for the user's ordered workspace list.
/// Bookmark data stays opaque here; the app layer creates and resolves it with Foundation.
public struct SavedWorkspaceStore {
    public static let defaultKey = "Monknot.savedWorkspaces"
    public static let defaultLastActiveKey = "Monknot.lastActiveWorkspaceID"
    public static let legacyRecentKey = "Monknot.recentWorkspaces"

    private struct LegacyRecentWorkspaceEntry: Codable {
        let path: String
        let displayName: String
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let lastActiveKey: String
    private let legacyRecentKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = Self.defaultKey,
        lastActiveKey: String = Self.defaultLastActiveKey,
        legacyRecentKey: String = Self.legacyRecentKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.lastActiveKey = lastActiveKey
        self.legacyRecentKey = legacyRecentKey
    }

    public func entries() -> [SavedWorkspaceEntry] {
        if let data = userDefaults.data(forKey: key),
           let entries = try? decoder.decode([SavedWorkspaceEntry].self, from: data) {
            return entries
        }

        guard key == Self.defaultKey,
              let legacyData = userDefaults.data(forKey: legacyRecentKey),
              let legacyEntries = try? decoder.decode([LegacyRecentWorkspaceEntry].self, from: legacyData)
        else {
            return []
        }

        // The old list was most-recent-first. Preserve its visible order during the one-time migration.
        let migrated = legacyEntries.map {
            SavedWorkspaceEntry(path: $0.path, customName: nil, bookmarkData: nil)
        }
        save(migrated)
        userDefaults.removeObject(forKey: legacyRecentKey)
        return migrated
    }

    public func entry(id: UUID) -> SavedWorkspaceEntry? {
        entries().first { $0.id == id }
    }

    public func entry(matching url: URL) -> SavedWorkspaceEntry? {
        let path = url.standardizedFileURL.path
        return entries().first { $0.path == path }
    }

    @discardableResult
    public func add(_ url: URL, bookmarkData: Data? = nil) -> SavedWorkspaceEntry {
        let path = url.standardizedFileURL.path
        var stored = entries()

        if let index = stored.firstIndex(where: { $0.path == path }) {
            if let bookmarkData {
                stored[index].bookmarkData = bookmarkData
                save(stored)
            }
            return stored[index]
        }

        let entry = SavedWorkspaceEntry(path: path, bookmarkData: bookmarkData)
        stored.append(entry)
        save(stored)
        return entry
    }

    @discardableResult
    public func updateLocation(
        id: UUID,
        url: URL,
        bookmarkData: Data?
    ) -> SavedWorkspaceEntry? {
        var stored = entries()
        guard let currentIndex = stored.firstIndex(where: { $0.id == id }) else { return nil }

        let path = url.standardizedFileURL.path
        let entry = SavedWorkspaceEntry(
            id: stored[currentIndex].id,
            path: path,
            customName: stored[currentIndex].customName,
            bookmarkData: bookmarkData ?? stored[currentIndex].bookmarkData
        )

        stored.remove(at: currentIndex)
        stored.removeAll { $0.path == path }
        stored.insert(entry, at: min(currentIndex, stored.count))
        save(stored)
        return entry
    }

    public func rename(id: UUID, to name: String) {
        var stored = entries()
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }

        let normalized = SavedWorkspaceEntry.normalizedCustomName(name)
        let folderName = URL(fileURLWithPath: stored[index].path, isDirectory: true).lastPathComponent
        stored[index].customName = normalized == folderName ? nil : normalized
        save(stored)
    }

    public func move(id: UUID, to destinationIndex: Int) {
        var stored = entries()
        guard let sourceIndex = stored.firstIndex(where: { $0.id == id }), !stored.isEmpty else { return }

        let entry = stored.remove(at: sourceIndex)
        let clampedIndex = min(max(0, destinationIndex), stored.count)
        stored.insert(entry, at: clampedIndex)
        save(stored)
    }

    @discardableResult
    public func remove(id: UUID) -> SavedWorkspaceRemoval? {
        var stored = entries()
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }

        let entry = stored.remove(at: index)
        let wasLastActive = lastActiveWorkspaceID() == id
        save(stored)
        if wasLastActive {
            userDefaults.removeObject(forKey: lastActiveKey)
        }
        return SavedWorkspaceRemoval(entry: entry, index: index, wasLastActive: wasLastActive)
    }

    public func restore(_ removal: SavedWorkspaceRemoval) {
        var stored = entries().filter { $0.id != removal.entry.id && $0.path != removal.entry.path }
        stored.insert(removal.entry, at: min(max(0, removal.index), stored.count))
        save(stored)
        if removal.wasLastActive {
            markActive(id: removal.entry.id)
        }
    }

    public func replaceEntries(_ entries: [SavedWorkspaceEntry]) {
        var seenPaths: Set<String> = []
        let normalized = entries.filter { seenPaths.insert($0.path).inserted }
        save(normalized)
        if let activeID = lastActiveWorkspaceID(), !normalized.contains(where: { $0.id == activeID }) {
            userDefaults.removeObject(forKey: lastActiveKey)
        }
    }

    public func markActive(id: UUID) {
        guard entries().contains(where: { $0.id == id }) else { return }
        userDefaults.set(id.uuidString, forKey: lastActiveKey)
    }

    public func lastActiveWorkspaceID() -> UUID? {
        guard let value = userDefaults.string(forKey: lastActiveKey) else { return nil }
        return UUID(uuidString: value)
    }

    public func lastActiveWorkspace() -> SavedWorkspaceEntry? {
        guard let id = lastActiveWorkspaceID() else { return nil }
        return entry(id: id)
    }

    public func clear() {
        userDefaults.removeObject(forKey: key)
        userDefaults.removeObject(forKey: lastActiveKey)
    }

    private func save(_ entries: [SavedWorkspaceEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        guard userDefaults.data(forKey: key) != data else { return }
        userDefaults.set(data, forKey: key)
    }
}
