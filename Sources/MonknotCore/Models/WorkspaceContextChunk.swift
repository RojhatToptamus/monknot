import Foundation

public struct WorkspaceContextChunk: Identifiable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let startLine: Int
    public let endLine: Int
    public let text: String

    public init(relativePath: String, startLine: Int, endLine: Int, text: String) {
        self.id = "\(relativePath):\(startLine)-\(endLine)"
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }

    public var citationLabel: String {
        if startLine == endLine {
            return "\(relativePath):\(startLine)"
        }
        return "\(relativePath):\(startLine)-\(endLine)"
    }
}
