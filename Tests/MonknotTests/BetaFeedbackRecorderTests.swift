import XCTest
@testable import MonknotCore

final class BetaFeedbackRecorderTests: XCTestCase {
    func testAppendWritesJSONLLine() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("feedback.jsonl")
        let recorder = BetaFeedbackRecorder(fileURL: fileURL)

        let entry = try recorder.append(message: "Preview scroll feels sticky")
        XCTAssertEqual(entry.message, "Preview scroll feels sticky")

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Preview scroll feels sticky"))
    }

    func testAppendRejectsEmptyMessage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = BetaFeedbackRecorder(fileURL: root.appendingPathComponent("feedback.jsonl"))
        XCTAssertThrowsError(try recorder.append(message: "   ")) { error in
            guard case BetaFeedbackRecorder.Error.emptyMessage = error else {
                return XCTFail("Expected emptyMessage, got \(error)")
            }
        }
    }

    func testAppendProducesOneDecodableJSONObjectPerLineInOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("feedback.jsonl")
        let recorder = BetaFeedbackRecorder(fileURL: fileURL)

        _ = try recorder.append(message: "  First message  ")
        _ = try recorder.append(message: "Second message")

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
        let entries = try lines.map {
            try JSONDecoder().decode(BetaFeedbackEntry.self, from: Data($0.utf8))
        }
        XCTAssertEqual(entries.map(\.message), ["First message", "Second message"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-feedback-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
