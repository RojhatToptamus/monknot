import Foundation
import OSLog

public struct WorkspaceSearchBatch: Sendable {
    public let results: [WorkspaceSearchResult]
    public let skippedLargeFileCount: Int

    public init(results: [WorkspaceSearchResult], skippedLargeFileCount: Int = 0) {
        self.results = results
        self.skippedLargeFileCount = skippedLargeFileCount
    }
}

public struct WorkspaceSearchService: Sendable {
    public let maxMatches: Int
    public let maxMatchesPerFile: Int
    public let maxTextFileBytes: Int64
    public let maxAutoIndexedTextBytes: Int64
    public let textCache: WorkspaceTextContentCache
    public let textIndex: WorkspaceSearchIndex
    public let pdfCache: WorkspacePDFTextCache
    public let pdfIndex: WorkspacePDFSearchIndex

    public init(
        maxMatches: Int = 500,
        maxMatchesPerFile: Int = 50,
        maxTextFileBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes,
        maxAutoIndexedTextBytes: Int64 = 16 * 1_024 * 1_024,
        textCache: WorkspaceTextContentCache = .shared,
        textIndex: WorkspaceSearchIndex? = nil,
        pdfCache: WorkspacePDFTextCache = .shared,
        pdfIndex: WorkspacePDFSearchIndex? = nil
    ) {
        self.maxMatches = maxMatches
        self.maxMatchesPerFile = maxMatchesPerFile
        self.maxTextFileBytes = maxTextFileBytes
        self.maxAutoIndexedTextBytes = max(0, maxAutoIndexedTextBytes)
        self.textCache = textCache
        self.textIndex = textIndex ?? (textCache === WorkspaceTextContentCache.shared
            ? .shared
            : WorkspaceSearchIndex(textCache: textCache))
        self.pdfCache = pdfCache
        self.pdfIndex = pdfIndex ?? (pdfCache === WorkspacePDFTextCache.shared
            ? .shared
            : WorkspacePDFSearchIndex(pdfCache: pdfCache))
    }

    public func search(
        query: String,
        documents: [WorkspaceDocument],
        dirtyTextByDocumentID: [String: String] = [:],
        dirtyPDFDataByDocumentID: [String: Data] = [:]
    ) throws -> WorkspaceSearchBatch {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return WorkspaceSearchBatch(results: []) }
        let foldedNeedle = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        let signpostID = MonknotSignposting.workspaceSearch.beginInterval("WorkspaceSearch")
        defer { MonknotSignposting.workspaceSearch.endInterval("WorkspaceSearch", signpostID) }

        var results: [WorkspaceSearchResult] = []
        var skippedLargeFileCount = 0
        var remainingAutoIndexedTextBytes = maxAutoIndexedTextBytes
        var remainingAutoIndexedTextDocuments = textIndex.maxEntryCount
        for document in documents {
            try Task.checkCancellation()

            let matches: [WorkspaceSearchResult]
            switch document.kind {
            case .markdown, .text:
                if let dirtyText = dirtyTextByDocumentID[document.id] {
                    matches = try textMatches(
                        foldedNeedle: foldedNeedle,
                        document: document,
                        text: dirtyText,
                        limit: maxMatchesPerFile
                    ).results
                    break
                }

                let isIndexed = textIndex.hasIndexedDocument(document.id)
                let fileSize = Self.fileSize(for: document.url)
                let canAutoIndex = !isIndexed
                    && remainingAutoIndexedTextDocuments > 0
                    && fileSize.map { $0 <= remainingAutoIndexedTextBytes } == true
                if isIndexed || canAutoIndex {
                    remainingAutoIndexedTextDocuments -= 1
                    remainingAutoIndexedTextBytes = max(0, remainingAutoIndexedTextBytes - (fileSize ?? 0))
                }

                let batch = try isIndexed || canAutoIndex
                    ? textIndex.matches(
                        foldedNeedle: foldedNeedle,
                        document: document,
                        limit: maxMatchesPerFile,
                        maxBytes: maxTextFileBytes
                    )
                    : uncachedTextMatches(
                        foldedNeedle: foldedNeedle,
                        document: document,
                        limit: maxMatchesPerFile
                    )
                skippedLargeFileCount += batch.skippedLargeFileCount
                matches = batch.results
            case .pdf:
                matches = try pdfMatches(
                    foldedNeedle: foldedNeedle,
                    document: document,
                    limit: maxMatchesPerFile,
                    pdfData: dirtyPDFDataByDocumentID[document.id]
                )
            case .media, .nativePreview, .unsupported:
                continue
            }

            results.append(contentsOf: matches)
            if results.count >= maxMatches {
                return WorkspaceSearchBatch(
                    results: Array(results.prefix(maxMatches)),
                    skippedLargeFileCount: skippedLargeFileCount
                )
            }
        }

        return WorkspaceSearchBatch(results: results, skippedLargeFileCount: skippedLargeFileCount)
    }

    private func uncachedTextMatches(
        foldedNeedle: String,
        document: WorkspaceDocument,
        limit: Int
    ) throws -> WorkspaceSearchIndex.DocumentMatchBatch {
        guard limit > 0 else {
            return WorkspaceSearchIndex.DocumentMatchBatch(results: [], skippedLargeFileCount: 0)
        }

        let text: String
        do {
            text = try WorkspaceTextFileGuard.readUTF8Text(
                from: document.url,
                maxBytes: maxTextFileBytes,
                cache: textCache
            )
        } catch WorkspaceTextFileGuard.Error.fileTooLarge {
            return WorkspaceSearchIndex.DocumentMatchBatch(results: [], skippedLargeFileCount: 1)
        }

        return try textMatches(
            foldedNeedle: foldedNeedle,
            document: document,
            text: text,
            limit: limit
        )
    }

    private func textMatches(
        foldedNeedle: String,
        document: WorkspaceDocument,
        text: String,
        limit: Int
    ) throws -> WorkspaceSearchIndex.DocumentMatchBatch {
        guard limit > 0 else {
            return WorkspaceSearchIndex.DocumentMatchBatch(results: [], skippedLargeFileCount: 0)
        }

        var results: [WorkspaceSearchResult] = []
        let nsNeedle = foldedNeedle as NSString
        var lineNumber = 1
        var cancelled = false

        text.enumerateLines { line, stop in
            if Task.isCancelled {
                cancelled = true
                stop = true
                return
            }

            let foldedLine = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let nsLine = foldedLine as NSString
            var searchRange = NSRange(location: 0, length: nsLine.length)

            while searchRange.length > 0 {
                let found = nsLine.range(of: nsNeedle as String, options: [], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }

                let preview = line.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchResult(
                    id: "\(document.id):\(lineNumber):\(found.location)",
                    documentID: document.id,
                    relativePath: document.relativePath,
                    displayName: document.displayName,
                    kind: .text,
                    line: lineNumber,
                    column: found.location,
                    preview: preview.isEmpty ? line : preview
                ))

                if results.count >= limit {
                    stop = true
                    return
                }

                let nextLocation = found.location + found.length
                guard nextLocation < nsLine.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsLine.length - nextLocation)
            }

            lineNumber += 1
        }

        if cancelled {
            try Task.checkCancellation()
        }

        return WorkspaceSearchIndex.DocumentMatchBatch(results: results, skippedLargeFileCount: 0)
    }

    private static func fileSize(for url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
    }

    private func pdfMatches(
        foldedNeedle: String,
        document: WorkspaceDocument,
        limit: Int,
        pdfData: Data?
    ) throws -> [WorkspaceSearchResult] {
        let signpostID = MonknotSignposting.pdfSearch.beginInterval("PDFSearch")
        defer { MonknotSignposting.pdfSearch.endInterval("PDFSearch", signpostID) }

        try Task.checkCancellation()
        return try pdfIndex.matches(
            foldedNeedle: foldedNeedle,
            document: document,
            limit: limit,
            pdfData: pdfData
        )
    }
}
