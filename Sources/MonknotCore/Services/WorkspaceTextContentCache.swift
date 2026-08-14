import Foundation

public final class WorkspaceTextContentCache: @unchecked Sendable {
    public static let shared = WorkspaceTextContentCache()

    struct SearchLine {
        let number: Int
        let text: String
    }

    struct Revision: Equatable {
        let global: Int
        let path: Int
    }

    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int64?
        let text: String
        var searchLines: [SearchLine]?
        var lastAccess: UInt64
    }

    public let maxEntryCount: Int
    private var entries: [String: Entry] = [:]
    private var pathRevisions: [String: Int] = [:]
    private var globalRevision = 0
    private var accessClock: UInt64 = 0
    private let lock = NSLock()

    public init(maxEntryCount: Int = 512) {
        self.maxEntryCount = max(1, maxEntryCount)
    }

    public func text(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let signature = Self.signature(for: url)

        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[path] else { return nil }
        guard entry.modificationDate == signature.modificationDate,
              entry.fileSize == signature.fileSize else {
            entries.removeValue(forKey: path)
            pathRevisions[path, default: 0] &+= 1
            return nil
        }
        accessClock &+= 1
        var updatedEntry = entry
        updatedEntry.lastAccess = accessClock
        entries[path] = updatedEntry
        return entry.text
    }

    public func store(text: String, for url: URL) {
        let path = url.standardizedFileURL.path
        let signature = Self.signature(for: url)

        lock.lock()
        entries[path] = Entry(
            modificationDate: signature.modificationDate,
            fileSize: signature.fileSize,
            text: text,
            searchLines: nil,
            lastAccess: nextAccess()
        )
        pathRevisions[path, default: 0] &+= 1
        evictIfNeeded()
        lock.unlock()
    }

    func searchLines(for url: URL, buildingFrom text: String) -> [SearchLine] {
        let path = url.standardizedFileURL.path
        let signature = Self.signature(for: url)

        lock.lock()
        if let entry = entries[path],
           entry.modificationDate == signature.modificationDate,
           entry.fileSize == signature.fileSize,
           let searchLines = entry.searchLines {
            accessClock &+= 1
            var updatedEntry = entry
            updatedEntry.lastAccess = accessClock
            entries[path] = updatedEntry
            lock.unlock()
            return searchLines
        }
        lock.unlock()

        let searchLines = Self.makeSearchLines(from: text)

        lock.lock()
        if var entry = entries[path],
           entry.modificationDate == signature.modificationDate,
           entry.fileSize == signature.fileSize {
            entry.searchLines = searchLines
            entry.lastAccess = nextAccess()
            entries[path] = entry
        } else {
            entries[path] = Entry(
                modificationDate: signature.modificationDate,
                fileSize: signature.fileSize,
                text: text,
                searchLines: searchLines,
                lastAccess: nextAccess()
            )
        }
        evictIfNeeded()
        lock.unlock()

        return searchLines
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

    private static func signature(for url: URL) -> (modificationDate: Date?, fileSize: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (nil, nil)
        }
        return (values.contentModificationDate, values.fileSize.map(Int64.init))
    }

    private static func makeSearchLines(from text: String) -> [SearchLine] {
        var lines: [SearchLine] = []
        var lineNumber = 1
        text.enumerateLines { line, _ in
            lines.append(SearchLine(
                number: lineNumber,
                text: line
            ))
            lineNumber += 1
        }
        return lines
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
        }
    }
}
