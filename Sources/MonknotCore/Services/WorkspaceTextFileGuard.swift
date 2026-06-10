import Foundation

public enum WorkspaceTextFileGuard {
    public static let defaultMaxBytes: Int64 = 32 * 1024 * 1024

    public enum Error: LocalizedError, Equatable {
        case fileTooLarge(path: String, size: Int64, maxBytes: Int64)
        case unreadableEncoding(path: String)

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge(let path, let size, let maxBytes):
                let sizeMB = Double(size) / (1024 * 1024)
                let maxMB = Double(maxBytes) / (1024 * 1024)
                return "\(path) is too large to open (\(String(format: "%.1f", sizeMB)) MB; limit \(String(format: "%.0f", maxMB)) MB)."
            case .unreadableEncoding(let path):
                return "\(path) is not valid UTF-8 text."
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

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Error.unreadableEncoding(path: url.lastPathComponent)
        }

        cache?.store(text: text, for: url)
        return text
    }
}
