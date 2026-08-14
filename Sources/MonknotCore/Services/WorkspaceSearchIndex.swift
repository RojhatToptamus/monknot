import Foundation

public final class WorkspaceSearchIndex: @unchecked Sendable {
    public static let shared = WorkspaceSearchIndex()

    enum DocumentStatus {
        case indexed([WorkspaceTextContentCache.SearchLine])
        case skippedLarge
    }

    struct DocumentMatchBatch {
        let results: [WorkspaceSearchResult]
        let skippedLargeFileCount: Int
    }

    private struct Entry {
        let documentID: String
        let path: String
        let modificationDate: Date?
        let fileSize: Int64?
        let cacheRevision: WorkspaceTextContentCache.Revision
        let maxBytes: Int64
        let status: DocumentStatus
        var lastAccess: UInt64
    }

    private var entriesByDocumentID: [String: Entry] = [:]
    private let textCache: WorkspaceTextContentCache
    public let maxEntryCount: Int
    private var accessClock: UInt64 = 0
    private let lock = NSLock()

    public init(textCache: WorkspaceTextContentCache = .shared, maxEntryCount: Int = 4096) {
        self.textCache = textCache
        self.maxEntryCount = max(1, maxEntryCount)
    }

    @discardableResult
    public func update(document: WorkspaceDocument, maxBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes) throws -> Bool {
        guard document.kind == .markdown || document.kind == .text else {
            remove(documentID: document.id)
            return false
        }

        _ = try entry(for: document, maxBytes: maxBytes)
        return true
    }

    public func rebuild(documents: [WorkspaceDocument], maxBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes) throws {
        invalidateAll()
        for document in documents where document.kind == .markdown || document.kind == .text {
            try Task.checkCancellation()
            try update(document: document, maxBytes: maxBytes)
        }
    }

    public func remove(documentID: String) {
        lock.lock()
        entriesByDocumentID.removeValue(forKey: documentID)
        lock.unlock()
    }

    public func invalidate(paths: some Sequence<String>) {
        let normalizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !normalizedPaths.isEmpty else { return }

        lock.lock()
        entriesByDocumentID = entriesByDocumentID.filter { _, entry in
            !normalizedPaths.contains(entry.path)
        }
        lock.unlock()
    }

    public func invalidateAll() {
        lock.lock()
        entriesByDocumentID.removeAll()
        lock.unlock()
    }

    public func hasIndexedDocument(_ documentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesByDocumentID[documentID] != nil
    }

    public func search(
        query: String,
        options: MonknotSearchOptions = MonknotSearchOptions(),
        documents: [WorkspaceDocument],
        maxMatches: Int = 500,
        maxMatchesPerFile: Int = 50,
        maxTextFileBytes: Int64 = WorkspaceTextFileGuard.defaultMaxBytes
    ) throws -> WorkspaceSearchBatch {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return WorkspaceSearchBatch(results: []) }
        var results: [WorkspaceSearchResult] = []
        var skippedLargeFileCount = 0

        for document in documents where document.kind == .markdown || document.kind == .text {
            try Task.checkCancellation()
            let batch = try matches(
                query: needle,
                options: options,
                document: document,
                limit: maxMatchesPerFile,
                maxBytes: maxTextFileBytes
            )
            skippedLargeFileCount += batch.skippedLargeFileCount
            results.append(contentsOf: batch.results)

            if results.count >= maxMatches {
                return WorkspaceSearchBatch(
                    results: Array(results.prefix(maxMatches)),
                    skippedLargeFileCount: skippedLargeFileCount
                )
            }
        }

        return WorkspaceSearchBatch(results: results, skippedLargeFileCount: skippedLargeFileCount)
    }

    func matches(
        query: String,
        options: MonknotSearchOptions,
        document: WorkspaceDocument,
        limit: Int,
        maxBytes: Int64
    ) throws -> DocumentMatchBatch {
        guard limit > 0 else {
            return DocumentMatchBatch(results: [], skippedLargeFileCount: 0)
        }

        let entry = try entry(for: document, maxBytes: maxBytes)
        switch entry.status {
        case .skippedLarge:
            return DocumentMatchBatch(results: [], skippedLargeFileCount: 1)
        case .indexed(let searchLines):
            return DocumentMatchBatch(
                results: Self.matches(
                    query: query,
                    options: options,
                    searchLines: searchLines,
                    document: document,
                    limit: limit
                ),
                skippedLargeFileCount: 0
            )
        }
    }

    var indexedDocumentIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entriesByDocumentID.keys)
    }

    private func entry(for document: WorkspaceDocument, maxBytes: Int64) throws -> Entry {
        let path = document.url.standardizedFileURL.path
        let signature = Self.signature(for: document.url)
        let cacheRevision = textCache.revision(for: document.url)

        lock.lock()
        if var cached = entriesByDocumentID[document.id],
           cached.path == path,
           cached.modificationDate == signature.modificationDate,
           cached.fileSize == signature.fileSize,
           cached.cacheRevision == cacheRevision,
           cached.maxBytes == maxBytes {
            cached.lastAccess = nextAccess()
            entriesByDocumentID[document.id] = cached
            lock.unlock()
            return cached
        }
        lock.unlock()

        let status: DocumentStatus
        do {
            let text = try WorkspaceTextFileGuard.readUTF8Text(
                from: document.url,
                maxBytes: maxBytes,
                cache: textCache
            )
            status = .indexed(textCache.searchLines(for: document.url, buildingFrom: text))
        } catch WorkspaceTextFileGuard.Error.fileTooLarge {
            status = .skippedLarge
        }
        let updatedCacheRevision = textCache.revision(for: document.url)

        let entry = Entry(
            documentID: document.id,
            path: path,
            modificationDate: signature.modificationDate,
            fileSize: signature.fileSize,
            cacheRevision: updatedCacheRevision,
            maxBytes: maxBytes,
            status: status,
            lastAccess: 0
        )

        lock.lock()
        var accessedEntry = entry
        accessedEntry.lastAccess = nextAccess()
        entriesByDocumentID[document.id] = accessedEntry
        evictIfNeeded()
        lock.unlock()

        return accessedEntry
    }

    private static func matches(
        query: String,
        options: MonknotSearchOptions,
        searchLines: [WorkspaceTextContentCache.SearchLine],
        document: WorkspaceDocument,
        limit: Int
    ) -> [WorkspaceSearchResult] {
        guard limit > 0 else { return [] }

        var results: [WorkspaceSearchResult] = []
        for line in searchLines {
            for found in MonknotTextSearch.matchingRanges(of: query, in: line.text, options: options) {
                let preview = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchResult(
                    id: "\(document.id):\(line.number):\(found.location)",
                    documentID: document.id,
                    relativePath: document.relativePath,
                    displayName: document.displayName,
                    kind: .text,
                    line: line.number,
                    column: found.location,
                    preview: preview.isEmpty ? line.text : preview
                ))

                if results.count >= limit {
                    return results
                }
            }
        }

        return results
    }

    private static func signature(for url: URL) -> (modificationDate: Date?, fileSize: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (nil, nil)
        }
        return (values.contentModificationDate, values.fileSize.map(Int64.init))
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func evictIfNeeded() {
        guard entriesByDocumentID.count > maxEntryCount else { return }
        let overflowCount = entriesByDocumentID.count - maxEntryCount
        let evictedDocumentIDs = entriesByDocumentID
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(overflowCount)
            .map(\.key)

        for documentID in evictedDocumentIDs {
            entriesByDocumentID.removeValue(forKey: documentID)
        }
    }
}
