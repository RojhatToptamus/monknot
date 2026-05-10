import Foundation

public struct MarkdownOutlineItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let level: Int
    public let location: MarkdownSourceLocation

    public init(id: String, title: String, level: Int, location: MarkdownSourceLocation) {
        self.id = id
        self.title = title
        self.level = level
        self.location = location
    }
}
