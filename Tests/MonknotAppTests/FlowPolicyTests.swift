import AppKit
import Foundation
import XCTest
@testable import MonknotApp

final class FlowPolicyTests: XCTestCase {
    func testFlowCheckerTypesFollowSpellingAndGrammarPreferences() {
        let spelling = EditorFlowCheckingTypes.value(for: EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false
        ))
        XCTAssertNotEqual(spelling & NSTextCheckingResult.CheckingType.orthography.rawValue, 0)
        XCTAssertNotEqual(spelling & NSTextCheckingResult.CheckingType.spelling.rawValue, 0)
        XCTAssertNotEqual(spelling & NSTextCheckingResult.CheckingType.correction.rawValue, 0)
        XCTAssertEqual(spelling & NSTextCheckingResult.CheckingType.grammar.rawValue, 0)

        let grammar = EditorFlowCheckingTypes.value(for: EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true
        ))
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.orthography.rawValue, 0)
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.spelling.rawValue, 0)
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.correction.rawValue, 0)
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.grammar.rawValue, 0)
    }

    func testSentenceBoundaryPlannerRecognizesClosingQuotesAndBracketsAfterPunctuation() throws {
        for source in ["teh.”", "teh.”)", "teh.]", "teh.}"] {
            let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
                in: source,
                selectedRange: NSRange(location: (source as NSString).length, length: 0)
            ))
            XCTAssertTrue(plan.offersSentenceBatch, "Expected a completed sentence for \(source)")
            XCTAssertEqual((source as NSString).substring(with: plan.range), source)
        }
    }

    func testSentencePlannerDoesNotInventBoundariesAfterCommonAbbreviations() throws {
        for source in [
            "Jan. tenth is teh.",
            "Corp. headquarters has teh issue.",
        ] {
            let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
                in: source,
                selectedRange: NSRange(location: (source as NSString).length, length: 0)
            ))
            XCTAssertEqual(
                plan.range,
                NSRange(location: 0, length: (source as NSString).length),
                "A manual lowercase split must not override Foundation's abbreviation range"
            )
            XCTAssertFalse(plan.isBatchSafe)
            XCTAssertFalse(plan.offersSentenceBatch)
        }
    }

    func testConcreteCorrectionResolverReturnsSpellingAndExactGrammarRanges() {
        let source = "teh sentence are here"
        let spellingRange = (source as NSString).range(of: "teh")
        let sentenceRange = (source as NSString).range(of: "sentence are")
        let grammarRange = (source as NSString).range(of: "are")
        let relativeGrammarRange = NSRange(
            location: grammarRange.location - sentenceRange.location,
            length: grammarRange.length
        )
        let spelling = NSTextCheckingResult.correctionCheckingResult(
            range: spellingRange,
            replacementString: "the"
        )
        let grammar = NSTextCheckingResult.grammarCheckingResult(
            range: sentenceRange,
            details: [[
                NSGrammarRange: NSValue(range: relativeGrammarRange),
                NSGrammarCorrections: ["is"],
            ]]
        )

        let corrections = EditorFlowCorrectionResolver.concreteCorrections(
            in: source,
            caretUTF16Offset: (source as NSString).length,
            results: [spelling, grammar]
        )

        XCTAssertEqual(corrections, [
            EditorFlowCorrectionCandidate(
                range: spellingRange,
                replacementText: "the",
                kind: .spelling
            ),
            EditorFlowCorrectionCandidate(
                range: grammarRange,
                replacementText: "is",
                kind: .grammar
            ),
        ])
    }

    func testCorrectionResolverPreservesPrimaryAndBoundsDeduplicatedReviewCandidates() throws {
        let source = "Please verfy and notifiy owners."
        let sourceValue = source as NSString
        let verfyRange = sourceValue.range(of: "verfy")
        let notifiyRange = sourceValue.range(of: "notifiy")
        let results = [
            NSTextCheckingResult.correctionCheckingResult(
                range: verfyRange,
                replacementString: "very"
            ),
            NSTextCheckingResult.spellCheckingResult(range: verfyRange),
            NSTextCheckingResult.correctionCheckingResult(
                range: notifiyRange,
                replacementString: "notify"
            ),
            NSTextCheckingResult.spellCheckingResult(range: notifiyRange),
        ]
        let lookups = try XCTUnwrap(EditorFlowCorrectionResolver.spellingCandidateLookups(
            in: source,
            caretUTF16Offset: sourceValue.length,
            results: results
        ))
        XCTAssertEqual(lookups, [
            EditorFlowSpellingCandidateLookup(
                range: verfyRange,
                primaryReplacement: "very"
            ),
            EditorFlowSpellingCandidateLookup(
                range: notifiyRange,
                primaryReplacement: "notify"
            ),
        ])
        XCTAssertEqual(
            EditorFlowCorrectionResolver.spellingReviewReplacements(
                in: source,
                lookup: lookups[0],
                candidateResults: [
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "verfy "
                    ),
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "verify "
                    ),
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "very "
                    ),
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "Verny "
                    ),
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "verify"
                    ),
                ]
            ),
            ["very", "verify", "Verny"]
        )
        XCTAssertEqual(
            EditorFlowCorrectionResolver.spellingReviewReplacements(
                in: source,
                lookup: lookups[1],
                candidateResults: [
                    NSTextCheckingResult.replacementCheckingResult(
                        range: notifiyRange,
                        replacementString: "notifiy "
                    ),
                    NSTextCheckingResult.replacementCheckingResult(
                        range: notifiyRange,
                        replacementString: "notify "
                    ),
                ]
            ),
            ["notify"]
        )
        let echoedResults = (0..<EditorFlowCorrectionResolver.maximumRawSpellingCandidateResultCount)
            .map { _ in
                NSTextCheckingResult.replacementCheckingResult(
                    range: verfyRange,
                    replacementString: "verfy "
                )
            }
        XCTAssertEqual(
            EditorFlowCorrectionResolver.spellingReviewReplacements(
                in: source,
                lookup: lookups[0],
                candidateResults: echoedResults + [
                    NSTextCheckingResult.replacementCheckingResult(
                        range: verfyRange,
                        replacementString: "verify "
                    ),
                ]
            ),
            ["very"]
        )
    }

    func testCorrectionResolverBoundsAsyncSpellingLookupRangesAtEight() throws {
        let words = ["aaa", "bbb", "ccc", "ddd", "eee", "fff", "ggg", "hhh", "iii"]
        let source = words.joined(separator: " ")
        let sourceValue = source as NSString
        let spellingResults = words.map {
            NSTextCheckingResult.spellCheckingResult(range: sourceValue.range(of: $0))
        }
        let bounded = try XCTUnwrap(EditorFlowCorrectionResolver.spellingCandidateLookups(
            in: source,
            caretUTF16Offset: sourceValue.length,
            results: Array(spellingResults.prefix(8))
        ))
        XCTAssertEqual(bounded.count, 8)
        XCTAssertNil(EditorFlowCorrectionResolver.spellingCandidateLookups(
            in: source,
            caretUTF16Offset: sourceValue.length,
            results: spellingResults
        ))
        XCTAssertEqual(
            EditorFlowCorrectionResolver.spellingCandidateLookups(
                in: source,
                caretUTF16Offset: sourceValue.length,
                results: [spellingResults[0], spellingResults[0]]
            )?.count,
            1
        )
    }

    func testCorrectionResolverRejectsAmbiguousGrammarChoices() {
        let source = "They is ready"
        let range = (source as NSString).range(of: "is")
        let result = NSTextCheckingResult.grammarCheckingResult(
            range: range,
            details: [[NSGrammarCorrections: ["are", "were"]]]
        )

        XCTAssertTrue(EditorFlowCorrectionResolver.concreteCorrections(
            in: source,
            caretUTF16Offset: NSMaxRange(range),
            results: [result]
        ).isEmpty)
    }

    func testAIRepairValidatorBuildsWordIndependentReviewEdits() throws {
        let cases = [
            ("Could u snd the route?", "Could you send the route?"),
            (
                "hey did the parcel arive yesturday was the box damagd can we call the shop tomorow qzpt",
                "Hey, did the parcel arrive yesterday? Was the box damaged? Can we call the shop tomorrow?"
            ),
            ("yarin gelecem.", "Yarın geleceğim."),
        ]

        for (original, candidate) in cases {
            let edits = try XCTUnwrap(EditorFlowAIRepairValidator.edits(
                originalSentence: original,
                candidateSentence: candidate
            ), "Rejected word-independent repair: \(original)")
            let rebuilt = NSMutableString(string: original)
            for edit in edits.reversed() {
                rebuilt.replaceCharacters(in: edit.range, with: edit.replacementText)
            }
            XCTAssertEqual(rebuilt as String, candidate)
        }
    }

    func testAIRepairValidatorAllowsVisibleDeletionAndPunctuationChanges() throws {
        for (original, candidate) in [
            ("A courier courier arrived before noon.", "A courier arrived before noon."),
            ("After review we can send it.", "After review, we can send it."),
        ] {
            XCTAssertNotNil(EditorFlowAIRepairValidator.edits(
                originalSentence: original,
                candidateSentence: candidate
            ))
        }
    }

    func testAIRepairValidatorRejectsLargeUnrelatedResponse() {
        XCTAssertNil(EditorFlowAIRepairValidator.edits(
            originalSentence: "Ship the report.",
            candidateSentence: "I cannot help with that request."
        ))
    }

    func testAIRepairValidatorPreservesStructuralAuthoredContent() {
        for (original, candidate) in [
            ("Run build_target now.", "Run build_targets now."),
            ("Keep MK-204 with 17 fixes.", "Keep MK-205 with 18 fixes."),
            ("Keep **Launch Ready** exact.", "Keep *Launch Ready* exact."),
            ("Maya said, “Ship today.”", "Maya said, Ship today."),
            ("The total is €17.", "The total is $17."),
        ] {
            XCTAssertNil(
                EditorFlowAIRepairValidator.edits(
                    originalSentence: original,
                    candidateSentence: candidate
                ),
                "Structural content changed: \(original) -> \(candidate)"
            )
        }
    }

    func testAIRepairValidatorRejectsEqualAndExcessiveOutput() {
        XCTAssertNil(EditorFlowAIRepairValidator.edits(
            originalSentence: "The report is ready.",
            candidateSentence: "The report is ready."
        ))
        XCTAssertNil(EditorFlowAIRepairValidator.edits(
            originalSentence: "The report is ready.",
            candidateSentence: String(repeating: "A", count: 901)
        ))
    }

    func testSentencePlannerKeepsHardWrapsAndStopsAtLogicalMarkdownBlocks() throws {
        for id in ["repair-exact-021", "repair-exact-022", "repair-exact-023"] {
            let testCase = try XCTUnwrap(FlowWritingCorpus.repairCases.first { $0.id == id })
            let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
                in: testCase.input,
                selectedRange: NSRange(
                    location: (testCase.input as NSString).length,
                    length: 0
                )
            ))
            XCTAssertEqual(
                plan.range,
                NSRange(location: 0, length: (testCase.input as NSString).length),
                "Hard-wrapped logical sentence was truncated: \(id)"
            )
            XCTAssertEqual((testCase.input as NSString).substring(with: plan.range), testCase.input)
        }

        let boundaryCases: [(String, String)] = [
            ("Earlier typo.\n\nCurrent teh.", "Current teh."),
            ("Earlier typo. Current teh.", "Current teh."),
            ("- Earlier list typo.\nCurrent teh.", "Current teh."),
            ("```swift\nlet value = 1\n```\nCurrent teh.", "Current teh."),
            ("> Earlier quoted typo.\nCurrent teh.", "Current teh."),
            ("# Earlier heading\nCurrent teh.", "Current teh."),
        ]
        for (source, expected) in boundaryCases {
            let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
                in: source,
                selectedRange: NSRange(location: (source as NSString).length, length: 0)
            ))
            XCTAssertEqual((source as NSString).substring(with: plan.range), expected, source)
            XCTAssertFalse(
                (source as NSString).substring(with: plan.range).contains("Earlier"),
                source
            )
        }
    }

    func testFlowPresentationPolicyIsIndependentOfViewportGeometryAndPreservesProvenance() {
        let original = "The lanterns is ready."
        let corrected = "The lanterns are ready."
        let range = NSRange(location: 0, length: (original as NSString).length)
        func suggestion(source: EditorFlowSuggestionSource) -> EditorFlowSuggestion {
            EditorFlowSuggestion(
                documentID: "note.md",
                revision: 1,
                selectedRange: NSRange(location: range.length, length: 0),
                caretUTF16Offset: range.length,
                sentenceRange: range,
                originalSentence: original,
                correctedSentence: corrected,
                source: source,
                acceptance: .reviewOnly,
                edits: [EditorFlowCorrectionEdit(
                    range: (original as NSString).range(of: "is"),
                    originalText: "is",
                    replacementText: "are",
                    kind: .grammar
                )]
            )
        }

        XCTAssertEqual(suggestion(source: .deterministic).acceptance, .reviewOnly)
        XCTAssertEqual(
            suggestion(source: .deterministic).sourceAccessibilityText,
            "Apple spelling and grammar"
        )
        XCTAssertEqual(
            suggestion(source: .ai).sourceAccessibilityText,
            "On-device writing assistance"
        )
    }
}
