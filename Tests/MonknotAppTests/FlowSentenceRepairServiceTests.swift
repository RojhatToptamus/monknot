import Foundation
import XCTest
@testable import MonknotApp

final class FlowSentenceRepairServiceTests: XCTestCase {
    func testRequestEnforcesSentenceBoundsAndLocale() {
        let locale = Locale(identifier: "en_US")
        let exactBound = String(
            repeating: "a",
            count: FlowSentenceRepairRequest.maximumSentenceUTF16Length
        )

        let request = FlowSentenceRepairRequest(sentence: exactBound, locale: locale)
        XCTAssertEqual(request?.sentence, exactBound)
        XCTAssertEqual(request?.locale.identifier, locale.identifier)

        XCTAssertNil(FlowSentenceRepairRequest(sentence: " \t "))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: exactBound + "a"))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "First line\nSecond line."))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "First sentence. Second sentence."))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "Unsafe\u{200B}sentence."))
    }

    func testTrustedInstructionIsExactAndStable() {
        XCTAssertEqual(
            FlowSentenceRepairService.trustedInstructions,
            "Correct only spelling, grammar, and punctuation. Preserve meaning, tone, names, numbers, Markdown, and sentence structure. Do not add information or paraphrase. Return only the corrected sentence."
        )
    }

    func testInjectedRepairReceivesTokenLimitAndSanitizesWrappingQuotes() async throws {
        let recorder = FlowSentenceRepairRecorder()
        let service = FlowSentenceRepairService { request, maximumResponseTokens in
            await recorder.record(
                request: request,
                maximumResponseTokens: maximumResponseTokens
            )
            return "  “The dogs are playing.”  "
        }
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig.",
            locale: Locale(identifier: "en_US")
        ))

        let result = await service.repair(for: request)
        let snapshot = await recorder.snapshot()

        XCTAssertEqual(result, "The dogs are playing.")
        XCTAssertEqual(snapshot.request, request)
        XCTAssertEqual(
            snapshot.maximumResponseTokens,
            FlowSentenceRepairService.maximumResponseTokens
        )
    }

    func testSanitizerRejectsEqualNewlineInvisibleOversizedAndMultipleSentences() {
        let original = "The dogs is playig."
        let oversized = String(
            repeating: "a",
            count: FlowSentenceRepairRequest.maximumSentenceUTF16Length + 1
        )
        let invalid = [
            original,
            "The dogs are\nplaying.",
            "The dogs are\u{202E}playing.",
            oversized,
            "The dogs are playing. They are outside.",
        ]

        for candidate in invalid {
            XCTAssertNil(
                FlowSentenceRepairSanitizer.sanitize(
                    candidate,
                    originalSentence: original
                ),
                "Expected rejection for: \(candidate.debugDescription)"
            )
        }
    }

    func testSanitizerAcceptsOneChangedSentenceWithClosingPunctuation() {
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                "\n  She asked, “Are the dogs playing?”  \n",
                originalSentence: "She ask, “Is the dogs playig?”"
            ),
            "She asked, “Are the dogs playing?”"
        )
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                "“The dogs are playing.”",
                originalSentence: "“The dogs is playig.”"
            ),
            "“The dogs are playing.”"
        )
    }

    func testUnavailableServiceDoesNotCallClient() async throws {
        let recorder = FlowSentenceRepairRecorder()
        let service = FlowSentenceRepairService(
            isAvailable: { $0.identifier == "en_US" },
            client: { request, maximumResponseTokens in
                await recorder.record(
                    request: request,
                    maximumResponseTokens: maximumResponseTokens
                )
                return "unused"
            }
        )
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "Les chiens joue.",
            locale: Locale(identifier: "fr_FR")
        ))

        XCTAssertFalse(service.isAvailable(for: request.locale))
        let result = await service.repair(for: request)
        let callCount = await recorder.callCount
        XCTAssertNil(result)
        XCTAssertEqual(callCount, 0)
    }

    func testNilAndThrownClientResultsFailClosed() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let nilService = FlowSentenceRepairService { _, _ in nil }
        let throwingService = FlowSentenceRepairService { _, _ in
            throw FlowSentenceRepairTestError.failed
        }

        let nilResult = await nilService.repair(for: request)
        let thrownResult = await throwingService.repair(for: request)
        XCTAssertNil(nilResult)
        XCTAssertNil(thrownResult)
    }
}

private actor FlowSentenceRepairRecorder {
    private(set) var request: FlowSentenceRepairRequest?
    private(set) var maximumResponseTokens: Int?
    private(set) var callCount = 0

    func record(
        request: FlowSentenceRepairRequest,
        maximumResponseTokens: Int
    ) {
        self.request = request
        self.maximumResponseTokens = maximumResponseTokens
        callCount += 1
    }

    func snapshot() -> (request: FlowSentenceRepairRequest?, maximumResponseTokens: Int?) {
        (request, maximumResponseTokens)
    }
}

private enum FlowSentenceRepairTestError: Error {
    case failed
}
