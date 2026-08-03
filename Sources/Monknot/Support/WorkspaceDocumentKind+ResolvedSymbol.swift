import MonknotCore

extension WorkspaceDocumentKind {
    /// Runtime-resolved SF Symbol (macOS 14+ safe fallbacks).
    var resolvedSystemImage: String {
        switch self {
        case .markdown:
            return MonknotSFSymbol.resolve("doc.text", fallback: systemImage)
        case .pdf:
            return MonknotSFSymbol.resolve("doc.richtext", fallback: systemImage)
        case .text:
            return MonknotSFSymbol.resolve("doc.text", fallback: systemImage)
        case .media:
            return MonknotSFSymbol.resolve("play.rectangle.fill", fallback: systemImage)
        case .nativePreview:
            return MonknotSFSymbol.resolve("doc.viewfinder", fallback: systemImage)
        case .unsupported:
            return systemImage
        }
    }
}

extension EditorMode {
    var resolvedSystemImage: String {
        switch self {
        case .source:
            return MonknotSFSymbol.resolve("text.alignleft", fallback: systemImage)
        case .preview:
            return MonknotSFSymbol.resolve("eye", fallback: systemImage)
        }
    }
}

extension WorkspaceSearchResultKind {
    var resolvedSystemImage: String {
        switch self {
        case .text:
            return MonknotSFSymbol.resolve("doc.text", fallback: systemImage)
        case .pdf:
            return WorkspaceDocumentKind.pdf.resolvedSystemImage
        }
    }
}
