import Foundation
import PDFKit

public final class WorkspacePDFTextCache: @unchecked Sendable {
    public static let shared = WorkspacePDFTextCache()

    struct PageText: Sendable, Equatable {
        let pageNumber: Int
        let text: String
    }

    struct Revision: Equatable {
        let global: Int
        let path: Int
    }

    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int64?
        let pages: [PageText]
        var lastAccess: UInt64
    }

    public let maxEntryCount: Int
    private var entries: [String: Entry] = [:]
    private var pathRevisions: [String: Int] = [:]
    private var globalRevision = 0
    private var accessClock: UInt64 = 0
    private let lock = NSLock()

    public init(maxEntryCount: Int = 256) {
        self.maxEntryCount = max(1, maxEntryCount)
    }

    func pageTexts(for url: URL) throws -> [PageText] {
        let path = url.standardizedFileURL.path
        let signature = Self.signature(for: url)

        lock.lock()
        if var entry = entries[path],
           entry.modificationDate == signature.modificationDate,
           entry.fileSize == signature.fileSize {
            entry.lastAccess = nextAccess()
            entries[path] = entry
            lock.unlock()
            return entry.pages
        }
        entries.removeValue(forKey: path)
        pathRevisions[path, default: 0] &+= 1
        lock.unlock()

        guard let pdf = PDFDocument(url: url) else {
            return []
        }

        let pages = try Self.pageTexts(from: pdf)

        lock.lock()
        entries[path] = Entry(
            modificationDate: signature.modificationDate,
            fileSize: signature.fileSize,
            pages: pages,
            lastAccess: nextAccess()
        )
        pathRevisions[path, default: 0] &+= 1
        evictIfNeeded()
        lock.unlock()

        return pages
    }

    func pageTexts(forPDFData data: Data) throws -> [PageText] {
        guard let pdf = PDFDocument(data: data) else {
            return []
        }
        return try Self.pageTexts(from: pdf)
    }

    public func invalidate(paths: some Sequence<String>) {
        lock.lock()
        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            entries.removeValue(forKey: normalizedPath)
            pathRevisions[normalizedPath, default: 0] &+= 1
        }
        lock.unlock()
    }

    public func invalidateAll() {
        lock.lock()
        entries.removeAll()
        globalRevision &+= 1
        lock.unlock()
    }

    func revision(for url: URL) -> Revision {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return Revision(global: globalRevision, path: pathRevisions[path] ?? 0)
    }

    var cachedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.keys)
    }

    private static func signature(for url: URL) -> (modificationDate: Date?, fileSize: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return (nil, nil)
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let fileSize = (attributes[.size] as? NSNumber).map { $0.int64Value }
        return (modificationDate, fileSize)
    }

    private static func pageTexts(from pdf: PDFDocument) throws -> [PageText] {
        var pages: [PageText] = []
        for pageIndex in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: pageIndex) else { continue }
            let text = Self.searchableText(for: page)
            guard !text.isEmpty else { continue }
            pages.append(PageText(pageNumber: pageIndex + 1, text: text))
        }
        return pages
    }

    private static func searchableText(for page: PDFPage) -> String {
        var parts: [String] = []

        if let pageText = trimmed(page.string) {
            parts.append(pageText)
        }
        var foldedParts = Set(parts.map(folded))

        let annotationTexts = page.annotations
            .sorted { lhs, rhs in
                if lhs.bounds.maxY == rhs.bounds.maxY {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            .compactMap { trimmed($0.contents) }

        for annotationText in annotationTexts {
            let foldedAnnotationText = folded(annotationText)
            guard !foldedParts.contains(foldedAnnotationText) else { continue }
            parts.append(annotationText)
            foldedParts.insert(foldedAnnotationText)
        }
        return parts.joined(separator: "\n")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntryCount else { return }
        let overflowCount = entries.count - maxEntryCount
        let evictedPaths = entries
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(overflowCount)
            .map(\.key)

        for path in evictedPaths {
            entries.removeValue(forKey: path)
            pathRevisions[path, default: 0] &+= 1
        }
    }
}
