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
    /// Files found not to be text (binary data under a source-like name), by their signature then,
    /// so search does not read them again until they change.
    private var unreadable: [String: (modificationDate: Date?, fileSize: Int64?, error: WorkspaceTextFileGuard.Error)] = [:]
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
            unreadable.removeValue(forKey: normalizedPath)
            pathRevisions[normalizedPath, default: 0] &+= 1
        }
        lock.unlock()
    }

    /// Why `url` is not text, when it was found so and has not changed since.
    public func unreadableError(for url: URL) -> WorkspaceTextFileGuard.Error? {
        let path = url.standardizedFileURL.path
        lock.lock()
        let known = unreadable[path]
        lock.unlock()
        guard let known else { return nil }
        let signature = Self.signature(for: url)
        guard known.modificationDate == signature.modificationDate, known.fileSize == signature.fileSize else {
            return nil
        }
        return known.error
    }

    public func markUnreadable(_ url: URL, error: WorkspaceTextFileGuard.Error) {
        let path = url.standardizedFileURL.path
        let signature = Self.signature(for: url)
        lock.lock()
        unreadable[path] = (signature.modificationDate, signature.fileSize, error)
        if unreadable.count > maxEntryCount * 8 {
            unreadable.removeAll()
        }
        lock.unlock()
    }

    public func invalidateAll() {
        lock.lock()
        entries.removeAll()
        unreadable.removeAll()
        globalRevision &+= 1
        lock.unlock()
    }

    func revision(for url: URL) -> Revision {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return Revision(global: globalRevision, path: pathRevisions[path] ?? 0)
    }

    /// The file's date and size as the disk has them now. A `URL` keeps the resource values it
    /// read once, which would hide a change to a file read through the same URL again.
    private static func signature(for url: URL) -> (modificationDate: Date?, fileSize: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return (nil, nil)
        }
        return (attributes[.modificationDate] as? Date, (attributes[.size] as? NSNumber)?.int64Value)
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
