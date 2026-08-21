import Foundation
import XCTest
@testable import MonknotApp

final class FlowProseCompletionServiceTests: XCTestCase {
    func testRequestEnforcesBoundAndRejectsNonWhitespaceControls() {
        let locale = Locale(identifier: "en_US")
        let exactBound = String(
            repeating: "a",
            count: FlowProseCompletionRequest.maximumContextUTF16Length
        )

        let request = FlowProseCompletionRequest(context: exactBound, locale: locale)
        XCTAssertEqual(request?.context, exactBound)
        XCTAssertEqual(request?.locale.identifier, locale.identifier)
        XCTAssertNotNil(FlowProseCompletionRequest(context: "First line\nSecond line"))

        XCTAssertNil(FlowProseCompletionRequest(context: " \n\t "))
        XCTAssertNil(FlowProseCompletionRequest(context: exactBound + "a"))
        XCTAssertNil(FlowProseCompletionRequest(context: "unsafe\u{0000}context"))
    }

    func testAvailabilityIsInjectableAndCompletionRechecksIt() async throws {
        let recorder = FlowProseCompletionRecorder()
        let service = FlowProseCompletionService(
            isAvailable: { $0.identifier == "en_US" },
            client: { request, maximumResponseTokens in
                await recorder.record(
                    request: request,
                    maximumResponseTokens: maximumResponseTokens
                )
                return "unused"
            }
        )

        XCTAssertTrue(service.isAvailable(for: Locale(identifier: "en_US")))
        XCTAssertFalse(service.isAvailable(for: Locale(identifier: "fr_FR")))

        let unavailableRequest = try XCTUnwrap(FlowProseCompletionRequest(
            context: "Bonjour",
            locale: Locale(identifier: "fr_FR")
        ))
        let result = await service.completion(for: unavailableRequest)
        let callCount = await recorder.callCount
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(callCount, 0)
    }

    func testInjectedCompletionReceivesTokenLimitAndSanitizesModelOutput() async throws {
        let recorder = FlowProseCompletionRecorder()
        let service = FlowProseCompletionService { request, maximumResponseTokens in
            await recorder.record(
                request: request,
                maximumResponseTokens: maximumResponseTokens
            )
            return "“We can write faster by keeping the next idea in view.”"
        }
        let request = try XCTUnwrap(FlowProseCompletionRequest(
            context: "We can write faster",
            locale: Locale(identifier: "en_US")
        ))

        let result = await service.completion(for: request)
        let snapshot = await recorder.snapshot()

        XCTAssertEqual(result, .success(" by keeping the next idea in view."))
        XCTAssertEqual(snapshot.request, request)
        XCTAssertEqual(
            snapshot.maximumResponseTokens,
            FlowProseCompletionService.maximumResponseTokens
        )
    }

    func testNilAndThrownClientResultsReportFailure() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let nilService = FlowProseCompletionService { _, _ in nil }
        let throwingService = FlowProseCompletionService { _, _ in
            throw FlowProseCompletionTestError.failed
        }

        let nilResult = await nilService.completion(for: request)
        let thrownResult = await throwingService.completion(for: request)
        XCTAssertEqual(nilResult, .failed)
        XCTAssertEqual(thrownResult, .failed)
    }

    func testSanitizerStripsWrappingQuotesNewlinesAndRepeatedContext() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "\n \"will help the reader.\" \n",
                context: "A concise opening"
            ),
            " will help the reader."
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "A clear draft keeps the whole team moving toward a decision",
                context: "A clear draft keeps the whole team moving"
            ),
            " toward a decision"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "the whole team moving toward a decision",
                context: "A clear draft keeps the whole team moving"
            ),
            " toward a decision"
        )
    }

    func testServiceRejectsTypoCorrectedRestatementOfContext() async throws {
        let service = FlowProseCompletionService { _, _ in
            "Hello, I’m writing this to express that I’m…"
        }
        let request = try XCTUnwrap(FlowProseCompletionRequest(
            context: "Hello im wiritng this to exprs that"
        ))

        let completion = await service.completion(for: request)

        XCTAssertEqual(completion, .validationRejected)
    }

    func testSanitizerRejectsRestatementAfterShortPreface() {
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "and Hello, I’m writing this to express that I’m ready.",
                context: "Hello im wiritng this to exprs that"
            )
        )
    }

    func testSanitizerDoesNotEncodeAuthoredTopicVocabulary() {
        let context = "We can outline why public parks matter in dense cities."
        let structurallySafeCompletions = [
            "Public parks are important for every neighborhood.",
            "Public parks play a key role downtown.",
            "Public parks remain vital to urban health.",
        ]

        for candidate in structurallySafeCompletions {
            XCTAssertEqual(
                FlowProseCompletionSanitizer.sanitize(candidate, context: context),
                " \(candidate)"
            )
        }
    }

    func testSanitizerAllowsSpecificTopicContinuations() {
        let context = "We can outline why public parks matter in dense cities."

        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "That makes equal access the first planning question.",
                context: context
            ),
            " That makes equal access the first planning question."
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "Survey data from outer districts would sharpen the argument.",
                context: context
            ),
            " Survey data from outer districts would sharpen the"
        )
    }

    func testSanitizerRejectsShortCorrectionOfTextBeforeCaret() {
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "writing clearly.",
                context: "I am writng"
            )
        )
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "the next step.",
                context: "We already chose the"
            )
        )
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "the next step.",
                context: "We typed teh"
            )
        )
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "and then continue.",
                context: "We agreed adn"
            )
        )
    }

    func testSanitizerRejectsRepeatedEarlierExactClause() {
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "A focused draft helps readers decide before lunch.",
                context: "A focused draft helps readers decide. After that we compare the options with the budget timeline owners risks evidence and launch criteria"
            )
        )
    }

    func testSanitizerRejectsCaseAndUnicodeApostropheRestatement() {
        XCTAssertNil(
            FlowProseCompletionSanitizer.sanitize(
                "When I’m clear about the goal, the team can move.",
                context: "WHEN IM CLEAR ABOUT THE GOAL we move faster"
            )
        )
    }

    func testSanitizerAllowsContinuationsWithOnlyBridgeWordsInCommon() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "that this time we should ask for customer feedback",
                context: "We agreed that this direction gives the team a stable plan"
            ),
            " that this time we should ask for customer"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "the plan should leave room for revision",
                context: "The plan from yesterday needs one more review"
            ),
            " the plan should leave room for revision"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "We can make every section easier to scan",
                context: "We can make this useful for readers"
            ),
            " We can make every section easier to scan"
        )
    }

    func testSanitizerRejectsLineBreaksMarkdownAndLinks() {
        let invalid = [
            "will\ninterrupt typing",
            "**will interrupt typing**",
            "[the next idea](https://example.com)",
            "`inline code`",
            "<em>formatted text</em>",
            "- a list item",
            "1. a numbered item",
            "1) another numbered item",
            "visit https://example.com",
            "email editor@example.com tomorrow",
            "open example.com/path",
            "open example.com?x=1",
            "open example.com#fragment",
            "open example.com/path?x=1#fragment",
            "?x=1",
            "#fragment",
            "connect to 192.0.2.1/path",
        ]

        for candidate in invalid {
            XCTAssertNil(
                FlowProseCompletionSanitizer.sanitize(candidate, context: "This"),
                "Expected rejection for: \(candidate)"
            )
        }
    }

    func testSanitizerAllowsDecimalAndVersionNearMisses() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "version 2.1 improves the draft",
                context: "This"
            ),
            " version 2.1 improves the draft"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(
                "the ratio stays 3.2 to 1",
                context: "This"
            ),
            " the ratio stays 3.2 to 1"
        )
    }

    func testSanitizerRejectsInvisibleAndDirectionChangingScalars() {
        let invalid = [
            "hidden\u{0000}control",
            "zero\u{200B}width",
            "direction\u{202E}override",
            "private\u{E000}use",
        ]

        for candidate in invalid {
            XCTAssertNil(
                FlowProseCompletionSanitizer.sanitize(candidate, context: "This"),
                "Expected rejection for invisible or unsafe scalar in: \(candidate.debugDescription)"
            )
        }
    }

    func testSanitizerCapsAtWordAndGraphemeBoundaries() {
        let nineWords = (1...9).map { "word\($0)" }.joined(separator: " ") + "."
        let expected = " " + (1...8).map { "word\($0)" }.joined(separator: " ")

        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(nineWords, context: "Continue"),
            expected
        )
        XCTAssertNil(FlowProseCompletionSanitizer.sanitize(
            String(repeating: "a", count: 65),
            context: "Continue"
        ))
    }

    func testSanitizerRejectionReturnsTypedOutcome() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let service = FlowProseCompletionService { _, _ in
            "**a Markdown continuation**"
        }

        let result = await service.completion(for: request)
        XCTAssertEqual(result, .validationRejected)
    }

    func testClientTimeoutReturnsWithoutWaitingForNoncooperativeWork() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let service = FlowProseCompletionService(
            timeoutNanoseconds: 10_000_000,
            client: { _, _ in
                await flowProseCompletionNonCooperativeDelay()
                return "can become clearer."
            }
        )
        let start = ContinuousClock.now

        let result = await service.completion(for: request)

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    func testTimedOutClientKeepsCopiedServiceAdmissionUntilUnderlyingCallEnds() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let client = FlowProseCompletionBlockingClient()
        let service = FlowProseCompletionService(
            timeoutNanoseconds: 10_000_000,
            client: { _, _ in await client.response() }
        )
        let copiedService = service

        let timedOutResult = await service.completion(for: request)
        let busyResult = await copiedService.completion(for: request)
        let callCountWhileBusy = await client.callCount
        XCTAssertEqual(timedOutResult, .timedOut)
        XCTAssertEqual(busyResult, .unavailable)
        XCTAssertEqual(callCountWhileBusy, 1)

        await client.releaseFirstCall()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var laterResult = await copiedService.completion(for: request)
        while laterResult == .unavailable, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            laterResult = await copiedService.completion(for: request)
        }

        let finalCallCount = await client.callCount
        XCTAssertEqual(laterResult, .success(" can become clearer."))
        XCTAssertEqual(finalCallCount, 2)
    }

    func testCancellationReturnsWithoutWaitingForClient() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let service = FlowProseCompletionService(
            timeoutNanoseconds: 1_000_000_000,
            client: { _, _ in
                await flowProseCompletionNonCooperativeDelay()
                return "can become clearer."
            }
        )
        let task = Task { await service.completion(for: request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let start = ContinuousClock.now

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failed)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    func testSanitizerProducesInsertionReadySpacingWithoutBreakingNoSpaceScripts() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize("world", context: "Hello"),
            " world"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize("world", context: "Hello "),
            "world"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(", then continue", context: "Pause"),
            ", then continue"
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize("世界更好", context: "你好"),
            "世界更好"
        )
    }

    func testNextWordSplitIncludesAdjacentPunctuationAndFollowingHorizontalSpace() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.splitNextWord(
                from: " improving, writing quality"
            ),
            FlowProseCompletionWordSplit(
                acceptedPrefix: " improving, ",
                remainingSuffix: "writing quality"
            )
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.splitNextWord(
                from: " improving—writing quality"
            ),
            FlowProseCompletionWordSplit(
                acceptedPrefix: " improving—",
                remainingSuffix: "writing quality"
            )
        )
        XCTAssertEqual(
            FlowProseCompletionSanitizer.splitNextWord(
                from: " improving,\nwriting quality"
            ),
            FlowProseCompletionWordSplit(
                acceptedPrefix: " improving,",
                remainingSuffix: "\nwriting quality"
            )
        )
    }

    func testNextWordSplitHasSafeGraphemeFallback() {
        XCTAssertEqual(
            FlowProseCompletionSanitizer.splitNextWord(from: " ✨ "),
            FlowProseCompletionWordSplit(
                acceptedPrefix: " ✨ ",
                remainingSuffix: ""
            )
        )
        XCTAssertNil(FlowProseCompletionSanitizer.splitNextWord(from: " \t "))
    }
}

private actor FlowProseCompletionRecorder {
    private(set) var request: FlowProseCompletionRequest?
    private(set) var maximumResponseTokens: Int?
    private(set) var callCount = 0

    func record(
        request: FlowProseCompletionRequest,
        maximumResponseTokens: Int
    ) {
        self.request = request
        self.maximumResponseTokens = maximumResponseTokens
        callCount += 1
    }

    func snapshot() -> (request: FlowProseCompletionRequest?, maximumResponseTokens: Int?) {
        (request, maximumResponseTokens)
    }
}

private enum FlowProseCompletionTestError: Error {
    case failed
}

private actor FlowProseCompletionBlockingClient {
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func response() async -> String? {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        return "can become clearer."
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

private func flowProseCompletionNonCooperativeDelay() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            continuation.resume()
        }
    }
}
