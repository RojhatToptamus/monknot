import Foundation
import XCTest
@testable import MonknotApp

final class FlowWritingCorpusTests: XCTestCase {
    func testSplitMix64SeedAndFrozenOrderingRemainStable() {
        XCTAssertEqual(FlowWritingCorpus.seed, 0x4D4F_4E4B_4E4F_5421)

        var generator = FlowWritingSplitMix64(seed: FlowWritingCorpus.seed)
        XCTAssertEqual(generator.next(), 0x42D6_113D_9492_2BBB)
        XCTAssertEqual(generator.next(), 0x2594_2435_AB02_D401)
        XCTAssertEqual(generator.next(), 0xE78B_100F_8F83_BD0A)

        XCTAssertEqual(FlowWritingCorpus.repairCases.count, 60)
        XCTAssertEqual(FlowWritingCorpus.repairCases.first?.id, "repair-exact-018")
        XCTAssertEqual(FlowWritingCorpus.repairCases.last?.id, "repair-ai-004")
        XCTAssertEqual(FlowWritingCorpus.autocompleteCases.count, 24)
        XCTAssertEqual(
            FlowWritingCorpus.autocompleteCases.first?.id,
            "autocomplete-useful-002"
        )
        XCTAssertEqual(
            FlowWritingCorpus.autocompleteCases.last?.id,
            "autocomplete-useful-005"
        )
    }

    func testRepairCorpusHasRequiredClassificationsAndUniqueStableIDs() {
        let cases = FlowWritingCorpus.repairCases
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        XCTAssertEqual(cases.filter { $0.expectation == .exactDeterministic }.count, 24)
        XCTAssertEqual(cases.filter { $0.expectation == .aiInvariant }.count, 20)
        XCTAssertEqual(cases.filter { $0.expectation == .protectedUnsafe }.count, 10)
        XCTAssertEqual(cases.filter { $0.expectation == .clean }.count, 6)
        XCTAssertGreaterThanOrEqual(cases.filter(\.isMultiError).count, 24)
        XCTAssertEqual(cases.filter(\.isLongOrHardWrapped).count, 12)

        for testCase in cases {
            XCTAssertFalse(testCase.id.isEmpty)
            XCTAssertEqual(
                FlowWritingCorpus.applyMutationManifest(
                    testCase.mutationManifest,
                    to: testCase.referenceText
                ),
                testCase.input,
                "Generated mutation input drifted: \(testCase.id)"
            )
            if testCase.referenceText != testCase.input {
                XCTAssertFalse(testCase.mutationManifest.isEmpty, testCase.id)
            }
            XCTAssertGreaterThanOrEqual(
                testCase.wordCount,
                5,
                "Too short: \(testCase.id)"
            )
            XCTAssertLessThanOrEqual(
                testCase.wordCount,
                150,
                "Too long: \(testCase.id)"
            )
            for anchor in testCase.preservedAnchors {
                XCTAssertTrue(
                    testCase.input.contains(anchor),
                    "Input lost anchor \(anchor.debugDescription): \(testCase.id)"
                )
                XCTAssertTrue(
                    testCase.referenceText.contains(anchor),
                    "Reference lost anchor \(anchor.debugDescription): \(testCase.id)"
                )
            }

            switch testCase.expectation {
            case .exactDeterministic:
                XCTAssertNotEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(testCase.expectedFinalText, testCase.referenceText, testCase.id)
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertTrue(testCase.protectedFragments.isEmpty, testCase.id)
            case .aiInvariant:
                XCTAssertNotEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(
                    testCase.expectedFinalText,
                    testCase.conservativeCandidateFixture ?? testCase.referenceText,
                    testCase.id
                )
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertTrue(testCase.protectedFragments.isEmpty, testCase.id)
            case .protectedUnsafe:
                XCTAssertNotEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(testCase.expectedFinalText, testCase.input, testCase.id)
                XCTAssertFalse(testCase.mutationManifest.isEmpty, testCase.id)
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertFalse(testCase.protectedFragments.isEmpty, testCase.id)
                for fragment in testCase.protectedFragments {
                    XCTAssertTrue(testCase.input.contains(fragment), testCase.id)
                }
            case .clean:
                XCTAssertEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(testCase.expectedFinalText, testCase.input, testCase.id)
                XCTAssertTrue(testCase.mutations.isEmpty, testCase.id)
                XCTAssertTrue(testCase.protectedFragments.isEmpty, testCase.id)
            }

            if testCase.isLongOrHardWrapped {
                XCTAssertTrue(
                    testCase.wordCount >= 20 || testCase.input.contains("\n"),
                    "Long fixture is neither long nor hard-wrapped: \(testCase.id)"
                )
            }
        }

        XCTAssertEqual(cases.map(\.wordCount).min(), 5)
        XCTAssertEqual(cases.map(\.wordCount).max(), 150)
    }

    func testRepairCorpusCoversEveryDomainAndRequestedMutation() {
        XCTAssertEqual(
            Set(FlowWritingCorpus.repairCases.map(\.domain)),
            Set(FlowWritingDomain.allCases)
        )
        XCTAssertEqual(
            Set(FlowWritingCorpus.repairCases.flatMap(\.mutations)),
            Set(FlowWritingMutationKind.allCases)
        )

        let aiCases = FlowWritingCorpus.repairCases.filter { $0.expectation == .aiInvariant }
        XCTAssertEqual(aiCases.count, 20)
        XCTAssertTrue(aiCases.contains { $0.mutations.contains(.duplicatedWord) })
        XCTAssertTrue(aiCases.contains { $0.mutations.contains(.localReorder) })
        XCTAssertTrue(aiCases.contains { $0.mutations.contains(.runOnClause) })

        let generated = FlowWritingCorpus.repairCases.first { $0.id == "repair-ai-001" }
        XCTAssertEqual(
            generated?.input,
            "My ankle did nt improve overnight after the new exercises the swelling look worse and the clinic have not replyed yet."
        )
        XCTAssertEqual(
            generated?.conservativeCandidateFixture,
            "My ankle did not improve overnight after the new exercises; the swelling looks worse, and the clinic has not replied yet."
        )
    }

    func testAutocompleteCorpusHasExpectedCasesAndRequiredRegressions() {
        let cases = FlowWritingCorpus.autocompleteCases
        XCTAssertEqual(Set(cases.map(\.id)).count, 24)
        XCTAssertEqual(cases.filter { $0.expectation == .useful }.count, 9)
        XCTAssertEqual(cases.filter { $0.expectation == .restatementOrGeneric }.count, 7)
        XCTAssertEqual(cases.filter { $0.expectation == .unsafe }.count, 8)

        for testCase in cases {
            XCTAssertFalse(testCase.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(testCase.modelOutput.isEmpty)
            switch testCase.expectation {
            case .useful:
                let continuation = testCase.expectedContinuation
                XCTAssertNotNil(continuation, testCase.id)
                XCTAssertLessThanOrEqual(testCase.modelOutput.count, 96, testCase.id)
                XCTAssertLessThanOrEqual(wordCount(in: testCase.modelOutput), 12, testCase.id)
                XCTAssertFalse(testCase.modelOutput.contains("\n"), testCase.id)
            case .restatementOrGeneric, .unsafe:
                XCTAssertNil(testCase.expectedContinuation, testCase.id)
            }
        }

        let restatement = cases.first { $0.id == "autocomplete-restatement-001" }
        XCTAssertEqual(restatement?.context, "Hello im wiritng this to exprs that")
        XCTAssertEqual(
            restatement?.modelOutput,
            "Hello, I’m writing this to express that I’m…"
        )
        XCTAssertTrue(cases.contains {
            $0.context == "We typed teh" && $0.modelOutput == "the next step"
        })
        XCTAssertTrue(cases.contains {
            $0.context == "We agreed adn" && $0.modelOutput == "and continue"
        })
        XCTAssertTrue(cases.contains {
            $0.expectation == .useful
                && $0.context.localizedCaseInsensitiveContains("public parks")
        })
    }

    func testAutocompleteCorpusRunsThroughProductionSanitizer() {
        for testCase in FlowWritingCorpus.autocompleteCases {
            let actual = FlowProseCompletionSanitizer.sanitize(
                testCase.modelOutput,
                context: testCase.context
            )
            switch testCase.expectation {
            case .useful:
                XCTAssertEqual(actual, testCase.expectedContinuation, testCase.id)
            case .restatementOrGeneric, .unsafe:
                XCTAssertNil(actual, testCase.id)
            }
        }

        XCTAssertNil(FlowProseCompletionSanitizer.sanitize(
            "visit example.com tomorrow",
            context: "For more details"
        ))
    }

    func testQASampleIsFrozenAndArtifactMatchesCorpus() throws {
        let sampleIDs = FlowWritingCorpus.qaSampleIDs
        XCTAssertEqual(sampleIDs, [
            "repair-exact-001",
            "repair-exact-002",
            "repair-exact-003",
            "repair-exact-004",
            "repair-exact-005",
            "repair-exact-013",
            "repair-exact-014",
            "repair-exact-015",
            "repair-exact-016",
            "repair-exact-017",
            "repair-exact-021",
            "repair-exact-022",
            "repair-exact-023",
            "repair-exact-024",
            "repair-ai-001",
            "repair-protected-001",
            "repair-protected-002",
            "repair-protected-003",
            "repair-protected-004",
            "repair-protected-005",
        ])
        XCTAssertEqual(sampleIDs.count, 20)
        XCTAssertEqual(Set(sampleIDs).count, 20)
        let casesByID = Dictionary(
            uniqueKeysWithValues: FlowWritingCorpus.repairCases.map { ($0.id, $0) }
        )
        let sample = try sampleIDs.map { id in
            try XCTUnwrap(casesByID[id], "Missing frozen QA case \(id)")
        }

        XCTAssertTrue(sample[0..<5].allSatisfy {
            $0.expectation == .exactDeterministic
                && !$0.isMultiError
                && !$0.isLongOrHardWrapped
        })
        XCTAssertTrue(sample[5..<10].allSatisfy(\.isMultiError))
        XCTAssertTrue(sample[10..<15].allSatisfy(\.isLongOrHardWrapped))
        XCTAssertTrue(sample[15..<20].allSatisfy {
            $0.expectation == .protectedUnsafe
        })

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FlowWritingCorpusQA.md")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertEqual(fixture, FlowWritingCorpus.qaMarkdown)
        for id in sampleIDs {
            XCTAssertEqual(
                fixture.components(separatedBy: "`\(id)`").count - 1,
                1,
                "QA artifact must number \(id) exactly once"
            )
        }
    }

    private func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
