import Foundation

public actor TypingAssistanceTelemetryRecorder {
    public nonisolated let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            )
            self.fileURL = support
                .appendingPathComponent("Monknot", isDirectory: true)
                .appendingPathComponent("flow-telemetry.jsonl")
        }
    }

    public func append(
        _ event: TypingAssistanceTelemetryEvent
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
