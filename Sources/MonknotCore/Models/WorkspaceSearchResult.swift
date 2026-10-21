import Foundation

public enum WorkspaceSearchResultKind: String, Codable, Hashable, Sendable {
    case text
    case pdf
}

public struct WorkspaceSearchPDFTarget: Hashable, Sendable {
    public let page: Int
    public let matchIndex: Int

    public init(page: Int, matchIndex: Int) {
        self.page = page
        self.matchIndex = matchIndex
    }
}

public struct WorkspaceSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let documentID: String
    public let relativePath: String
    public let displayName: String
    public let kind: WorkspaceSearchResultKind
    public let line: Int
    public let column: Int
    public let preview: String
    public let pdfTarget: WorkspaceSearchPDFTarget?

    public var locationLabel: String {
        switch kind {
        case .text:
            return ":\(line)"
        case .pdf:
            return "p\(line)"
        }
    }

    public init(
        id: String,
        documentID: String,
        relativePath: String,
        displayName: String,
        kind: WorkspaceSearchResultKind = .text,
        line: Int,
        column: Int,
        preview: String,
        pdfTarget: WorkspaceSearchPDFTarget? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.relativePath = relativePath
        self.displayName = displayName
        self.kind = kind
        self.line = line
        self.column = column
        self.preview = preview
        self.pdfTarget = pdfTarget
    }
}
