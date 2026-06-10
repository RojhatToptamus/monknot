import Foundation

public struct BetaFeedbackEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date = Date(), message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

public struct BetaFeedbackRecorder {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = support
                .appendingPathComponent("Monknot", isDirectory: true)
                .appendingPathComponent("beta-feedback.jsonl")
        }
    }

    public func append(message: String) throws -> BetaFeedbackEntry {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.emptyMessage
        }

        let entry = BetaFeedbackEntry(message: trimmed)
        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else {
            throw Error.encodingFailed
        }
        line.append("\n")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return entry
    }

    public enum Error: Swift.Error {
        case emptyMessage
        case encodingFailed
    }
}
