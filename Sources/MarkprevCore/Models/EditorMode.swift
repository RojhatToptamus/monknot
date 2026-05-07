import Foundation

public enum EditorMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case source
    case preview

    public var id: String { rawValue }
}
