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
        XCTAssertNotNil(FlowSentenceRepairRequest(sentence: "First line\ncontinues here."))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "\nFirst line continues here."))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "First line continues here.\n"))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "First line\n\nSecond line."))
        XCTAssertNil(FlowSentenceRepairRequest(sentence: "First sentence.\nSecond sentence."))
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

        XCTAssertEqual(result, .success("The dogs are playing."))
        XCTAssertEqual(snapshot.request, request)
        XCTAssertEqual(
            snapshot.maximumResponseTokens,
            FlowSentenceRepairService.maximumResponseTokens
        )
    }

    func testSanitizerRejectsEqualNewlineInvisibleOversizedAndMoreThanTwoSentences() {
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
            "The dogs are playing. They are outside. We should leave.",
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
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                "The dogs are playing. They are outside.",
                originalSentence: "The dogs is playing and they is outside."
            ),
            "The dogs are playing. They are outside."
        )
    }

    func testHardWrappedRepairPreservesExactLineBreakStructure() async throws {
        let original = "The release managers cheked every backup,  \n    and the support lead confirms the list."
        let corrected = "The release managers checked every backup,  \n    and the support lead confirmed the list."
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: original,
            locale: Locale(identifier: "en_US")
        ))
        let service = FlowSentenceRepairService { received, _ in
            XCTAssertEqual(received.sentence, original)
            return corrected
        }

        let result = await service.repair(for: request)
        let joinedLineService = FlowSentenceRepairService { _, _ in
            corrected.replacingOccurrences(of: "\n", with: " ")
        }
        let joinedLineResult = await joinedLineService.repair(for: request)
        let removedHardBreakSpacesService = FlowSentenceRepairService { _, _ in
            corrected.replacingOccurrences(of: "  \n", with: "\n")
        }
        let removedHardBreakSpacesResult = await removedHardBreakSpacesService.repair(for: request)
        let changedContinuationIndentService = FlowSentenceRepairService { _, _ in
            corrected.replacingOccurrences(of: "\n    ", with: "\n  ")
        }
        let changedContinuationIndentResult = await changedContinuationIndentService.repair(
            for: request
        )

        XCTAssertEqual(result, .success(corrected))
        XCTAssertEqual(joinedLineResult, .validationRejected)
        XCTAssertEqual(removedHardBreakSpacesResult, .validationRejected)
        XCTAssertEqual(changedContinuationIndentResult, .validationRejected)
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            corrected.replacingOccurrences(of: "\n", with: " "),
            originalSentence: original
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            corrected.replacingOccurrences(of: "\n", with: "\r\n"),
            originalSentence: original
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            corrected.replacingOccurrences(of: "\n", with: "\n\n"),
            originalSentence: original
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "The release managers checked every  \n    backup, and the support lead confirmed the list.",
            originalSentence: original
        ))
    }

    func testHardWrappedRepairAllowsWordCountChangesAwayFromBoundaryAnchors() async throws {
        let original = "We need send the draft\nbefore noon."
        let corrected = "We need to send the draft\nbefore noon."
        let duplicateOriginal = "We need need to send the draft\nbefore noon."
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: original,
            locale: Locale(identifier: "en_US")
        ))
        let service = FlowSentenceRepairService { _, _ in corrected }

        let result = await service.repair(for: request)

        XCTAssertEqual(result, .success(corrected))
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                corrected,
                originalSentence: duplicateOriginal
            ),
            corrected
        )
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "We need to send the\nbefore draft noon.",
            originalSentence: original
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "We need to send the draftbefore\nnoon.",
            originalSentence: original
        ))
    }

    func testHardWrappedRepairKeepsBoundaryOwnershipWhileDeferringWordValidation() {
        let original = "Please revieiw\nthe draft before noon."
        let corrected = "Please review\nthe draft before noon."
        let grammarOriginal = "The dogs\nis"
        let grammarCorrected = "The dogs\nare"

        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                corrected,
                originalSentence: original
            ),
            corrected
        )
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                grammarCorrected,
                originalSentence: grammarOriginal
            ),
            grammarCorrected
        )
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                "The dogs\nare ready.",
                originalSentence: "The dogs\nready."
            ),
            "The dogs\nare ready."
        )
        XCTAssertEqual(
            FlowSentenceRepairSanitizer.sanitize(
                "are.",
                originalSentence: "is."
            ),
            "are."
        )
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "Please review the\ndraft before noon.",
            originalSentence: original
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "Please reviewthe\ndraft before noon.",
            originalSentence: "Please review\nthe draft before noon."
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "The dogs are\nready.",
            originalSentence: "The dogs\nis ready."
        ))
        XCTAssertNil(FlowSentenceRepairSanitizer.sanitize(
            "The dogs are ready.",
            originalSentence: "The dogs\nis ready."
        ))
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
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(callCount, 0)
    }

    func testNilAndThrownClientResultsReportFailure() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let nilService = FlowSentenceRepairService { _, _ in nil }
        let throwingService = FlowSentenceRepairService { _, _ in
            throw FlowSentenceRepairTestError.failed
        }

        let nilResult = await nilService.repair(for: request)
        let thrownResult = await throwingService.repair(for: request)
        XCTAssertEqual(nilResult, .failed)
        XCTAssertEqual(thrownResult, .failed)
    }

    func testSanitizerRejectionReturnsTypedOutcome() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let service = FlowSentenceRepairService { _, _ in
            "The dogs is playig."
        }

        let result = await service.repair(for: request)
        XCTAssertEqual(result, .validationRejected)
    }

    func testClientTimeoutReturnsWithoutWaitingForNoncooperativeWork() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let service = FlowSentenceRepairService(
            timeoutNanoseconds: 10_000_000,
            client: { _, _ in
                await flowSentenceRepairNonCooperativeDelay()
                return "The dogs are playing."
            }
        )
        let start = ContinuousClock.now

        let result = await service.repair(for: request)

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    func testTimedOutClientKeepsCopiedServiceAdmissionUntilUnderlyingCallEnds() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let client = FlowSentenceRepairBlockingClient()
        let service = FlowSentenceRepairService(
            timeoutNanoseconds: 10_000_000,
            client: { _, _ in await client.response() }
        )
        let copiedService = service

        let timedOutResult = await service.repair(for: request)
        let busyResult = await copiedService.repair(for: request)
        let callCountWhileBusy = await client.callCount
        XCTAssertEqual(timedOutResult, .timedOut)
        XCTAssertEqual(busyResult, .unavailable)
        XCTAssertEqual(callCountWhileBusy, 1)

        await client.releaseFirstCall()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var laterResult = await copiedService.repair(for: request)
        while laterResult == .unavailable, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            laterResult = await copiedService.repair(for: request)
        }

        let finalCallCount = await client.callCount
        XCTAssertEqual(laterResult, .success("The dogs are playing."))
        XCTAssertEqual(finalCallCount, 2)
    }

    func testCancellationReturnsWithoutWaitingForClient() async throws {
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: "The dogs is playig."
        ))
        let service = FlowSentenceRepairService(
            timeoutNanoseconds: 1_000_000_000,
            client: { _, _ in
                await flowSentenceRepairNonCooperativeDelay()
                return "The dogs are playing."
            }
        )
        let task = Task { await service.repair(for: request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let start = ContinuousClock.now

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failed)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    func testReportedLongMultiErrorSentenceCanReachTypedSuccess() async throws {
        let original = "I am nt be able to come today because yesterday I got sick so badly and now cannot get out of the bed wirhgth now."
        let corrected = "I am not able to come today because yesterday I got so sick that I cannot get out of bed now."
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: original,
            locale: Locale(identifier: "en_US")
        ))
        let service = FlowSentenceRepairService { received, _ in
            XCTAssertEqual(received.sentence, original)
            return corrected
        }

        let result = await service.repair(for: request)
        XCTAssertEqual(result, .success(corrected))
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

private actor FlowSentenceRepairBlockingClient {
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func response() async -> String? {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        return "The dogs are playing."
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

private func flowSentenceRepairNonCooperativeDelay() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            continuation.resume()
        }
    }
}
