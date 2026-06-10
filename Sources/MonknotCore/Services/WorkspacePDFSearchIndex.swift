import Foundation

public final class WorkspacePDFSearchIndex: @unchecked Sendable {
    public static let shared = WorkspacePDFSearchIndex()

    private struct SearchLine {
        let text: String
        let foldedText: String
    }

    private struct IndexedPage {
        let pageNumber: Int
        let lines: [SearchLine]
    }

    private struct Entry {
        let documentID: String
        let path: String
        let modificationDate: Date?
        let fileSize: Int64?
        let cacheRevision: WorkspacePDFTextCache.Revision
        let pages: [IndexedPage]
        var lastAccess: UInt64
    }

    private var entriesByDocumentID: [String: Entry] = [:]
    private let pdfCache: WorkspacePDFTextCache
    public let maxEntryCount: Int
    private var accessClock: UInt64 = 0
    private let lock = NSLock()

    public init(pdfCache: WorkspacePDFTextCache = .shared, maxEntryCount: Int = 256) {
        self.pdfCache = pdfCache
        self.maxEntryCount = max(1, maxEntryCount)
    }

    @discardableResult
    public func update(document: WorkspaceDocument) throws -> Bool {
        guard document.kind == .pdf else {
            remove(documentID: document.id)
            return false
        }

        _ = try entry(for: document)
        return true
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

    func matches(
        foldedNeedle: String,
        document: WorkspaceDocument,
        limit: Int,
        pdfData: Data? = nil
    ) throws -> [WorkspaceSearchResult] {
        guard limit > 0 else { return [] }

        if let pdfData {
            let pages = try pdfCache.pageTexts(forPDFData: pdfData).map { pageText in
                IndexedPage(
                    pageNumber: pageText.pageNumber,
                    lines: Self.searchLines(from: pageText.text)
                )
            }
            return Self.matches(
                foldedNeedle: foldedNeedle,
                pages: pages,
                document: document,
                limit: limit
            )
        }

        let entry = try entry(for: document)
        return Self.matches(
            foldedNeedle: foldedNeedle,
            pages: entry.pages,
            document: document,
            limit: limit
        )
    }

    var indexedDocumentIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entriesByDocumentID.keys)
    }

    private func entry(for document: WorkspaceDocument) throws -> Entry {
        let path = document.url.standardizedFileURL.path
        let signature = Self.signature(for: document.url)
        let cacheRevision = pdfCache.revision(for: document.url)

        lock.lock()
        if var cached = entriesByDocumentID[document.id],
           cached.path == path,
           cached.modificationDate == signature.modificationDate,
           cached.fileSize == signature.fileSize,
           cached.cacheRevision == cacheRevision {
            cached.lastAccess = nextAccess()
            entriesByDocumentID[document.id] = cached
            lock.unlock()
            return cached
        }
        lock.unlock()

        let pages = try pdfCache.pageTexts(for: document.url).map { pageText in
            IndexedPage(
                pageNumber: pageText.pageNumber,
                lines: Self.searchLines(from: pageText.text)
            )
        }
        let updatedCacheRevision = pdfCache.revision(for: document.url)

        let entry = Entry(
            documentID: document.id,
            path: path,
            modificationDate: signature.modificationDate,
            fileSize: signature.fileSize,
            cacheRevision: updatedCacheRevision,
            pages: pages,
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
        foldedNeedle: String,
        pages: [IndexedPage],
        document: WorkspaceDocument,
        limit: Int
    ) -> [WorkspaceSearchResult] {
        guard limit > 0 else { return [] }

        var results: [WorkspaceSearchResult] = []
        let nsNeedle = foldedNeedle as NSString

        for page in pages {
            for line in page.lines {
                let nsLine = line.foldedText as NSString
                var searchRange = NSRange(location: 0, length: nsLine.length)

                while searchRange.length > 0 {
                    let found = nsLine.range(of: nsNeedle as String, options: [], range: searchRange)
                    guard found.location != NSNotFound, found.length > 0 else { break }

                    let matchIndex = results.count
                    let preview = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    results.append(WorkspaceSearchResult(
                        id: "\(document.id):pdf:\(page.pageNumber):\(found.location):\(matchIndex)",
                        documentID: document.id,
                        relativePath: document.relativePath,
                        displayName: document.displayName,
                        kind: .pdf,
                        line: page.pageNumber,
                        column: found.location,
                        preview: preview.isEmpty ? line.text : preview,
                        pdfTarget: WorkspaceSearchPDFTarget(page: page.pageNumber, matchIndex: matchIndex)
                    ))

                    if results.count >= limit {
                        return results
                    }

                    let nextLocation = found.location + found.length
                    guard nextLocation < nsLine.length else { break }
                    searchRange = NSRange(location: nextLocation, length: nsLine.length - nextLocation)
                }
            }
        }

        return results
    }

    private static func searchLines(from text: String) -> [SearchLine] {
        var lines: [SearchLine] = []
        text.enumerateLines { line, _ in
            lines.append(SearchLine(
                text: line,
                foldedText: line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            ))
        }
        return lines
    }

    private static func signature(for url: URL) -> (modificationDate: Date?, fileSize: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return (nil, nil)
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let fileSize = (attributes[.size] as? NSNumber).map { $0.int64Value }
        return (modificationDate, fileSize)
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
