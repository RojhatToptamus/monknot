import Foundation
import MonknotCore

enum WorkspaceLibraryError: LocalizedError {
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let name):
            return "The folder for \(name) could not be found."
        }
    }
}

/// App-wide observable access to the one persisted saved-workspace registry.
@MainActor
final class WorkspaceLibraryStore: ObservableObject {
    @Published private(set) var entries: [SavedWorkspaceEntry]

    private let persistence: SavedWorkspaceStore
    private let userDefaults: UserDefaults
    private let legacyBookmarkKey: String

    init(
        userDefaults: UserDefaults = .standard,
        persistence: SavedWorkspaceStore? = nil,
        legacyBookmarkKey: String = "Monknot.workspaceBookmark"
    ) {
        self.userDefaults = userDefaults
        self.persistence = persistence ?? SavedWorkspaceStore(userDefaults: userDefaults)
        self.legacyBookmarkKey = legacyBookmarkKey
        entries = self.persistence.entries()
        importLegacyActiveWorkspaceIfNeeded()
    }

    @discardableResult
    func add(_ url: URL) -> SavedWorkspaceEntry {
        let standardizedURL = url.standardizedFileURL
        let entry = persistence.add(
            standardizedURL,
            bookmarkData: makeBookmark(for: standardizedURL)
        )
        reload()
        return entry
    }

    func entry(matching url: URL?) -> SavedWorkspaceEntry? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        return entries.first { $0.path == path }
    }

    func resolveURL(for entry: SavedWorkspaceEntry) throws -> URL {
        if let bookmarkData = entry.bookmarkData {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ).standardizedFileURL

                if isDirectory(resolvedURL) {
                    if isStale || resolvedURL.path != entry.path {
                        _ = persistence.updateLocation(
                            id: entry.id,
                            url: resolvedURL,
                            bookmarkData: makeBookmark(for: resolvedURL)
                        )
                        reload()
                    }
                    return resolvedURL
                }
            } catch {
                // A plain path remains a valid fallback for this non-sandboxed distribution.
            }
        }

        let pathURL = URL(fileURLWithPath: entry.path, isDirectory: true).standardizedFileURL
        guard isDirectory(pathURL) else {
            throw WorkspaceLibraryError.folderUnavailable(entry.displayName)
        }

        if entry.bookmarkData == nil {
            _ = persistence.updateLocation(
                id: entry.id,
                url: pathURL,
                bookmarkData: makeBookmark(for: pathURL)
            )
            reload()
        }
        return pathURL
    }

    func lastActiveWorkspaceURL() throws -> URL? {
        guard let entry = persistence.lastActiveWorkspace() else { return nil }
        return try resolveURL(for: entry)
    }

    func markActive(_ url: URL) {
        let entry = entry(matching: url) ?? add(url)
        persistence.markActive(id: entry.id)
    }

    @discardableResult
    func relocate(id: UUID, to url: URL) -> SavedWorkspaceEntry? {
        let updated = persistence.updateLocation(
            id: id,
            url: url.standardizedFileURL,
            bookmarkData: makeBookmark(for: url.standardizedFileURL)
        )
        reload()
        return updated
    }

    func rename(id: UUID, to name: String) {
        persistence.rename(id: id, to: name)
        reload()
    }

    func move(id: UUID, to destinationIndex: Int) {
        persistence.move(id: id, to: destinationIndex)
        reload()
    }

    @discardableResult
    func remove(id: UUID) -> SavedWorkspaceRemoval? {
        let removal = persistence.remove(id: id)
        reload()
        return removal
    }

    func restore(_ removal: SavedWorkspaceRemoval) {
        persistence.restore(removal)
        reload()
    }

    func replaceEntries(_ entries: [SavedWorkspaceEntry]) {
        persistence.replaceEntries(entries)
        reload()
    }

    private func reload() {
        let updated = persistence.entries()
        guard updated != entries else { return }
        entries = updated
    }

    private func importLegacyActiveWorkspaceIfNeeded() {
        guard let bookmarkData = userDefaults.data(forKey: legacyBookmarkKey) else { return }
        defer { userDefaults.removeObject(forKey: legacyBookmarkKey) }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            guard isDirectory(url) else { return }

            let entry = persistence.add(
                url,
                bookmarkData: isStale ? makeBookmark(for: url) : bookmarkData
            )
            persistence.markActive(id: entry.id)
            entries = persistence.entries()
        } catch {
            return
        }
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
