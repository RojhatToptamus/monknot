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
    public let file: MarkdownFile?
    public let children: [SidebarNode]?

    public init(
        id: String,
        url: URL,
        name: String,
        relativePath: String,
        kind: Kind,
        file: MarkdownFile? = nil,
        children: [SidebarNode]? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.file = file
        self.children = children
    }

    public var isFile: Bool {
        kind == .file
    }
}
