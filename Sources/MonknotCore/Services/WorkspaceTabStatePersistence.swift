import Foundation

public struct WorkspaceTabStatePersistence {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "Monknot.workspaceTabState"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(for workspaceURL: URL) -> WorkspaceTabState? {
        guard let data = defaults.data(forKey: key(for: workspaceURL)) else {
            return nil
        }

        return try? decoder.decode(WorkspaceTabState.self, from: data)
    }

    public func save(_ state: WorkspaceTabState, for workspaceURL: URL) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: key(for: workspaceURL))
    }

    public func remove(for workspaceURL: URL) {
        defaults.removeObject(forKey: key(for: workspaceURL))
    }

    public func key(for workspaceURL: URL) -> String {
        let pathData = Data(workspaceURL.standardizedFileURL.path.utf8)
        let pathToken = pathData.base64EncodedString()
        return "\(keyPrefix).\(pathToken)"
    }
}
