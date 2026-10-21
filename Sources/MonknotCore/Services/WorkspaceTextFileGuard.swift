import Foundation

public enum WorkspaceTextFileGuard {
    public static let defaultMaxBytes: Int64 = 32 * 1024 * 1024

    public enum Error: LocalizedError, Equatable {
        case fileTooLarge(path: String, size: Int64, maxBytes: Int64)
        case unreadableEncoding(path: String)
        case binaryContent(path: String)

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge(let path, let size, let maxBytes):
                let sizeMB = Double(size) / (1024 * 1024)
                let maxMB = Double(maxBytes) / (1024 * 1024)
                return "\(path) is too large to open (\(String(format: "%.1f", sizeMB)) MB; limit \(String(format: "%.0f", maxMB)) MB)."
            case .unreadableEncoding(let path):
                return "\(path) is not valid UTF-8 text."
            case .binaryContent(let path):
                return "\(path) holds binary data, not text."
            }
        }
    }

    public static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    public static func ensureWithinLimit(at url: URL, maxBytes: Int64 = defaultMaxBytes) throws {
        let size = try fileSize(at: url)
        guard size <= maxBytes else {
            throw Error.fileTooLarge(
                path: url.lastPathComponent,
                size: size,
                maxBytes: maxBytes
            )
        }
    }

    public static func readUTF8Text(
        from url: URL,
        maxBytes: Int64 = defaultMaxBytes,
        cache: WorkspaceTextContentCache? = .shared
    ) throws -> String {
        try ensureWithinLimit(at: url, maxBytes: maxBytes)

        if let cache, let cached = cache.text(for: url) {
            return cached
        }
        if let known = cache?.unreadableError(for: url) {
            throw known
        }

        do {
            // A large file whose first bytes are not text is refused before the rest is read: a
            // build product or a database under an unknown extension can be many megabytes.
            if try fileSize(at: url) > sniffedPrefixBytes, let error = try prefixError(of: url) {
                throw error
            }
            let data = try Data(contentsOf: url)
            guard let text = decodeUTF8(data) else {
                throw Error.unreadableEncoding(path: url.lastPathComponent)
            }
            // A NUL byte is valid UTF-8 but never appears in text; the editor would show it as garbage.
            guard !containsNULByte(data) else {
                throw Error.binaryContent(path: url.lastPathComponent)
            }
            cache?.store(text: text, for: url)
            return text
        } catch let error as Error {
            if case .fileTooLarge = error {} else {
                cache?.markUnreadable(url, error: error)
            }
            throw error
        }
    }

    /// How much of a large file is read first to tell text from binary data.
    static let sniffedPrefixBytes = 8 * 1024

    /// Why the first `sniffedPrefixBytes` of `url` are not text, or nil when they are. The prefix
    /// may end inside a multi-byte character, which is not counted against it.
    private static func prefixError(of url: URL) throws -> Error? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: sniffedPrefixBytes) ?? Data()
        let decodes = (0...3).contains { decodeUTF8(prefix.dropLast($0)) != nil }
        guard decodes else { return .unreadableEncoding(path: url.lastPathComponent) }
        return containsNULByte(prefix) ? .binaryContent(path: url.lastPathComponent) : nil
    }

    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    /// The text of UTF-8 `data` without a leading byte order mark, which some macOS versions keep
    /// when decoding and others drop.
    public static func decodeUTF8(_ data: Data) -> String? {
        let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data[...]
        return String(data: Data(body), encoding: .utf8)
    }

    /// Decoding drops a UTF-8 byte order mark, so a save puts it back when the file starts with one.
    public static func utf8Data(for text: String, preservingByteOrderMarkOf url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data(text.utf8) }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: byteOrderMark.count)) == byteOrderMark else {
            return Data(text.utf8)
        }
        return byteOrderMark + Data(text.utf8)
    }

    /// Writes `text` atomically as UTF-8, keeping the file's byte order mark if it has one.
    public static func writeUTF8Text(_ text: String, to url: URL) throws {
        try utf8Data(for: text, preservingByteOrderMarkOf: url).write(to: url, options: .atomic)
    }

    private static func containsNULByte(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return memchr(baseAddress, 0, buffer.count) != nil
        }
    }
}
