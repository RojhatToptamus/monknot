import Foundation
import XCTest
@testable import MonknotApp
@testable import MonknotCore

final class LocalTypingAssistantRuntimeTests: XCTestCase {
    func testLoadedCorrectionReturnsSafeSuggestion() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .json(
                    #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"This is ready.\"}"}}"#
                ),
            ]
        )
        let runtime = makeRuntime(transport: transport)
        let snapshot = snapshot(text: "this is ready")
        let context = TypingAssistanceContext(
            text: snapshot.text,
            range: NSRange(location: 0, length: (snapshot.text as NSString).length)
        )

        let result = await runtime.requestCorrection(
            snapshot: snapshot,
            context: context
        )
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(result.route, .loadedForeground)
        XCTAssertEqual(result.suggestion?.replacementText, "This is ready.")
        XCTAssertEqual(diagnostics.observedPeakModelConcurrency, 1)
    }

    func testUnloadedStateReturnsNoSuggestionAndWarmsInBackground() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[]}"#),
                .json(#"{"done":true}"#),
            ]
        )
        let runtime = makeRuntime(transport: transport)
        let snapshot = snapshot(text: "this is ready")

        let result = await runtime.requestCorrection(
            snapshot: snapshot,
            context: TypingAssistanceContext(
                text: snapshot.text,
                range: NSRange(location: 0, length: (snapshot.text as NSString).length)
            )
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(result.route, .unloadedBackgroundWarmup)
        XCTAssertNil(result.suggestion)
        XCTAssertEqual(diagnostics.backgroundWarmups, 1)
        XCTAssertEqual(diagnostics.fallbackTextMutationCount, 0)
        XCTAssertEqual(diagnostics.fabricatedFallbackCorrectionCount, 0)
    }

    func testForegroundTimeoutReturnsNoSuggestion() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .delayedJSON(
                    #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"This is ready.\"}"}}"#,
                    nanoseconds: 80_000_000
                ),
            ]
        )
        let runtime = makeRuntime(
            transport: transport,
            foregroundDeadline: 0.01
        )
        let snapshot = snapshot(text: "this is ready")

        let result = await runtime.requestCorrection(
            snapshot: snapshot,
            context: TypingAssistanceContext(
                text: snapshot.text,
                range: NSRange(location: 0, length: (snapshot.text as NSString).length)
            )
        )

        XCTAssertEqual(result.route, .foregroundTimeout)
        XCTAssertNil(result.suggestion)
    }

    func testProbeFailureReturnsNoSuggestionAndSchedulesWarmup() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .failure(.invalidResponse),
                .json(#"{"done":true}"#),
            ]
        )
        let runtime = makeRuntime(transport: transport)
        let source = snapshot(text: "this is ready")

        let result = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(result.route, .probeFailure)
        XCTAssertNil(result.suggestion)
        XCTAssertEqual(diagnostics.backgroundWarmups, 1)
        XCTAssertEqual(source.text, "this is ready")
    }

    func testBackgroundTimeoutReturnsNoSuggestionAndAllowsLaterRetry() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[]}"#),
                .delayedJSON(#"{"done":true}"#, nanoseconds: 80_000_000),
                .json(#"{"models":[]}"#),
                .json(#"{"done":true}"#),
            ]
        )
        let runtime = makeRuntime(
            transport: transport,
            backgroundDeadline: 0.01
        )
        let source = snapshot(text: "this is ready")

        let first = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(first.route, .unloadedBackgroundWarmup)
        XCTAssertEqual(second.route, .unloadedBackgroundWarmup)
        XCTAssertNil(first.suggestion)
        XCTAssertNil(second.suggestion)
        XCTAssertEqual(diagnostics.backgroundWarmups, 1)
        XCTAssertEqual(diagnostics.fallbackTextMutationCount, 0)
        XCTAssertEqual(diagnostics.fabricatedFallbackCorrectionCount, 0)
    }

    func testSafetySuppressionDoesNotExposeRewrite() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .json(
                    #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"You need checks.\"}"}}"#
                ),
            ]
        )
        let runtime = makeRuntime(transport: transport)
        let snapshot = snapshot(text: "A scheduler require checks.")

        let result = await runtime.requestCorrection(
            snapshot: snapshot,
            context: TypingAssistanceContext(
                text: snapshot.text,
                range: NSRange(location: 0, length: (snapshot.text as NSString).length)
            )
        )

        XCTAssertEqual(result.route, .safetySuppressed)
        XCTAssertNil(result.suggestion)
    }

    func testConcurrentRequestIsRejectedInsteadOfQueued() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .delayedJSON(
                    #"{"message":{"content":"{\"action\":\"unchanged\",\"text\":\"first\"}"}}"#,
                    nanoseconds: 20_000_000
                ),
            ]
        )
        let runtime = makeRuntime(transport: transport)
        let first = snapshot(text: "first", revision: 1)
        let second = snapshot(text: "second", revision: 2)

        async let firstResult = runtime.requestCorrection(
            snapshot: first,
            context: TypingAssistanceContext(
                text: first.text,
                range: NSRange(location: 0, length: 5)
            )
        )
        async let secondResult = runtime.requestCorrection(
            snapshot: second,
            context: TypingAssistanceContext(
                text: second.text,
                range: NSRange(location: 0, length: 6)
            )
        )
        let results = await (firstResult, secondResult)
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(diagnostics.observedPeakModelConcurrency, 1)
        XCTAssertEqual(diagnostics.totalModelCalls, 1)
        XCTAssertTrue([results.0.route, results.1.route].contains(.modelBusy))
    }

    private func makeRuntime(
        transport: FakeTypingAssistantTransport,
        foregroundDeadline: TimeInterval = 0.2,
        backgroundDeadline: TimeInterval = 0.2
    ) -> LocalTypingAssistantRuntime {
        LocalTypingAssistantRuntime(
            configuration: LocalTypingAssistantConfiguration(
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: "test-model",
                contextLength: 2_048,
                keepAlive: "5m",
                probeDeadline: 0.1,
                foregroundDeadline: foregroundDeadline,
                backgroundDeadline: backgroundDeadline
            ),
            transport: transport
        )
    }

    private func snapshot(
        text: String,
        revision: Int = 1
    ) -> TypingAssistanceEditorSnapshot {
        TypingAssistanceEditorSnapshot(
            documentID: "note.md",
            revision: revision,
            text: text,
            cursorUTF16Offset: (text as NSString).length
        )
    }

    private func context(
        for snapshot: TypingAssistanceEditorSnapshot
    ) -> TypingAssistanceContext {
        TypingAssistanceContext(
            text: snapshot.text,
            range: NSRange(
                location: 0,
                length: (snapshot.text as NSString).length
            )
        )
    }
}

private actor FakeTypingAssistantTransport: LocalTypingAssistantTransport {
    enum Response {
        case json(String)
        case delayedJSON(String, nanoseconds: UInt64)
        case failure(LocalTypingAssistantRuntimeError)
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else {
            throw LocalTypingAssistantRuntimeError.invalidResponse
        }
        let response = responses.removeFirst()
        let text: String
        switch response {
        case let .json(value):
            text = value
        case let .delayedJSON(value, nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            text = value
        case let .failure(error):
            throw error
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(text.utf8), httpResponse)
    }
}
