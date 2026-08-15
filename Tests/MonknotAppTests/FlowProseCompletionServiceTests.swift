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
        XCTAssertNil(result)
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

        XCTAssertEqual(result, " by keeping the next idea in view.")
        XCTAssertEqual(snapshot.request, request)
        XCTAssertEqual(
            snapshot.maximumResponseTokens,
            FlowProseCompletionService.maximumResponseTokens
        )
    }

    func testNilAndThrownClientResultsFailClosed() async throws {
        let request = try XCTUnwrap(FlowProseCompletionRequest(context: "A draft"))
        let nilService = FlowProseCompletionService { _, _ in nil }
        let throwingService = FlowProseCompletionService { _, _ in
            throw FlowProseCompletionTestError.failed
        }

        let nilResult = await nilService.completion(for: request)
        let thrownResult = await throwingService.completion(for: request)
        XCTAssertNil(nilResult)
        XCTAssertNil(thrownResult)
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

    func testSanitizerRejectsLineBreaksMarkdownAndLinks() {
        let invalid = [
            "will\ninterrupt typing",
            "**will interrupt typing**",
            "[the next idea](https://example.com)",
            "`inline code`",
            "<em>formatted text</em>",
            "- a list item",
            "1. a numbered item",
            "visit https://example.com"
        ]

        for candidate in invalid {
            XCTAssertNil(
                FlowProseCompletionSanitizer.sanitize(candidate, context: "This"),
                "Expected rejection for: \(candidate)"
            )
        }
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
        let thirteenWords = (1...13).map { "word\($0)" }.joined(separator: " ") + "."
        let expected = " " + (1...12).map { "word\($0)" }.joined(separator: " ")

        XCTAssertEqual(
            FlowProseCompletionSanitizer.sanitize(thirteenWords, context: "Continue"),
            expected
        )
        XCTAssertNil(FlowProseCompletionSanitizer.sanitize(
            String(repeating: "a", count: 97),
            context: "Continue"
        ))
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
