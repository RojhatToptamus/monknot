import Foundation

public struct MarkdownIncomingLink: Identifiable, Equatable, Sendable {
    public let sourceDocumentID: String
    public let sourceRelativePath: String
    public let label: String
    public let location: MarkdownSourceLocation
    public let column: Int

    public var id: String {
        "\(sourceDocumentID):\(location.line):\(location.offset):\(label)"
    }

    public init(
        sourceDocumentID: String,
        sourceRelativePath: String,
        label: String,
        location: MarkdownSourceLocation,
        column: Int
    ) {
        self.sourceDocumentID = sourceDocumentID
        self.sourceRelativePath = sourceRelativePath
        self.label = label
        self.location = location
        self.column = column
    }
}

public enum MarkdownOutgoingLinkIssueKind: String, Equatable, Sendable {
    case missing
    case ambiguous
}

public struct MarkdownOutgoingLinkIssue: Identifiable, Equatable, Sendable {
    public let kind: MarkdownOutgoingLinkIssueKind
    public let label: String
    public let location: MarkdownSourceLocation
    public let column: Int
    public let candidateDocumentIDs: [String]

    public var id: String {
        "\(location.line):\(location.offset):\(label):\(kind.rawValue)"
    }

    public init(
        kind: MarkdownOutgoingLinkIssueKind,
        label: String,
        location: MarkdownSourceLocation,
        column: Int,
        candidateDocumentIDs: [String] = []
    ) {
        self.kind = kind
        self.label = label
        self.location = location
        self.column = column
        self.candidateDocumentIDs = candidateDocumentIDs
    }
}

public struct MarkdownLinkInspection: Equatable, Sendable {
    public let documentID: String
    public let incomingLinks: [MarkdownIncomingLink]
    public let outgoingIssues: [MarkdownOutgoingLinkIssue]
    public let skippedDocumentCount: Int

    public init(
        documentID: String,
        incomingLinks: [MarkdownIncomingLink],
        outgoingIssues: [MarkdownOutgoingLinkIssue],
        skippedDocumentCount: Int
    ) {
        self.documentID = documentID
        self.incomingLinks = incomingLinks
        self.outgoingIssues = outgoingIssues
        self.skippedDocumentCount = skippedDocumentCount
    }
}

public struct MarkdownLinkInspectionService: Sendable {
    public let maxFileBytes: Int64
    public let textCache: WorkspaceTextContentCache

    public init(
        maxFileBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes,
        textCache: WorkspaceTextContentCache = .shared
    ) {
        self.maxFileBytes = maxFileBytes
        self.textCache = textCache
    }

    public func inspect(
        document: WorkspaceDocument,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument],
        textByDocumentID: [String: String] = [:]
    ) throws -> MarkdownLinkInspection {
        try Task.checkCancellation()
        guard document.kind == .markdown,
              documents.contains(where: { $0.id == document.id })
        else {
            return MarkdownLinkInspection(
                documentID: document.id,
                incomingLinks: [],
                outgoingIssues: [],
                skippedDocumentCount: 0
            )
        }

        let parser = MarkdownWorkspaceLinkParser()
        let resolver = MarkdownWorkspaceLinkResolver()
        let activeText = try text(
            for: document,
            override: textByDocumentID[document.id]
        )
        let outgoingIssues: [MarkdownOutgoingLinkIssue] = try parser.links(in: activeText).compactMap { link in
            try Task.checkCancellation()
            guard Self.isNavigable(link) else { return nil }
            let position = Self.position(forUTF16Offset: link.sourceRange.location, in: activeText)
            switch resolver.resolve(
                link,
                sourceDocument: document,
                workspaceRootURL: workspaceRootURL,
                documents: documents
            ) {
            case .missing:
                return MarkdownOutgoingLinkIssue(
                    kind: .missing,
                    label: link.label,
                    location: position.location,
                    column: position.column
                )
            case .ambiguous(let documentIDs):
                return MarkdownOutgoingLinkIssue(
                    kind: .ambiguous,
                    label: link.label,
                    location: position.location,
                    column: position.column,
                    candidateDocumentIDs: documentIDs
                )
            case .invalid:
                return MarkdownOutgoingLinkIssue(
                    kind: .missing,
                    label: link.label,
                    location: position.location,
                    column: position.column
                )
            case .document, .external:
                return nil
            }
        }

        var incomingLinks: [MarkdownIncomingLink] = []
        var skippedDocumentCount = 0
        for sourceDocument in documents where sourceDocument.kind == .markdown && sourceDocument.id != document.id {
            try Task.checkCancellation()
            let sourceText: String
            do {
                sourceText = try text(
                    for: sourceDocument,
                    override: textByDocumentID[sourceDocument.id]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedDocumentCount += 1
                continue
            }

            for link in parser.links(in: sourceText) where Self.isNavigable(link) {
                try Task.checkCancellation()
                guard case .document(let targetID, _) = resolver.resolve(
                    link,
                    sourceDocument: sourceDocument,
                    workspaceRootURL: workspaceRootURL,
                    documents: documents
                ), targetID == document.id else {
                    continue
                }
                let position = Self.position(forUTF16Offset: link.sourceRange.location, in: sourceText)
                incomingLinks.append(MarkdownIncomingLink(
                    sourceDocumentID: sourceDocument.id,
                    sourceRelativePath: sourceDocument.relativePath,
                    label: link.label,
                    location: position.location,
                    column: position.column
                ))
            }
        }

        try Task.checkCancellation()
        incomingLinks.sort {
            if $0.sourceRelativePath == $1.sourceRelativePath {
                if $0.location.line == $1.location.line {
                    return $0.column < $1.column
                }
                return $0.location.line < $1.location.line
            }
            return $0.sourceRelativePath.localizedStandardCompare($1.sourceRelativePath) == .orderedAscending
        }
        return MarkdownLinkInspection(
            documentID: document.id,
            incomingLinks: incomingLinks,
            outgoingIssues: outgoingIssues,
            skippedDocumentCount: skippedDocumentCount
        )
    }

    private func text(for document: WorkspaceDocument, override: String?) throws -> String {
        if let override {
            return override
        }
        return try WorkspaceTextFileGuard.readUTF8Text(
            from: document.url,
            maxBytes: maxFileBytes,
            cache: textCache
        )
    }

    private static func isNavigable(_ link: MarkdownWorkspaceLink) -> Bool {
        link.kind == .markdown || link.kind == .wikilink || link.kind == .referenceUsage
    }

    private static func position(
        forUTF16Offset offset: Int,
        in text: String
    ) -> (location: MarkdownSourceLocation, column: Int) {
        let source = text as NSString
        let clampedOffset = min(max(offset, 0), source.length)
        var line = 1
        var lineStart = 0
        while lineStart < clampedOffset {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let nextLineStart = NSMaxRange(lineRange)
            guard nextLineStart > lineStart, nextLineStart <= clampedOffset else { break }
            lineStart = nextLineStart
            line += 1
        }
        let prefix = source.substring(
            with: NSRange(location: lineStart, length: clampedOffset - lineStart)
        )
        return (
            MarkdownSourceLocation(line: line, offset: clampedOffset - lineStart),
            prefix.count + 1
        )
    }
}
