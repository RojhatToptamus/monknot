import Foundation

public enum WorkspaceReplaceScope: String, CaseIterable, Codable, Sendable {
    case entireWorkspace
    case searchResultsOnly
    case selectedSearchResult

    public var title: String {
        switch self {
        case .entireWorkspace:
            return "All files"
        case .searchResultsOnly:
            return "Search results"
        case .selectedSearchResult:
            return "Selected file"
        }
    }

    public var systemImage: String {
        switch self {
        case .entireWorkspace:
            return "folder"
        case .searchResultsOnly:
            return "list.bullet"
        case .selectedSearchResult:
            return "doc"
        }
    }
}

public struct WorkspaceReplaceUndoSnapshot: Equatable, Sendable {
    public let previousTextsByDocumentID: [String: String]

    public init(previousTextsByDocumentID: [String: String]) {
        self.previousTextsByDocumentID = previousTextsByDocumentID
    }
}
