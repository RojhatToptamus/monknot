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
        XCTAssertEqual(
            result.suggestion?.sourceSelectionUTF16Location,
            snapshot.selectionUTF16Location
        )
        XCTAssertEqual(
            result.suggestion?.sourceSelectionLength,
            snapshot.selectionLength
        )
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

    func testUncooperativeForegroundReturnsAtDeadlineAndKeepsGateUntilDrain() async {
        let loaded = #"{"models":[{"name":"test-model","context_length":2048}]}"#
        let correction =
            #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"This is ready.\"}"}}"#
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(loaded),
                .uncooperativeDelayedJSON(
                    correction,
                    nanoseconds: 300_000_000
                ),
                .json(loaded),
                .json(loaded),
                .json(correction),
            ]
        )
        let runtime = makeRuntime(
            transport: transport,
            foregroundDeadline: 0.02
        )
        let source = snapshot(text: "this is ready")
        let started = Date()

        let timedOut = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        let deadlineLatency = Date().timeIntervalSince(started)
        let whileDraining = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        let drainingDiagnostics = await runtime.diagnostics()

        XCTAssertEqual(timedOut.route, .foregroundTimeout)
        XCTAssertNil(timedOut.suggestion)
        XCTAssertLessThan(deadlineLatency, 0.15)
        XCTAssertEqual(whileDraining.route, .modelBusy)
        XCTAssertNil(whileDraining.suggestion)
        XCTAssertEqual(drainingDiagnostics.observedPeakModelConcurrency, 1)
        XCTAssertEqual(drainingDiagnostics.totalModelCalls, 1)
        XCTAssertEqual(source.text, "this is ready")

        try? await Task.sleep(nanoseconds: 350_000_000)
        let afterDrain = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        let finalDiagnostics = await runtime.diagnostics()

        XCTAssertEqual(afterDrain.route, .loadedForeground)
        XCTAssertEqual(afterDrain.suggestion?.replacementText, "This is ready.")
        XCTAssertEqual(finalDiagnostics.observedPeakModelConcurrency, 1)
        XCTAssertEqual(finalDiagnostics.totalModelCalls, 2)
    }

    func testCallerCancellationNeverReturnsLateSuggestion() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .json(#"{"models":[{"name":"test-model","context_length":2048}]}"#),
                .uncooperativeDelayedJSON(
                    #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"This is ready.\"}"}}"#,
                    nanoseconds: 300_000_000
                ),
            ]
        )
        let runtime = makeRuntime(
            transport: transport,
            foregroundDeadline: 1
        )
        let source = snapshot(text: "this is ready")
        let request = Task {
            await runtime.requestCorrection(
                snapshot: source,
                context: context(for: source)
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = Date()

        request.cancel()
        let result = await request.value
        let cancellationLatency = Date().timeIntervalSince(cancelledAt)

        XCTAssertEqual(result.route, .foregroundNoSuggestion)
        XCTAssertEqual(result.suppressionReason, "cancelled")
        XCTAssertNil(result.suggestion)
        XCTAssertLessThan(cancellationLatency, 0.15)
        XCTAssertEqual(source.text, "this is ready")
    }

    func testProbeDeadlineDoesNotAwaitUncooperativeTransport() async {
        let transport = FakeTypingAssistantTransport(
            responses: [
                .uncooperativeDelayedJSON(
                    #"{"models":[]}"#,
                    nanoseconds: 300_000_000
                ),
                .json(#"{"done":true}"#),
            ]
        )
        let runtime = makeRuntime(
            transport: transport,
            probeDeadline: 0.02
        )
        let source = snapshot(text: "this is ready")
        let started = Date()

        let result = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.route, .probeFailure)
        XCTAssertNil(result.suggestion)
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(source.text, "this is ready")
    }

    func testLoopbackURLSessionDeadlineIsHardAndCancelsRequest() async throws {
        let server = try LoopbackHTTPTestServer { path in
            switch path {
            case "/api/ps":
                return .init(
                    body: #"{"models":[{"name":"test-model","context_length":2048}]}"#
                )
            case "/api/chat":
                return .init(
                    body:
                        #"{"message":{"content":"{\"action\":\"correct\",\"text\":\"This is ready.\"}"}}"#,
                    delay: 0.3
                )
            default:
                return .init(body: #"{"done":true}"#)
            }
        }
        let endpoint = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            server.stop()
        }
        let runtime = makeRuntime(
            transport: URLSessionTypingAssistantTransport(session: session),
            endpoint: endpoint,
            foregroundDeadline: 0.03
        )
        let source = snapshot(text: "this is ready")
        let started = Date()

        let result = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.route, .foregroundTimeout)
        XCTAssertNil(result.suggestion)
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(source.text, "this is ready")

        var observedClientClosure = false
        for _ in 0..<100 {
            if server.clientClosureCount(for: "/api/chat") > 0 {
                observedClientClosure = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observedClientClosure)
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
                .uncooperativeDelayedJSON(
                    #"{"done":true}"#,
                    nanoseconds: 80_000_000
                ),
                .json(#"{"models":[]}"#),
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
        try? await Task.sleep(nanoseconds: 100_000_000)
        let third = await runtime.requestCorrection(
            snapshot: source,
            context: context(for: source)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let diagnostics = await runtime.diagnostics()

        XCTAssertEqual(first.route, .unloadedBackgroundWarmup)
        XCTAssertEqual(second.route, .unloadedBackgroundWarmup)
        XCTAssertEqual(third.route, .unloadedBackgroundWarmup)
        XCTAssertNil(first.suggestion)
        XCTAssertNil(second.suggestion)
        XCTAssertNil(third.suggestion)
        XCTAssertEqual(diagnostics.backgroundWarmups, 1)
        XCTAssertEqual(diagnostics.observedPeakModelConcurrency, 1)
        XCTAssertEqual(diagnostics.totalModelCalls, 2)
        XCTAssertEqual(diagnostics.fallbackTextMutationCount, 0)
        XCTAssertEqual(diagnostics.fabricatedFallbackCorrectionCount, 0)
        XCTAssertEqual(source.text, "this is ready")
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
        transport: LocalTypingAssistantTransport,
        endpoint: URL = URL(string: "http://127.0.0.1:11434")!,
        probeDeadline: TimeInterval = 0.1,
        foregroundDeadline: TimeInterval = 0.2,
        backgroundDeadline: TimeInterval = 0.2
    ) -> LocalTypingAssistantRuntime {
        LocalTypingAssistantRuntime(
            configuration: LocalTypingAssistantConfiguration(
                endpoint: endpoint,
                model: "test-model",
                contextLength: 2_048,
                keepAlive: "5m",
                probeDeadline: probeDeadline,
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
        case uncooperativeDelayedJSON(String, nanoseconds: UInt64)
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
        case let .uncooperativeDelayedJSON(value, nanoseconds):
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(nanoseconds))
                ) {
                    continuation.resume()
                }
            }
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
