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

/// What undoing a workspace Replace puts back: each file's text before the replace, written only
/// while the file still holds the text the replace wrote.
public struct WorkspaceReplaceUndoSnapshot: Equatable, Sendable {
    public let previousTextsByDocumentID: [String: String]
    public let replacedTextsByDocumentID: [String: String]

    public init(previousTextsByDocumentID: [String: String], replacedTextsByDocumentID: [String: String]) {
        self.previousTextsByDocumentID = previousTextsByDocumentID
        self.replacedTextsByDocumentID = replacedTextsByDocumentID
    }
}
