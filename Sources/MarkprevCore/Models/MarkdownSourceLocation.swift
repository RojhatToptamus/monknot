import Foundation

public struct MarkdownSourceLocation: Equatable, Sendable {
    public let line: Int
    public let offset: Int

    public init(line: Int, offset: Int) {
        self.line = line
        self.offset = offset
    }
}
