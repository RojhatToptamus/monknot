import AppKit
import XCTest
@testable import MonknotApp

@MainActor
final class FlowRealAPIProbeTests: XCTestCase {
    private static let fixedAIIDs = (1...10).map { index in
        String(format: "repair-ai-%03d", index)
    }

    private static let fixedSpellCheckerIDs = (1...10).map { index in
        String(format: "repair-exact-%03d", index)
    }

    func testOptInFoundationModelsCorpusReturnsTypedTerminalOutcomesWithinDeadline() async throws {
        guard ProcessInfo.processInfo.environment["MONKNOT_RUN_FOUNDATION_MODELS"] == "1" else {
            throw XCTSkip("Set MONKNOT_RUN_FOUNDATION_MODELS=1 on a supported Mac to run the real model probe.")
        }

        let service = FlowSentenceRepairService.system
        let locale = Locale(identifier: "en_US")
        guard service.isAvailable(for: locale) else {
            throw XCTSkip("Foundation Models is not available for the fixed en_US probe corpus.")
        }

        let cases = try Self.fixedAIIDs.map { id in
            try XCTUnwrap(
                FlowWritingCorpus.repairCases.first { $0.id == id },
                "Missing fixed real-model corpus case \(id)"
            )
        }
        XCTAssertEqual(cases.count, 10)
        var responseCount = 0
        var successCount = 0

        for testCase in cases {
            let request = try XCTUnwrap(FlowSentenceRepairRequest(
                sentence: testCase.input,
                locale: locale
            ))
            let startedAt = ContinuousClock.now
            let outcome = await service.repair(for: request)
            let elapsed = startedAt.duration(to: .now)
            let elapsedMilliseconds = elapsedMilliseconds(elapsed)
            let elapsedText = String(format: "%.1f", elapsedMilliseconds)
            let proposal: String
            switch outcome {
            case let .success(value):
                responseCount += 1
                successCount += 1
                proposal = String(reflecting: value)
            case .validationRejected:
                responseCount += 1
                proposal = "none"
            case .unavailable, .failed, .timedOut:
                proposal = "none"
            }

            XCTAssertLessThanOrEqual(
                elapsedMilliseconds,
                7_500,
                "Real model request exceeded its service deadline for \(testCase.id)"
            )
            print(
                "FLOW_REAL_FOUNDATION_MODEL case=\(testCase.id) "
                    + "outcome=\(label(for: outcome)) "
                    + "elapsedMs=\(elapsedText) "
                    + "proposal=\(proposal)"
            )
        }
        XCTAssertGreaterThan(responseCount, 0, "The available model returned no response for the fixed corpus")
        XCTAssertGreaterThan(successCount, 0, "The available model returned no usable sanitized proposal")
    }

    func testOptInNSSpellCheckerCorpusReturnsBoundedWellFormedResults() async throws {
        guard ProcessInfo.processInfo.environment["MONKNOT_RUN_NSSPELLCHECKER"] == "1" else {
            throw XCTSkip("Set MONKNOT_RUN_NSSPELLCHECKER=1 to run the real NSSpellChecker probe.")
        }

        let cases = try Self.fixedSpellCheckerIDs.map { id in
            try XCTUnwrap(
                FlowWritingCorpus.repairCases.first { $0.id == id },
                "Missing fixed spell-checker corpus case \(id)"
            )
        }
        XCTAssertEqual(cases.count, 10)
        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { NSSpellChecker.shared.closeSpellDocument(withTag: documentTag) }
        var totalResultCount = 0
        var orthographyResponseCount = 0

        for testCase in cases {
            let response = expectation(description: "NSSpellChecker response for \(testCase.id)")
            let capture = RealSpellCheckCapture()
            let source = testCase.input as NSString
            let startedAt = ContinuousClock.now
            EditorFlowCheckingClient.system.request(
                testCase.input,
                NSRange(location: 0, length: source.length),
                EditorFlowCheckingTypes.value(for: EditorTextCheckingOptions(
                    checksSpelling: true,
                    checksGrammar: true,
                    inlinePredictions: false
                )),
                documentTag
            ) { results, orthography in
                capture.store(results: results, orthography: orthography)
                response.fulfill()
            }
            await fulfillment(of: [response], timeout: 5)
            let elapsedMilliseconds = elapsedMilliseconds(startedAt.duration(to: .now))
            let snapshot = try XCTUnwrap(
                capture.snapshot,
                "NSSpellChecker did not return a terminal response for \(testCase.id)"
            )
            let orthographyLabel = snapshot.orthography == nil ? "nil" : "present"
            let elapsedText = String(format: "%.1f", elapsedMilliseconds)
            totalResultCount += snapshot.results.count
            if snapshot.orthography != nil {
                orthographyResponseCount += 1
            }

            XCTAssertLessThanOrEqual(
                elapsedMilliseconds,
                5_000,
                "NSSpellChecker exceeded the probe deadline for \(testCase.id)"
            )
            for result in snapshot.results {
                XCTAssertNotEqual(result.range.location, NSNotFound)
                XCTAssertGreaterThanOrEqual(result.range.location, 0)
                XCTAssertLessThanOrEqual(
                    NSMaxRange(result.range),
                    source.length,
                    "NSSpellChecker returned an out-of-bounds range for \(testCase.id)"
                )
            }
            print(
                "FLOW_REAL_NSSPELLCHECKER case=\(testCase.id) "
                    + "results=\(snapshot.results.count) "
                    + "orthography=\(orthographyLabel) "
                    + "elapsedMs=\(elapsedText)"
            )
        }
        XCTAssertGreaterThan(totalResultCount, 0, "NSSpellChecker returned no issue results for the fixed corpus")
        XCTAssertGreaterThan(orthographyResponseCount, 0, "NSSpellChecker returned no orthography for the fixed corpus")
    }

    private func label(for outcome: FlowModelOutcome) -> String {
        switch outcome {
        case .success:
            return "success"
        case .unavailable:
            return "unavailable"
        case .failed:
            return "failed"
        case .timedOut:
            return "timedOut"
        case .validationRejected:
            return "validationRejected"
        }
    }

    private func elapsedMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private final class RealSpellCheckCapture: @unchecked Sendable {
    struct Snapshot {
        let results: [NSTextCheckingResult]
        let orthography: NSOrthography?
    }

    private let lock = NSLock()
    private var storedSnapshot: Snapshot?

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func store(results: [NSTextCheckingResult], orthography: NSOrthography?) {
        lock.lock()
        storedSnapshot = Snapshot(results: results, orthography: orthography)
        lock.unlock()
    }
}
