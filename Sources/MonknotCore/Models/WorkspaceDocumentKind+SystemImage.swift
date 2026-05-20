import Foundation

extension WorkspaceDocumentKind {
    /// SF Symbol for sidebar rows, tabs, and search results.
    /// Names are chosen for macOS 14+ availability (no SF Symbols 5+‑only glyphs).
    public var systemImage: String {
        switch self {
        case .markdown:
            return "doc.text.fill"
        case .pdf:
            return "doc.fill"
        case .text:
            return "doc.text"
        case .media:
            return "play.rectangle.fill"
        case .nativePreview:
            return "doc.viewfinder"
        case .unsupported:
            return "doc"
        }
    }
}

extension EditorMode {
    /// SF Symbol for the markdown source / preview toggle.
    public var systemImage: String {
        switch self {
        case .source:
            return "text.alignleft"
        case .preview:
            return "eye"
        }
    }
}
