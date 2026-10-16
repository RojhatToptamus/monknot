import Foundation

public struct SidebarNode: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder
        case file
    }

    public let id: String
    public let url: URL
    public let name: String
    public let relativePath: String
    public let kind: Kind
    public let document: WorkspaceDocument?
    public let children: [SidebarNode]?

    public init(
        id: String,
        url: URL,
        name: String,
        relativePath: String,
        kind: Kind,
        document: WorkspaceDocument? = nil,
        children: [SidebarNode]? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.document = document
        self.children = children
    }

    public var isFile: Bool {
        kind == .file
    }

    /// The node with `id` in this subtree. Node IDs are standardized paths, so the search descends
    /// only into the folder whose path leads to `id`.
    public func node(withID id: String) -> SidebarNode? {
        if self.id == id {
            return self
        }
        let prefix = self.id.hasSuffix("/") ? self.id : self.id + "/"
        guard let children, id.hasPrefix(prefix) else { return nil }
        for child in children where child.id == id || id.hasPrefix(child.id + "/") {
            if let found = child.node(withID: id) {
                return found
            }
        }
        return nil
    }
}
