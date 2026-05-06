import Foundation

public enum EditorMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case source
    case preview

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source:
            return "Source"
        case .preview:
            return "Preview"
        }
    }
}
