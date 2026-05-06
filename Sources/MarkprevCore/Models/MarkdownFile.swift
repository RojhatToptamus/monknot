import Foundation

public struct MarkdownFile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let relativePath: String
    public let depth: Int

    public init(url: URL, rootURL: URL) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.id = standardizedURL.path
        self.displayName = standardizedURL.lastPathComponent
        self.relativePath = MarkdownFileSupport.relativePath(for: standardizedURL, in: rootURL)
        self.depth = max(0, relativePath.split(separator: "/").count - 1)
    }
}

public enum MarkdownFileSupport {
    public static let supportedExtensions: Set<String> = [
        "md",
        "markdown",
        "mdown",
        "mkd"
    ]

    public static func isMarkdownFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
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
