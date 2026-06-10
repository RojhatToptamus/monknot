import Foundation

public struct WorkspaceSearchPrewarmService: Sendable {
    public let maxTextDocuments: Int
    public let maxPDFDocuments: Int
    public let maxTextFileBytes: Int64
    public let textIndex: WorkspaceSearchIndex
    public let pdfIndex: WorkspacePDFSearchIndex

    public init(
        maxTextDocuments: Int = 128,
        maxPDFDocuments: Int = 0,
        maxTextFileBytes: Int64 = 2 * 1024 * 1024,
        textIndex: WorkspaceSearchIndex = .shared,
        pdfIndex: WorkspacePDFSearchIndex = .shared
    ) {
        self.maxTextDocuments = max(0, maxTextDocuments)
        self.maxPDFDocuments = max(0, maxPDFDocuments)
        self.maxTextFileBytes = maxTextFileBytes
        self.textIndex = textIndex
        self.pdfIndex = pdfIndex
    }

    public func prewarm(documents: [WorkspaceDocument]) throws {
        guard maxTextDocuments > 0 || maxPDFDocuments > 0 else { return }

        var warmedTextCount = 0
        var warmedPDFCount = 0

        for document in documents {
            try Task.checkCancellation()

            switch document.kind {
            case .markdown, .text:
                guard warmedTextCount < maxTextDocuments else { continue }
                _ = try textIndex.update(document: document, maxBytes: maxTextFileBytes)
                warmedTextCount += 1
            case .pdf:
                guard warmedPDFCount < maxPDFDocuments else { continue }
                _ = try pdfIndex.update(document: document)
                warmedPDFCount += 1
            case .media, .nativePreview, .unsupported:
                continue
            }

            if warmedTextCount >= maxTextDocuments, warmedPDFCount >= maxPDFDocuments {
                return
            }
        }
    }
}
