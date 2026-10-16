import Foundation

public struct RecentDocumentEntry: Codable, Equatable, Hashable, Sendable {
    public var documentID: String
    public var relativePath: String
    public var displayName: String

    public init(documentID: String, relativePath: String, displayName: String) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.displayName = displayName
    }

    public init(document: WorkspaceDocument) {
        documentID = document.id
        relativePath = document.relativePath
        displayName = document.displayName
    }
}

public struct RecentDocumentStore {
    public static let keyPrefix = "Monknot.recentDocuments."

    private let userDefaults: UserDefaults
    private let limit: Int

    public init(userDefaults: UserDefaults = .standard, limit: Int = 8) {
        self.userDefaults = userDefaults
        self.limit = max(1, limit)
    }

    public func entries(for workspaceURL: URL) -> [RecentDocumentEntry] {
        let key = storageKey(for: workspaceURL)
        guard let data = userDefaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([RecentDocumentEntry].self, from: data)
        else {
            return []
        }

        return entries
    }

    public func record(_ document: WorkspaceDocument, workspaceURL: URL) {
        let entry = RecentDocumentEntry(document: document)
        let key = storageKey(for: workspaceURL)
        let currentEntries = entries(for: workspaceURL)
        guard currentEntries.first != entry else { return }
        let updatedEntries = ([entry] + currentEntries.filter { $0.documentID != entry.documentID })
            .prefix(limit)
        save(Array(updatedEntries), key: key)
    }

    /// Points the entries of renamed or moved documents at their new location, keeping their place
    /// in the list. `movedDocuments` maps an old document ID to the document now at its new path.
    /// Returns whether any entry changed.
    @discardableResult
    public func remap(_ movedDocuments: [String: WorkspaceDocument], workspaceURL: URL) -> Bool {
        let currentEntries = entries(for: workspaceURL)
        let updatedEntries = currentEntries.map { entry in
            movedDocuments[entry.documentID].map(RecentDocumentEntry.init(document:)) ?? entry
        }
        guard updatedEntries != currentEntries else { return false }
        save(updatedEntries, key: storageKey(for: workspaceURL))
        return true
    }

    public func remove(documentID: String, workspaceURL: URL) {
        let key = storageKey(for: workspaceURL)
        save(entries(for: workspaceURL).filter { $0.documentID != documentID }, key: key)
    }

    public func storageKey(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }

    private func save(_ entries: [RecentDocumentEntry], key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: key)
    }
}
