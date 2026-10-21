import AppKit
import MonknotCore
import XCTest
@testable import MonknotApp

/// The decisions writing assistance makes the same way in Source and in Preview
/// (`EditorFlowRepairPolicy`), on their own: where a check goes, which fixes wait for review, what
/// the on-device model's answers lead to, the cooldowns after it fails, what a fix the user turned
/// down or took keeps from coming back, and how protected Markdown is kept out of every edit.
final class EditorFlowRepairPolicyTests: XCTestCase {
    private static let appleOnly = EditorTextCheckingOptions(
        checksSpelling: true,
        checksGrammar: true,
        inlinePredictions: true,
        onDeviceProseCompletions: false
    )
    private static let onDevice = EditorTextCheckingOptions(
        checksSpelling: true,
        checksGrammar: true,
        inlinePredictions: true,
        onDeviceProseCompletions: true
    )
    private static let english = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en"]])

    // MARK: - Where a check goes

    func testACleanSentenceIsClearOrGoesToTheModelWhenOnDeviceAssistanceIsOn() {
        let sentence = "We read the plan."
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(afterChecking: [], snapshot: snapshot(sentence), protectedRanges: []),
            .end(.clear(.clean))
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: [],
                snapshot: snapshot(sentence, options: Self.onDevice),
                protectedRanges: []
            ),
            .modelRepair
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: [],
                snapshot: snapshot(sentence, options: Self.onDevice, offersBatch: false),
                protectedRanges: []
            ),
            .end(.clear(.clean)),
            "The model repairs only a sentence offered as one batch"
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: [],
                snapshot: snapshot(sentence, options: Self.onDevice, coversWholeSentence: false),
                protectedRanges: []
            ),
            .end(.blocked),
            "Part of a sentence that checks clean waits for the rest"
        )
    }

    func testIssuesResolveOnlyInAWholeSentenceOfferedAsOneBatch() {
        let sentence = "We read teh plan."
        let results = [spelling("teh", in: sentence, "the")]
        let issue = EditorFlowDetectedIssue(range: NSRange(location: 8, length: 3), kind: .spelling, hasPreciseRange: true)
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(afterChecking: results, snapshot: snapshot(sentence), protectedRanges: []),
            .resolve([issue])
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: results,
                snapshot: snapshot(sentence, offersBatch: false),
                protectedRanges: []
            ),
            .end(.unresolved(.unresolvedAppleResult)),
            "Without a batch Apple's marks stay and nothing is fixed"
        )
    }

    /// Protected ranges are document offsets; the issues Apple reports are offsets in the checked
    /// sentence, which here starts at 20.
    func testAnIssueInProtectedMarkdownWhollyOrInPartIsLeftToTheSystem() {
        let sentence = "Use `teh` here now."
        let start = 20
        let results = [spelling("teh", in: sentence, "the")]
        let code = NSRange(location: start + 4, length: 5)
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: results,
                snapshot: snapshot(sentence, at: start),
                protectedRanges: [code]
            ),
            .end(.unresolved(.protected)),
            "An issue inside a code span is never repaired"
        )
        let partly = NSRange(location: start + 4, length: 3)
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: results,
                snapshot: snapshot(sentence, at: start),
                protectedRanges: [partly]
            ),
            .end(.unresolved(.protected)),
            "Nor is one that overlaps protected source only in part"
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.step(
                afterChecking: results,
                snapshot: snapshot(sentence, at: start),
                protectedRanges: [NSRange(location: 4, length: 5)]
            ),
            .resolve([EditorFlowDetectedIssue(range: NSRange(location: 5, length: 3), kind: .spelling, hasPreciseRange: true)]),
            "A protected range elsewhere in the document does not cover the issue"
        )
    }

    func testAppleCandidatesFollowTheChecksThatAreOnAndGiveUpOnTooManyLookups() {
        let sentence = "They is teh one."
        let results = [
            spelling("teh", in: sentence, "the"),
            grammar("is", in: sentence, ["are"]),
        ]
        let all = EditorFlowRepairPolicy.appleCandidates(in: results, snapshot: snapshot(sentence))
        XCTAssertEqual(all.concrete.map(\.replacementText), ["are", "the"])
        XCTAssertEqual(all.spellingLookups, [], "A misspelling with one certain fix needs no lookup")

        let grammarOnly = EditorFlowRepairPolicy.appleCandidates(
            in: results,
            snapshot: snapshot(sentence, options: EditorTextCheckingOptions(checksSpelling: false, checksGrammar: true))
        )
        XCTAssertEqual(grammarOnly.concrete.map(\.kind), [.grammar], "Spelling off drops spelling fixes")

        let words = (0..<9).map { "wrd\($0)" }.joined(separator: " ") + "."
        let unknown = (0..<9).map {
            NSTextCheckingResult.spellCheckingResult(range: (words as NSString).range(of: "wrd\($0)"))
        }
        XCTAssertEqual(
            EditorFlowRepairPolicy.appleCandidates(in: unknown, snapshot: snapshot(words)),
            EditorFlowAppleCandidates(concrete: [], alternatives: [], spellingLookups: []),
            "More misspellings than can be looked up resolve into nothing"
        )
    }

    func testASpellingLookupBecomesAnAlternativeOnlyWithAGuessBeyondTheAutomaticFix() {
        let sentence = "We read teh plan."
        let range = NSRange(location: 8, length: 3)
        let guess = { (word: String) in NSTextCheckingResult.correctionCheckingResult(range: range, replacementString: word) }
        let certain = EditorFlowSpellingCandidateLookup(range: range, primaryReplacement: "the")
        XCTAssertNil(EditorFlowRepairPolicy.spellingAlternative(for: certain, candidateResults: [guess("the")], in: sentence))
        XCTAssertEqual(
            EditorFlowRepairPolicy.spellingAlternative(for: certain, candidateResults: [guess("tea")], in: sentence),
            EditorFlowAlternativeCandidate(range: range, replacementTexts: ["the", "tea"], kind: .spelling)
        )
        let unsure = EditorFlowSpellingCandidateLookup(range: range, primaryReplacement: nil)
        XCTAssertEqual(
            EditorFlowRepairPolicy.spellingAlternative(for: unsure, candidateResults: [guess("the")], in: sentence),
            EditorFlowAlternativeCandidate(range: range, replacementTexts: ["the"], kind: .spelling)
        )
        XCTAssertNil(EditorFlowRepairPolicy.spellingAlternative(for: unsure, candidateResults: [], in: sentence))
    }

    func testExactlyOneIssueWithAlternativesIsValidatedAndASpellingOneForcesReview() {
        let sentence = "They is teh one."
        let isRange = NSRange(location: 5, length: 2)
        let tehRange = NSRange(location: 8, length: 3)
        let issues = [
            EditorFlowDetectedIssue(range: isRange, kind: .grammar, hasPreciseRange: true),
            EditorFlowDetectedIssue(range: tehRange, kind: .spelling, hasPreciseRange: true),
        ]
        let concrete = [
            EditorFlowCorrectionCandidate(range: isRange, replacementText: "are", kind: .grammar),
            EditorFlowCorrectionCandidate(range: tehRange, replacementText: "the", kind: .spelling),
        ]
        let grammarChoice = EditorFlowAlternativeCandidate(range: isRange, replacementTexts: ["are", "were"], kind: .grammar)
        let spellingChoice = EditorFlowAlternativeCandidate(range: tehRange, replacementTexts: ["the", "tea"], kind: .spelling)
        func step(_ alternatives: [EditorFlowAlternativeCandidate], protectedRanges: [NSRange] = []) -> EditorFlowCandidateStep {
            EditorFlowRepairPolicy.step(
                concreteCandidates: concrete,
                alternatives: alternatives,
                detectedIssues: issues,
                snapshot: snapshot(sentence),
                protectedRanges: protectedRanges,
                sourceUTF16Length: (sentence as NSString).length
            )
        }
        XCTAssertEqual(step([]), .present(concrete))
        XCTAssertEqual(
            step([grammarChoice]),
            .validate(grammarChoice, concreteCandidates: [concrete[1]], forcesReview: false),
            "The issue's own fix gives way to its alternatives"
        )
        XCTAssertEqual(step([spellingChoice]), .validate(spellingChoice, concreteCandidates: [concrete[0]], forcesReview: true))
        XCTAssertEqual(step([grammarChoice, spellingChoice]), .present([]), "Two issues with alternatives resolve into nothing")
        XCTAssertEqual(step([grammarChoice], protectedRanges: [isRange]), .present([]), "Alternatives in protected Markdown are not offered")
    }

    // MARK: - Which fixes wait for review

    func testFixesThatDeleteLettersOrChangeWordsInGrammarWaitForReview() throws {
        func acceptance(
            _ sentence: String,
            _ target: String,
            _ replacement: String,
            _ kind: EditorFlowCorrectionKind,
            forcesReview: Bool = false
        ) throws -> EditorFlowSuggestionAcceptance {
            let range = (sentence as NSString).range(of: target)
            let suggestion = try XCTUnwrap(EditorFlowRepairPolicy.deterministicSuggestion(
                candidates: [EditorFlowCorrectionCandidate(range: range, replacementText: replacement, kind: kind)],
                detectedIssues: [EditorFlowDetectedIssue(range: range, kind: kind, hasPreciseRange: true)],
                snapshot: snapshot(sentence),
                protectedRanges: [],
                sourceUTF16Length: (sentence as NSString).length,
                suppression: nil,
                forcesReview: forcesReview
            ))
            return suggestion.acceptance
        }
        XCTAssertEqual(try acceptance("We read teh plan.", "teh", "the", .spelling), .direct)
        XCTAssertEqual(try acceptance("We read thhe plan.", "thhe", "the", .spelling), .reviewOnly, "A fix that deletes a letter")
        XCTAssertEqual(try acceptance("They is ready.", "is", "are", .grammar), .reviewOnly, "A grammar fix that changes words")
        XCTAssertEqual(try acceptance("We left ,then ate.", " ,", ",", .grammar), .direct, "A grammar fix to punctuation only")
        XCTAssertEqual(try acceptance("We read teh plan.", "teh", "the", .spelling, forcesReview: true), .reviewOnly)
    }

    func testAFixIsNotOfferedForAnImpreciseIssueOrInsideProtectedMarkdown() {
        let sentence = "We read teh plan."
        let range = NSRange(location: 8, length: 3)
        let candidate = EditorFlowCorrectionCandidate(range: range, replacementText: "the", kind: .spelling)
        func suggestion(precise: Bool, protectedRanges: [NSRange]) -> EditorFlowSuggestion? {
            EditorFlowRepairPolicy.deterministicSuggestion(
                candidates: [candidate],
                detectedIssues: [EditorFlowDetectedIssue(range: range, kind: .spelling, hasPreciseRange: precise)],
                snapshot: snapshot(sentence),
                protectedRanges: protectedRanges,
                sourceUTF16Length: (sentence as NSString).length,
                suppression: nil
            )
        }
        XCTAssertNotNil(suggestion(precise: true, protectedRanges: []))
        XCTAssertNil(suggestion(precise: false, protectedRanges: []))
        XCTAssertNil(suggestion(precise: true, protectedRanges: [NSRange(location: 9, length: 1)]))
    }

    func testAValidationSentenceCarriesTheOtherFixesAndPointsAtTheAlternative() throws {
        let sentence = "Thhe cat sat on teh mat."
        let earlier = EditorFlowCorrectionCandidate(range: NSRange(location: 0, length: 4), replacementText: "The", kind: .spelling)
        let alternative = EditorFlowAlternativeCandidate(
            range: NSRange(location: 16, length: 3),
            replacementTexts: ["the", "a"],
            kind: .spelling
        )
        let validation = try XCTUnwrap(EditorFlowRepairPolicy.validationSentence(
            sentence,
            alternativeCandidate: alternative,
            alternativeReplacement: "a",
            concreteCandidates: [earlier]
        ))
        XCTAssertEqual(validation.text, "The cat sat on a mat.")
        XCTAssertEqual(validation.replacementRange, NSRange(location: 15, length: 1), "The earlier fix moved the alternative left by one")

        let overlapping = EditorFlowCorrectionCandidate(range: NSRange(location: 15, length: 3), replacementText: "x", kind: .grammar)
        XCTAssertNil(EditorFlowRepairPolicy.validationSentence(
            sentence,
            alternativeCandidate: alternative,
            alternativeReplacement: "a",
            concreteCandidates: [overlapping]
        ))
    }

    func testValidationCountsWhatIsCheckedAndNeedsALanguage() {
        let text = "They are teh ones."
        let misspelling = spelling("teh", in: text, "the")
        let grammarIssue = grammar("are", in: text, ["is"])
        let alternativeRange = NSRange(location: 0, length: 4)
        func clean(_ results: [NSTextCheckingResult], _ options: EditorTextCheckingOptions, orthography: NSOrthography? = Self.english) -> Bool {
            EditorFlowRepairPolicy.checkingValidationIsClean(
                results,
                orthography: orthography,
                options: options,
                requiredSpellingRange: alternativeRange,
                checkedUTF16Length: (text as NSString).length
            )
        }
        XCTAssertTrue(clean([], Self.appleOnly))
        XCTAssertFalse(clean([], Self.appleOnly, orthography: nil), "An answer without a language proves nothing")
        XCTAssertFalse(clean([misspelling], Self.appleOnly))
        XCTAssertTrue(
            clean([misspelling], EditorTextCheckingOptions(checksSpelling: false, checksGrammar: true)),
            "With spelling off, a misspelling outside the alternative does not count"
        )
        XCTAssertFalse(clean([grammarIssue], Self.appleOnly))
        XCTAssertTrue(clean([grammarIssue], EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)))
    }

    // MARK: - Fixes the user turned down or took

    func testAnUnresolvedSentenceGoesToTheModelUnlessTheUserTurnedTheFixDown() {
        let sentence = "They is ready."
        let checked = snapshot(sentence)
        let candidates = [EditorFlowCorrectionCandidate(range: NSRange(location: 5, length: 2), replacementText: "are", kind: .grammar)]
        XCTAssertNil(EditorFlowRepairPolicy.end(afterUnresolvedFixes: candidates, snapshot: checked, suppression: nil))
        let dismissed = EditorFlowSuggestionSuppression(suggestion(for: sentence, "is", "are", .grammar), accepted: false)
        XCTAssertEqual(
            EditorFlowRepairPolicy.end(afterUnresolvedFixes: [], snapshot: checked, suppression: dismissed),
            .unresolved(.suppressedDuplicate),
            "The same sentence is not offered to the model again"
        )
        XCTAssertNil(
            EditorFlowRepairPolicy.end(
                afterUnresolvedFixes: [],
                snapshot: snapshot("They is ready now."),
                suppression: dismissed
            ),
            "Another sentence is"
        )
    }

    func testAnAcceptedFixKeepsItsSentenceAndItsWordsFromBeingFixedAgain() {
        let original = "We read teh plan."
        let accepted = EditorFlowSuggestionSuppression(suggestion(for: original, "teh", "the", .spelling), accepted: true)
        XCTAssertTrue(accepted.targetStillExists(in: "We read the plan."), "The corrected words are there")
        XCTAssertTrue(accepted.targetStillExists(in: original), "Undo brought the original back")
        XCTAssertFalse(accepted.targetStillExists(in: "We read a plan."), "Neither is: the suppression can go")

        let undone = snapshot(original)
        let sameFix = [EditorFlowCorrectionCandidate(range: NSRange(location: 8, length: 3), replacementText: "the", kind: .spelling)]
        XCTAssertTrue(accepted.applies(to: sameFix, snapshot: undone))
        let longer = snapshot("We read teh plan today.")
        XCTAssertTrue(accepted.applies(to: sameFix, snapshot: longer), "The same edit in a longer sentence is the same fix")
        let otherFix = [EditorFlowCorrectionCandidate(range: NSRange(location: 8, length: 3), replacementText: "tea", kind: .spelling)]
        XCTAssertFalse(accepted.applies(to: otherFix, snapshot: longer))
    }

    // MARK: - The on-device model

    func testWhichModelOutcomesCountAsFailures() {
        let checked = snapshot("Their going home.")
        XCTAssertEqual(EditorFlowRepairPolicy.modelRepairAnswer(.unavailable, snapshot: checked), .failure(EditorFlowModelFailure(.modelUnavailable)))
        XCTAssertEqual(
            EditorFlowRepairPolicy.modelRepairAnswer(.failed, snapshot: checked),
            .failure(EditorFlowModelFailure(.modelFailed, startsCooldown: true))
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.modelRepairAnswer(.timedOut, snapshot: checked),
            .failure(EditorFlowModelFailure(.modelTimedOut, startsCooldown: true))
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.modelRepairAnswer(.validationRejected, snapshot: checked),
            .failure(EditorFlowModelFailure(.validationRejected, startsCooldown: true))
        )
        XCTAssertNil(EditorFlowModelFailure(.success("They're going home.")))
        XCTAssertEqual(EditorFlowRepairPolicy.modelRepairAnswer(.success("Their going home."), snapshot: checked), .unchanged)
        guard case let .candidate(sentence, edits) = EditorFlowRepairPolicy.modelRepairAnswer(
            .success("They're going home."),
            snapshot: checked
        ) else {
            return XCTFail("A small repair is a candidate")
        }
        XCTAssertEqual(sentence, "They're going home.")
        XCTAssertFalse(edits.isEmpty)
        XCTAssertEqual(
            EditorFlowRepairPolicy.modelRepairAnswer(.success("Use `the` here."), snapshot: snapshot("Use `teh` here.")),
            .failure(EditorFlowModelFailure(.validationRejected, startsCooldown: true)),
            "A repair that changes protected Markdown is the model failing"
        )
    }

    func testAFailureStartsACooldownOnlyWhenAppleFoundIssues() {
        let failed = EditorFlowModelFailure(.modelFailed, startsCooldown: true)
        XCTAssertTrue(EditorFlowRepairPolicy.end(withoutModelRepair: failed, appleFoundIssues: true) == (.unresolved(.modelFailed), true))
        XCTAssertTrue(
            EditorFlowRepairPolicy.end(withoutModelRepair: failed, appleFoundIssues: false) == (.clear(.modelFailed), false),
            "A sentence Apple passed is never held back"
        )
        let missing = EditorFlowModelFailure(.modelUnavailable)
        XCTAssertTrue(EditorFlowRepairPolicy.end(withoutModelRepair: missing, appleFoundIssues: true) == (.unresolved(.modelUnavailable), false))
        XCTAssertEqual(EditorFlowRepairPolicy.end(forUnchangedSentenceAfterAppleFoundIssues: true), .unresolved(.validationRejected))
        XCTAssertEqual(EditorFlowRepairPolicy.end(forUnchangedSentenceAfterAppleFoundIssues: false), .clear(.clean))
    }

    func testTheModelsRepairIsReviewedOnlyWhenItChecksCleanAndKeepsClearOfProtectedMarkdown() {
        let sentence = "Their going home."
        let start = 10
        let checked = snapshot(sentence, at: start, options: Self.onDevice)
        let edits = [EditorFlowCorrectionEdit(
            range: NSRange(location: 0, length: 5),
            originalText: "Their",
            replacementText: "They're",
            kind: .grammar
        )]
        func suggestion(
            results: [NSTextCheckingResult] = [],
            orthography: NSOrthography? = Self.english,
            appleFoundIssues: Bool = true,
            protectedRanges: [NSRange] = [],
            suppression: EditorFlowSuggestionSuppression? = nil
        ) -> EditorFlowModelSuggestion {
            EditorFlowRepairPolicy.modelSuggestion(
                sentence: "They're going home.",
                edits: edits,
                checkResults: results,
                orthography: orthography,
                appleFoundIssues: appleFoundIssues,
                snapshot: checked,
                protectedRanges: protectedRanges,
                suppression: suppression
            )
        }
        guard case let .review(review) = suggestion() else { return XCTFail("A clean repair is reviewed") }
        XCTAssertEqual(review.source, .ai)
        XCTAssertEqual(review.acceptance, .reviewOnly, "The model's repairs never apply by themselves")
        XCTAssertEqual(review.edits.map(\.range), [NSRange(location: start, length: 5)], "Edits move to document offsets")

        let issue = grammar("going", in: "They're going home.", ["went"])
        XCTAssertEqual(suggestion(results: [issue]), .rejected(.unresolved(.validationRejected), startsCooldown: true))
        XCTAssertEqual(suggestion(results: [issue], appleFoundIssues: false), .rejected(.clear(.validationRejected), startsCooldown: false))
        XCTAssertEqual(suggestion(orthography: nil), .rejected(.unresolved(.validationRejected), startsCooldown: true))
        XCTAssertEqual(
            suggestion(protectedRanges: [NSRange(location: start + 2, length: 1)]),
            .rejected(.unresolved(.validationRejected), startsCooldown: true)
        )
        let dismissed = EditorFlowSuggestionSuppression(review, accepted: false)
        XCTAssertEqual(suggestion(suppression: dismissed), .rejected(.unresolved(.suppressedDuplicate), startsCooldown: false))
    }

    func testCooldownsLastThirtySecondsForOneSentenceOrForEverything() {
        let now = Date()
        var repair = EditorFlowModelCooldown()
        XCTAssertFalse(repair.applies(to: "Their going home.", now: now))
        repair.start(for: " Their going home.\n", now: now)
        XCTAssertTrue(repair.applies(to: "Their going home.", now: now.addingTimeInterval(29)), "Surrounding whitespace does not count")
        XCTAssertFalse(repair.applies(to: "Another sentence.", now: now.addingTimeInterval(1)))
        XCTAssertFalse(repair.applies(to: "Their going home.", now: now.addingTimeInterval(30)))
        XCTAssertFalse(repair.applies(to: "Their going home.", now: now.addingTimeInterval(1)), "A cooldown that ran out is over")

        var completions = EditorFlowModelCooldown()
        completions.start(now: now)
        XCTAssertTrue(completions.applies(now: now.addingTimeInterval(29)))
        completions.end()
        XCTAssertFalse(completions.applies(now: now.addingTimeInterval(1)))
    }

    // MARK: - Protected Markdown

    func testProtectedRangesMovePastAnInsertionAtOrBeforeThem() {
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 5, length: 3), NSRange(location: 10, length: 2)]
        XCTAssertEqual(
            EditorFlowRepairPolicy.rebasedProtectedRanges(ranges, insertingAt: 5, length: 2),
            [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3), NSRange(location: 12, length: 2)],
            "A range that starts exactly at the insertion moves with it"
        )
        XCTAssertEqual(
            EditorFlowRepairPolicy.rebasedProtectedRanges(ranges, insertingAt: 3, length: 1),
            [NSRange(location: 0, length: 3), NSRange(location: 6, length: 3), NSRange(location: 11, length: 2)],
            "A range that ends at the insertion stays"
        )
    }

    func testTheCaretIsOutsideProtectedMarkdownOnlyWhenTheCharacterAfterItIs() {
        let code = [NSRange(location: 4, length: 5)]
        func outside(_ caret: Int, length: Int = 0, text: Int = 20) -> Bool {
            EditorFlowRepairPolicy.caretIsOutsideProtectedRanges(
                code,
                selection: NSRange(location: caret, length: length),
                sourceUTF16Length: text
            )
        }
        XCTAssertTrue(outside(3))
        XCTAssertFalse(outside(4), "Right before a code span")
        XCTAssertFalse(outside(8))
        XCTAssertTrue(outside(9), "Right after it")
        XCTAssertFalse(outside(9, text: 9), "At the end of the text, the last character counts")
        XCTAssertFalse(outside(2, length: 1), "A selection is not a caret")
        XCTAssertTrue(outside(0, text: 0), "Nothing is protected in an empty text")
    }

    // MARK: - Helpers

    private func snapshot(
        _ sentence: String,
        at location: Int = 0,
        options: EditorTextCheckingOptions = appleOnly,
        coversWholeSentence: Bool = true,
        offersBatch: Bool = true
    ) -> EditorFlowCheckSnapshot {
        let range = NSRange(location: location, length: (sentence as NSString).length)
        return EditorFlowCheckSnapshot(
            documentID: "Note.md",
            revision: 3,
            checkedText: sentence,
            checkedRange: range,
            selectedRange: NSRange(location: NSMaxRange(range), length: 0),
            caretUTF16Offset: NSMaxRange(range),
            options: options,
            sourceMode: .markdown,
            coversWholeCurrentSentence: coversWholeSentence,
            offersSentenceBatch: offersBatch,
            checksCompletedStructuralSentence: false,
            requestsAutocompleteAfterClear: false
        )
    }

    private func suggestion(
        for sentence: String,
        _ target: String,
        _ replacement: String,
        _ kind: EditorFlowCorrectionKind
    ) -> EditorFlowSuggestion {
        let range = (sentence as NSString).range(of: target)
        return EditorFlowSuggestion(
            documentID: "Note.md",
            revision: 3,
            selectedRange: NSRange(location: (sentence as NSString).length, length: 0),
            caretUTF16Offset: (sentence as NSString).length,
            sentenceRange: NSRange(location: 0, length: (sentence as NSString).length),
            originalSentence: sentence,
            correctedSentence: (sentence as NSString).replacingCharacters(in: range, with: replacement),
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(range: range, originalText: target, replacementText: replacement, kind: kind)]
        )
    }

    private func spelling(_ word: String, in text: String, _ replacement: String) -> NSTextCheckingResult {
        NSTextCheckingResult.correctionCheckingResult(range: (text as NSString).range(of: word), replacementString: replacement)
    }

    private func grammar(_ target: String, in text: String, _ corrections: [String]) -> NSTextCheckingResult {
        let source = text as NSString
        return NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: source.length),
            details: [[NSGrammarRange: NSValue(range: source.range(of: target)), NSGrammarCorrections: corrections]]
        )
    }
}
