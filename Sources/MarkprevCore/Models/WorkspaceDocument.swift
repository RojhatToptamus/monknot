import Foundation

public enum WorkspaceDocumentKind: String, Codable, Sendable {
    case markdown
    case pdf
    case unsupported
}

public struct WorkspaceDocument: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let relativePath: String
    public let kind: WorkspaceDocumentKind
    public let depth: Int

    public init(url: URL, rootURL: URL) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.id = standardizedURL.path
        self.displayName = standardizedURL.lastPathComponent
        self.relativePath = WorkspaceDocumentSupport.relativePath(for: standardizedURL, in: rootURL)
        self.kind = WorkspaceDocumentSupport.kind(for: standardizedURL) ?? .unsupported
        self.depth = max(0, relativePath.split(separator: "/").count - 1)
    }
}

public enum WorkspaceDocumentSupport {
    public static let markdownExtensions: Set<String> = [
        "md",
        "markdown",
        "mdown",
        "mkd"
    ]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let supportedExtensions = markdownExtensions.union(pdfExtensions)

    public static func kind(for url: URL) -> WorkspaceDocumentKind? {
        let fileExtension = url.pathExtension.lowercased()
        if markdownExtensions.contains(fileExtension) {
            return .markdown
        }

        if pdfExtensions.contains(fileExtension) {
            return .pdf
        }

        return nil
    }

    public static func isWorkspaceDocument(_ url: URL) -> Bool {
        kind(for: url) != nil
    }

    public static func isMarkdownDocument(_ url: URL) -> Bool {
        kind(for: url) == .markdown
    }

    public static func isPDFDocument(_ url: URL) -> Bool {
        kind(for: url) == .pdf
    }

    public static func relativePath(for url: URL, in rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return url.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }
}
