import Foundation

public struct WorkspaceTreeExpansionPersistence {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "Monknot.workspaceTreeExpansion"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(for workspaceURL: URL) -> Set<String>? {
        guard let data = defaults.data(forKey: key(for: workspaceURL)),
              let paths = try? decoder.decode([String].self, from: data)
        else {
            return nil
        }
        return Set(paths)
    }

    public func save(_ expandedFolderIDs: Set<String>, for workspaceURL: URL) {
        guard let data = try? encoder.encode(expandedFolderIDs.sorted()) else { return }
        let storageKey = key(for: workspaceURL)
        guard defaults.data(forKey: storageKey) != data else { return }
        defaults.set(data, forKey: storageKey)
    }

    public func key(for workspaceURL: URL) -> String {
        let pathData = Data(workspaceURL.standardizedFileURL.path.utf8)
        return "\(keyPrefix).\(pathData.base64EncodedString())"
    }
}
