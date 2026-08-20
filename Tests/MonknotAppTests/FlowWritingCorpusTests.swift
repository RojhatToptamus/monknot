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
                XCTAssertNil(testCase.aiClassification, testCase.id)
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertTrue(testCase.protectedFragments.isEmpty, testCase.id)
            case .aiInvariant:
                XCTAssertNotEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(
                    testCase.expectedFinalText,
                    testCase.conservativeCandidateFixture ?? testCase.referenceText,
                    testCase.id
                )
                XCTAssertNotNil(testCase.aiClassification, testCase.id)
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertTrue(testCase.protectedFragments.isEmpty, testCase.id)
            case .protectedUnsafe:
                XCTAssertNotEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(testCase.expectedFinalText, testCase.input, testCase.id)
                XCTAssertNil(testCase.aiClassification, testCase.id)
                XCTAssertFalse(testCase.mutationManifest.isEmpty, testCase.id)
                XCTAssertFalse(testCase.mutations.isEmpty, testCase.id)
                XCTAssertFalse(testCase.protectedFragments.isEmpty, testCase.id)
                for fragment in testCase.protectedFragments {
                    XCTAssertTrue(testCase.input.contains(fragment), testCase.id)
                }
            case .clean:
                XCTAssertEqual(testCase.input, testCase.referenceText, testCase.id)
                XCTAssertEqual(testCase.expectedFinalText, testCase.input, testCase.id)
                XCTAssertNil(testCase.aiClassification, testCase.id)
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

        let directAI = FlowWritingCorpus.repairCases.filter {
            $0.aiClassification == .direct
        }
        let reviewOnlyAI = FlowWritingCorpus.repairCases.filter {
            $0.aiClassification == .reviewOnly
        }
        XCTAssertEqual(directAI.count, 4)
        XCTAssertEqual(reviewOnlyAI.count, 16)
        let directMutationKinds: Set<FlowWritingMutationKind> = [
            .spelling,
            .adjacentTransposition,
            .missingShortWord,
            .subjectVerbAgreement,
            .wrongArticle,
            .wrongPreposition,
            .missingComma,
            .incorrectPunctuation,
            .capitalization,
        ]
        for testCase in directAI {
            XCTAssertTrue(
                testCase.mutations.allSatisfy(directMutationKinds.contains),
                "Direct AI fixture contains a structural mutation: \(testCase.id)"
            )
        }
        XCTAssertTrue(reviewOnlyAI.contains { $0.mutations.contains(.duplicatedWord) })
        XCTAssertTrue(reviewOnlyAI.contains { $0.mutations.contains(.localReorder) })
        XCTAssertTrue(reviewOnlyAI.contains { $0.mutations.contains(.runOnClause) })

        let reported = FlowWritingCorpus.repairCases.first { $0.id == "repair-ai-001" }
        XCTAssertEqual(
            reported?.input,
            "I am nt be able to come today because yesterday I got sick so badly and now cannot get out of the bed wirhgth now."
        )
        XCTAssertEqual(reported?.aiClassification, .reviewOnly)
        XCTAssertEqual(
            reported?.conservativeCandidateFixture,
            "I am not able to come today because yesterday I got sick so badly, and now I cannot get out of the bed right now."
        )
    }

    func testAutocompleteCorpusHasEightCasesPerClassAndRequiredRegressions() {
        let cases = FlowWritingCorpus.autocompleteCases
        XCTAssertEqual(Set(cases.map(\.id)).count, 24)
        for expectation in FlowWritingAutocompleteExpectation.allCases {
            XCTAssertEqual(
                cases.filter { $0.expectation == expectation }.count,
                8,
                expectation.rawValue
            )
        }

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

        let reported = cases.first { $0.id == "autocomplete-restatement-001" }
        XCTAssertEqual(reported?.context, "Hello im wiritng this to exprs that")
        XCTAssertEqual(
            reported?.modelOutput,
            "Hello, I’m writing this to express that I’m…"
        )
        XCTAssertTrue(cases.contains {
            $0.context == "We typed teh" && $0.modelOutput == "the next step"
        })
        XCTAssertTrue(cases.contains {
            $0.context == "We agreed adn" && $0.modelOutput == "and continue"
        })
        XCTAssertTrue(cases.contains {
            $0.expectation == .restatementOrGeneric
                && $0.context.localizedCaseInsensitiveContains("education")
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

    func testCompletedSignedAppQARunContainsEveryFrozenCaseWithoutPlaceholders() throws {
        let runURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FlowWritingCorpusQARun-2026-08-16.md")
        let run = try String(contentsOf: runURL, encoding: .utf8)

        XCTAssertFalse(run.contains("___"))
        XCTAssertEqual(
            run.components(separatedBy: "### Case ").count - 1,
            FlowWritingCorpus.qaSampleIDs.count
        )
        for id in FlowWritingCorpus.qaSampleIDs {
            XCTAssertEqual(
                run.components(separatedBy: "`\(id)`").count - 1,
                1,
                "Completed QA run must contain \(id) exactly once"
            )
        }
    }

    func testFinalSignedAppQAFollowUpRecordMatchesRecordedScope() throws {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let record = try String(
            contentsOf: fixturesURL.appendingPathComponent(
                "FlowWritingCorpusQAFollowUp-2026-08-16-final03.md"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(record.contains("___"))
        XCTAssertEqual(record.components(separatedBy: "## Observation ").count - 1, 4)
        let rerunSections = record.components(separatedBy: "## Full fixed-sample rerun")
        XCTAssertEqual(rerunSections.count, 2)
        let rerunTail = try XCTUnwrap(rerunSections.last)
        let rerun = try XCTUnwrap(
            rerunTail.components(
                separatedBy: "\n## Post-audit build boundary"
            ).first
        )
        XCTAssertTrue(rerun.contains("exactly 10 were typed and 10 used real Command-V paste"))
        for id in FlowWritingCorpus.qaSampleIDs {
            XCTAssertEqual(
                rerun.components(separatedBy: "`\(id)`").count - 1,
                1,
                "Final03 rerun must contain \(id) exactly once"
            )
        }
        XCTAssertEqual(
            record.components(
                separatedBy: "## Async spelling-candidate build boundary — 2026-08-17"
            ).count - 1,
            1
        )
        XCTAssertTrue(record.contains("Deep and strict code-signature verification passed."))
        XCTAssertTrue(record.contains("automated hosted-editor evidence, not a signed-app observation"))
        XCTAssertTrue(record.contains("This targeted check is not a full fixed-sample rerun"))
        XCTAssertTrue(record.contains("No current04 UI behavior is claimed."))
        XCTAssertTrue(record.contains("that build offered `very` for `repair-exact-023`"))
        XCTAssertTrue(record.contains("No latest-clone UI behavior is claimed"))
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
