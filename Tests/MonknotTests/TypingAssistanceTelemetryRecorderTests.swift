import XCTest
@testable import MonknotCore

final class TypingAssistanceTelemetryRecorderTests: XCTestCase {
    func testRecorderWritesTextFreeJSONL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("flow.jsonl")
        let recorder = TypingAssistanceTelemetryRecorder(fileURL: fileURL)
        let event = TypingAssistanceTelemetryEvent(
            participantID: "participant",
            sessionID: "session",
            kind: .modelResult,
            requestKind: .grammar,
            inputCategory: .normal,
            route: "loadedForeground",
            path: "foreground",
            timeoutResult: "notTimedOut",
            fallbackResult: "notFallback",
            dispatchMilliseconds: nil,
            modelLatencyMilliseconds: 12,
            suggestionShown: true,
            automaticApplication: false,
            accepted: false,
            staleCancellation: false,
            editorTextUnchanged: true,
            observedPeakModelConcurrency: 1
        )

        try await recorder.append(event)

        let data = try Data(contentsOf: fileURL)
        let line = try XCTUnwrap(
            String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .first
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            object["schemaVersion"] as? String,
            TypingAssistanceTelemetryEvent.schemaVersion
        )
        XCTAssertEqual(object["noteTextIncluded"] as? Bool, false)
        XCTAssertEqual(object["suggestionTextIncluded"] as? Bool, false)
        XCTAssertEqual(object["documentIdentityIncluded"] as? Bool, false)
        XCTAssertEqual(object["hiddenRegressionUsed"] as? Bool, false)
        XCTAssertEqual(object["trainingDataProduced"] as? Bool, false)
        XCTAssertEqual(object["observedPeakModelConcurrency"] as? Int, 1)
        XCTAssertNil(object["text"])
        XCTAssertNil(object["suggestion"])
        XCTAssertNil(object["documentID"])
    }

    func testInputCategoryUsesOnlyDerivedShape() {
        XCTAssertEqual(
            TypingAssistanceInputCategory.classify("Fix this"),
            .short
        )
        XCTAssertEqual(
            TypingAssistanceInputCategory.classify(
                "This sentence contains enough words to be normal prose."
            ),
            .normal
        )
        XCTAssertEqual(
            TypingAssistanceInputCategory.classify(
                Array(repeating: "word", count: 20).joined(separator: " ")
            ),
            .long20To50Words
        )
        XCTAssertEqual(
            TypingAssistanceInputCategory.classify(
                Array(repeating: "word", count: 51).joined(separator: " ")
            ),
            .over50Words
        )
        XCTAssertEqual(
            TypingAssistanceInputCategory.classify("First sentence. Second sentence."),
            .multiSentence
        )
    }
}
