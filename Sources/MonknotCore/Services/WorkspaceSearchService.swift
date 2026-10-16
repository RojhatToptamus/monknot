import Foundation
import OSLog

public struct WorkspaceSearchBatch: Sendable {
    public let results: [WorkspaceSearchResult]
    public let skippedLargeFileCount: Int
    /// There are more matches than `results`: a total or per-file limit cut them off.
    public let reachedMatchLimit: Bool
    /// Documents that have more matches than `results` lists for them.
    public let truncatedDocumentIDs: Set<String>

    public init(
        results: [WorkspaceSearchResult],
        skippedLargeFileCount: Int = 0,
        reachedMatchLimit: Bool = false,
        truncatedDocumentIDs: Set<String> = []
    ) {
        self.results = results
        self.skippedLargeFileCount = skippedLargeFileCount
        self.reachedMatchLimit = reachedMatchLimit
        self.truncatedDocumentIDs = truncatedDocumentIDs
    }
}

/// Gathers matches file by file up to a total and a per-file limit, and notes what the limits cut off.
struct WorkspaceSearchCollector {
    let maxMatches: Int
    let maxMatchesPerFile: Int
    private(set) var results: [WorkspaceSearchResult] = []
    private var truncatedDocumentIDs: Set<String> = []
    private var reachedMatchLimit = false

    init(maxMatches: Int, maxMatchesPerFile: Int) {
        self.maxMatches = maxMatches
        self.maxMatchesPerFile = maxMatchesPerFile
    }

    /// Ask each file for one match more than its limit, so a file with exactly the limit is not
    /// reported as cut short.
    var perFileQueryLimit: Int { maxMatchesPerFile + 1 }

    /// Adds one file's matches. Returns false once the total limit is reached and the search can stop.
    mutating func add(_ fileMatches: [WorkspaceSearchResult], documentID: String) -> Bool {
        var matches = fileMatches
        if matches.count > maxMatchesPerFile {
            matches = Array(matches.prefix(maxMatchesPerFile))
            truncatedDocumentIDs.insert(documentID)
            reachedMatchLimit = true
        }
        let room = maxMatches - results.count
        guard matches.count > room else {
            results.append(contentsOf: matches)
            return true
        }
        if room > 0 {
            truncatedDocumentIDs.insert(documentID)
        }
        results.append(contentsOf: matches.prefix(room))
        reachedMatchLimit = true
        return false
    }

    func batch(skippedLargeFileCount: Int) -> WorkspaceSearchBatch {
        WorkspaceSearchBatch(
            results: results,
            skippedLargeFileCount: skippedLargeFileCount,
            reachedMatchLimit: reachedMatchLimit,
            truncatedDocumentIDs: truncatedDocumentIDs
        )
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
        options: MonknotSearchOptions = MonknotSearchOptions(),
        documents: [WorkspaceDocument],
        dirtyTextByDocumentID: [String: String] = [:],
        dirtyPDFDataByDocumentID: [String: Data] = [:]
    ) throws -> WorkspaceSearchBatch {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return WorkspaceSearchBatch(results: []) }
        let signpostID = MonknotSignposting.workspaceSearch.beginInterval("WorkspaceSearch")
        defer { MonknotSignposting.workspaceSearch.endInterval("WorkspaceSearch", signpostID) }

        var collector = WorkspaceSearchCollector(maxMatches: maxMatches, maxMatchesPerFile: maxMatchesPerFile)
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
                        query: needle,
                        options: options,
                        document: document,
                        text: dirtyText,
                        limit: collector.perFileQueryLimit
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
                        query: needle,
                        options: options,
                        document: document,
                        limit: collector.perFileQueryLimit,
                        maxBytes: maxTextFileBytes
                    )
                    : uncachedTextMatches(
                        query: needle,
                        options: options,
                        document: document,
                        limit: collector.perFileQueryLimit
                    )
                skippedLargeFileCount += batch.skippedLargeFileCount
                matches = batch.results
            case .pdf:
                matches = try pdfMatches(
                    query: needle,
                    options: options,
                    document: document,
                    limit: collector.perFileQueryLimit,
                    pdfData: dirtyPDFDataByDocumentID[document.id]
                )
            case .image, .media, .nativePreview, .unsupported:
                continue
            }

            guard collector.add(matches, documentID: document.id) else { break }
        }

        return collector.batch(skippedLargeFileCount: skippedLargeFileCount)
    }

    private func uncachedTextMatches(
        query: String,
        options: MonknotSearchOptions,
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
        } catch is WorkspaceTextFileGuard.Error {
            return WorkspaceSearchIndex.DocumentMatchBatch(results: [], skippedLargeFileCount: 0)
        }

        return try textMatches(
            query: query,
            options: options,
            document: document,
            text: text,
            limit: limit
        )
    }

    private func textMatches(
        query: String,
        options: MonknotSearchOptions,
        document: WorkspaceDocument,
        text: String,
        limit: Int
    ) throws -> WorkspaceSearchIndex.DocumentMatchBatch {
        guard limit > 0 else {
            return WorkspaceSearchIndex.DocumentMatchBatch(results: [], skippedLargeFileCount: 0)
        }

        var results: [WorkspaceSearchResult] = []
        var lineNumber = 1
        var cancelled = false

        text.enumerateLines { line, stop in
            if Task.isCancelled {
                cancelled = true
                stop = true
                return
            }

            for found in MonknotTextSearch.matchingRanges(of: query, in: line, options: options) {
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
        query: String,
        options: MonknotSearchOptions,
        document: WorkspaceDocument,
        limit: Int,
        pdfData: Data?
    ) throws -> [WorkspaceSearchResult] {
        let signpostID = MonknotSignposting.pdfSearch.beginInterval("PDFSearch")
        defer { MonknotSignposting.pdfSearch.endInterval("PDFSearch", signpostID) }

        try Task.checkCancellation()
        return try pdfIndex.matches(
            query: query,
            options: options,
            document: document,
            limit: limit,
            pdfData: pdfData
        )
    }
}
