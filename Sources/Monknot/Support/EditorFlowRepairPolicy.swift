import AppKit
import MonknotCore

/// The pauses and limits writing assistance keeps the same in Source and in Preview.
enum EditorFlowTiming {
    /// The pause after typing before Apple's on-device model is asked for a completion.
    static let proseCompletionDelayNanoseconds: UInt64 = 360_000_000
    /// A completion never shows sooner than this after it was asked for.
    static let proseOfferDelayNanoseconds: UInt64 = 420_000_000
    /// How long Apple's checker may take before the sentence is left to the system.
    static let checkingTimeoutNanoseconds: UInt64 = 2_000_000_000
    /// The pause after an edit before the protected Markdown is scanned again.
    static let protectedRangesDelayNanoseconds: UInt64 = 140_000_000
    /// How long a completion waits for that scan before it is dropped.
    static let protectedRangesRetryNanoseconds: UInt64 = 1_000_000_000
    /// How long a model that failed is left alone (`EditorFlowModelCooldown`).
    static let modelFailureCooldown: TimeInterval = 30
}

/// The pause after one of Apple's on-device models failed: no completion is asked for at all, and
/// no repair of the same sentence (compared without its surrounding whitespace).
struct EditorFlowModelCooldown {
    private var until: Date?
    private var sentence: String?

    mutating func start(for sentence: String? = nil, now: Date = Date()) {
        until = now.addingTimeInterval(EditorFlowTiming.modelFailureCooldown)
        self.sentence = sentence.map(Self.key)
    }

    mutating func end() {
        until = nil
        sentence = nil
    }

    /// Whether the pause covers `sentence` (or, started for no sentence, everything) now. A pause
    /// that has run out ends.
    mutating func applies(to sentence: String? = nil, now: Date = Date()) -> Bool {
        guard let until else { return false }
        guard until > now else {
            end()
            return false
        }
        return self.sentence == sentence.map(Self.key)
    }

    private static func key(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How a sentence check ends when Flow shows nothing for it. Source records the reason in its
/// diagnostics; Preview has none.
enum EditorFlowRepairEnd: Equatable {
    /// Nothing for Flow to fix, so a completion may follow.
    case clear(EditorFlowTerminalReason)
    /// Apple found something Flow does not fix: the system's own marks stay, and nothing is
    /// completed until the sentence changes.
    case unresolved(EditorFlowTerminalReason)
    /// Apple found nothing in a check that did not cover the whole sentence: wait for the rest.
    case blocked
}

/// What Apple's answer for a checked sentence leads to.
enum EditorFlowCheckStep: Equatable {
    case end(EditorFlowRepairEnd)
    /// Apple found nothing; Apple's on-device model may still repair the sentence.
    case modelRepair
    /// Apple's issues, all outside protected Markdown, to resolve into fixes.
    case resolve([EditorFlowDetectedIssue])
}

/// Apple's answers for a sentence with issues: the exact fixes for the kinds of check that are on,
/// the grammar issues that come with alternatives, and the misspelled words whose guesses are still
/// to be asked for.
struct EditorFlowAppleCandidates: Equatable {
    let concrete: [EditorFlowCorrectionCandidate]
    let alternatives: [EditorFlowAlternativeCandidate]
    let spellingLookups: [EditorFlowSpellingCandidateLookup]
}

/// What Apple's fixes and alternatives for a sentence lead to.
enum EditorFlowCandidateStep: Equatable {
    /// Check each of one issue's alternatives in the corrected sentence before any is offered.
    case validate(
        EditorFlowAlternativeCandidate,
        concreteCandidates: [EditorFlowCorrectionCandidate],
        forcesReview: Bool
    )
    /// Present these fixes, if they resolve into a suggestion.
    case present([EditorFlowCorrectionCandidate])
}

/// Why there is no model answer to show (the model was not asked, is not there, or failed), and
/// whether that counts as the model failing, which keeps Flow from asking it again for a while
/// (`EditorFlowModelCooldown`).
struct EditorFlowModelFailure: Equatable {
    let reason: EditorFlowTerminalReason
    let startsCooldown: Bool

    init(_ reason: EditorFlowTerminalReason, startsCooldown: Bool = false) {
        self.reason = reason
        self.startsCooldown = startsCooldown
    }

    /// The failure in a model's outcome; nil for an answer. A model that is not there has not
    /// failed; one that errs, runs out of time or answers something unusable has.
    init?(_ outcome: FlowModelOutcome) {
        switch outcome {
        case .success:
            return nil
        case .unavailable:
            self.init(.modelUnavailable)
        case .failed:
            self.init(.modelFailed, startsCooldown: true)
        case .timedOut:
            self.init(.modelTimedOut, startsCooldown: true)
        case .validationRejected:
            self.init(.validationRejected, startsCooldown: true)
        }
    }
}

/// What the on-device model's answer to a repair request leads to.
enum EditorFlowModelRepairAnswer: Equatable {
    /// A repair, still to be checked with Apple's checker before anyone sees it.
    case candidate(sentence: String, edits: [EditorFlowCorrectionEdit])
    /// The model left the sentence as it was.
    case unchanged
    case failure(EditorFlowModelFailure)
}

/// The model's repair once Apple's checker has seen its sentence.
enum EditorFlowModelSuggestion: Equatable {
    /// Always for review: the model's repairs never apply by themselves.
    case review(EditorFlowSuggestion)
    /// Not shown; `startsCooldown` keeps the model off this sentence for a while.
    case rejected(EditorFlowRepairEnd, startsCooldown: Bool)
}

/// Decisions writing assistance (Flow) makes the same way in Source and in Preview: which checker
/// results become a fix, whether a fix applies at once or waits for review, when the on-device
/// model is asked and what its answers lead to, and which edits keep clear of Markdown syntax.
/// `EditorFlowPipeline` runs the checker, planners and models through these for both editors; only
/// how a suggestion is shown and taken differs between Source and Preview.
enum EditorFlowRepairPolicy {
    // MARK: - Routing a check

    /// What Apple's answer for a checked sentence leads to. An issue in protected Markdown, wholly
    /// or in part, is never Flow's to fix; fixes come only from a check of a whole sentence that
    /// offers them as one batch; a clean sentence may still go to the model when on-device writing
    /// assistance is on.
    static func step(
        afterChecking results: [NSTextCheckingResult],
        snapshot: EditorFlowCheckSnapshot,
        protectedRanges: [NSRange]
    ) -> EditorFlowCheckStep {
        let allDetectedIssues = EditorFlowCorrectionResolver.detectedIssues(
            in: snapshot.checkedText,
            caretUTF16Offset: (snapshot.checkedText as NSString).length,
            results: results,
            options: snapshot.options
        )
        let (issues, hasPartiallyProtectedIssue) = unprotectedIssues(
            allDetectedIssues,
            checkedRange: snapshot.checkedRange,
            protectedRanges: protectedRanges
        )
        if hasPartiallyProtectedIssue || issues.isEmpty && !allDetectedIssues.isEmpty {
            return .end(.unresolved(.protected))
        }
        if issues.isEmpty {
            guard snapshot.coversWholeCurrentSentence else { return .end(.blocked) }
            return snapshot.offersSentenceBatch && snapshot.options.onDeviceProseCompletions
                ? .modelRepair
                : .end(.clear(.clean))
        }
        guard snapshot.offersSentenceBatch else { return .end(.unresolved(.unresolvedAppleResult)) }
        return .resolve(issues)
    }

    /// Apple's fixes and alternatives in a sentence with issues. With more misspelled words than
    /// can be looked up, nothing resolves, and the sentence goes to the model.
    static func appleCandidates(
        in results: [NSTextCheckingResult],
        snapshot: EditorFlowCheckSnapshot
    ) -> EditorFlowAppleCandidates {
        let checked = snapshot.checkedText
        let caret = (checked as NSString).length
        let spellingLookups = snapshot.options.checksSpelling
            ? EditorFlowCorrectionResolver.spellingCandidateLookups(
                in: checked,
                caretUTF16Offset: caret,
                results: results
            )
            : []
        guard let spellingLookups else {
            return EditorFlowAppleCandidates(concrete: [], alternatives: [], spellingLookups: [])
        }
        let concrete = EditorFlowCorrectionResolver.concreteCorrections(
            in: checked,
            caretUTF16Offset: caret,
            results: results
        ).filter { candidate in
            switch candidate.kind {
            case .spelling: return snapshot.options.checksSpelling
            case .grammar: return snapshot.options.checksGrammar
            }
        }
        return EditorFlowAppleCandidates(
            concrete: concrete,
            alternatives: EditorFlowCorrectionResolver.ambiguousGrammarCorrections(
                in: checked,
                caretUTF16Offset: caret,
                results: results
            ),
            spellingLookups: spellingLookups
        )
    }

    /// The alternatives Apple's guesses for a misspelled word make, or nil when its automatic fix
    /// already is the only guess.
    static func spellingAlternative(
        for lookup: EditorFlowSpellingCandidateLookup,
        candidateResults: [NSTextCheckingResult],
        in checkedText: String
    ) -> EditorFlowAlternativeCandidate? {
        let replacements = EditorFlowCorrectionResolver.spellingReviewReplacements(
            in: checkedText,
            lookup: lookup,
            candidateResults: candidateResults
        )
        guard replacements.contains(where: { $0 != lookup.primaryReplacement }) else { return nil }
        return EditorFlowAlternativeCandidate(range: lookup.range, replacementTexts: replacements, kind: .spelling)
    }

    /// What a sentence's fixes and alternatives lead to. Exactly one issue with alternatives has
    /// them checked first, and a spelling one always waits for review; with more than one, nothing
    /// is presented and the sentence goes to the model.
    static func step(
        concreteCandidates: [EditorFlowCorrectionCandidate],
        alternatives: [EditorFlowAlternativeCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        protectedRanges: [NSRange],
        sourceUTF16Length: Int
    ) -> EditorFlowCandidateStep {
        if alternatives.count == 1, let alternative = alternatives.first {
            let remaining = concreteCandidates.filter {
                $0.range != alternative.range || $0.kind != alternative.kind
            }
            if let candidate = alternativeCandidateForValidation(
                alternative,
                concreteCandidates: remaining,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                protectedRanges: protectedRanges,
                sourceUTF16Length: sourceUTF16Length
            ) {
                return .validate(candidate, concreteCandidates: remaining, forcesReview: candidate.kind == .spelling)
            }
        }
        return .present(alternatives.isEmpty ? concreteCandidates : [])
    }

    /// How a sentence ends when Apple's issues resolved into nothing Flow could show, or nil when
    /// the model is asked to repair it: it is not when the user already turned this fix down or
    /// took it back.
    static func end(
        afterUnresolvedFixes candidates: [EditorFlowCorrectionCandidate],
        snapshot: EditorFlowCheckSnapshot,
        suppression: EditorFlowSuggestionSuppression?
    ) -> EditorFlowRepairEnd? {
        suppression?.applies(to: candidates, snapshot: snapshot) == true
            ? .unresolved(.suppressedDuplicate)
            : nil
    }

    // MARK: - The on-device model's repairs

    /// What the model's answer leads to. A repair must keep every protected fragment as it was and
    /// pass `EditorFlowAIRepairValidator`, or the model counts as failing.
    static func modelRepairAnswer(
        _ outcome: FlowModelOutcome,
        snapshot: EditorFlowCheckSnapshot
    ) -> EditorFlowModelRepairAnswer {
        if let failure = EditorFlowModelFailure(outcome) { return .failure(failure) }
        guard case let .success(sentence) = outcome, sentence != snapshot.checkedText else { return .unchanged }
        guard protectedFragments(in: sentence, mode: snapshot.sourceMode)
                == protectedFragments(in: snapshot.checkedText, mode: snapshot.sourceMode),
              let edits = EditorFlowAIRepairValidator.edits(
                originalSentence: snapshot.checkedText,
                candidateSentence: sentence
              )
        else { return .failure(EditorFlowModelFailure(.validationRejected, startsCooldown: true)) }
        return .candidate(sentence: sentence, edits: edits)
    }

    /// How a sentence ends when the model gives no repair for it: Apple's issues are left to the
    /// system, and a sentence Apple found clean is clear for completions. A failure starts the
    /// sentence's cooldown only in the first case.
    static func end(
        withoutModelRepair failure: EditorFlowModelFailure,
        appleFoundIssues: Bool
    ) -> (end: EditorFlowRepairEnd, startsCooldown: Bool) {
        appleFoundIssues
            ? (.unresolved(failure.reason), failure.startsCooldown)
            : (.clear(failure.reason), false)
    }

    /// How a sentence ends when the model left it as it was; this also ends any cooldown.
    static func end(forUnchangedSentenceAfterAppleFoundIssues appleFoundIssues: Bool) -> EditorFlowRepairEnd {
        appleFoundIssues ? .unresolved(.validationRejected) : .clear(.clean)
    }

    /// The model's repair once Apple has checked its sentence: shown for review only when the
    /// sentence checks clean, the user has not already turned down exactly these edits, and no edit
    /// touches protected Markdown.
    static func modelSuggestion(
        sentence: String,
        edits: [EditorFlowCorrectionEdit],
        checkResults: [NSTextCheckingResult],
        orthography: NSOrthography?,
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        protectedRanges: [NSRange],
        suppression: EditorFlowSuggestionSuppression?
    ) -> EditorFlowModelSuggestion {
        guard orthography != nil, allCheckingResultsAreClean(checkResults) else {
            let outcome = end(
                withoutModelRepair: EditorFlowModelFailure(.validationRejected, startsCooldown: true),
                appleFoundIssues: appleFoundIssues
            )
            return .rejected(outcome.end, startsCooldown: outcome.startsCooldown)
        }
        let absoluteEdits = edits.map { edit in
            EditorFlowCorrectionEdit(
                range: NSRange(location: snapshot.checkedRange.location + edit.range.location, length: edit.range.length),
                originalText: edit.originalText,
                replacementText: edit.replacementText,
                kind: edit.kind
            )
        }
        if let suppression,
           suppression.edits.count == absoluteEdits.count,
           absoluteEdits.allSatisfy(suppression.suppresses) {
            return .rejected(.unresolved(.suppressedDuplicate), startsCooldown: false)
        }
        guard absoluteEdits.allSatisfy({
            editRangeIsOutsideProtectedRanges($0.range, protectedRanges: protectedRanges)
        }) else {
            return .rejected(.unresolved(.validationRejected), startsCooldown: true)
        }
        return .review(EditorFlowSuggestion(
            documentID: snapshot.documentID,
            revision: snapshot.revision,
            selectedRange: snapshot.selectedRange,
            caretUTF16Offset: snapshot.caretUTF16Offset,
            sentenceRange: snapshot.checkedRange,
            originalSentence: snapshot.checkedText,
            correctedSentence: sentence,
            source: .ai,
            acceptance: .reviewOnly,
            edits: absoluteEdits
        ))
    }

    // MARK: - Protected Markdown

    /// Protected ranges after `length` UTF-16 units were inserted at `location`: a range that starts
    /// at the insertion or after it moves past it.
    static func rebasedProtectedRanges(
        _ ranges: [NSRange],
        insertingAt location: Int,
        length: Int
    ) -> [NSRange] {
        ranges.map { range in
            guard range.location >= location else { return range }
            return NSRange(location: range.location + length, length: range.length)
        }
    }

    /// Whether the selection is a caret with no protected Markdown at it: the character after it,
    /// or the last one at the end of the text.
    static func caretIsOutsideProtectedRanges(
        _ ranges: [NSRange],
        selection: NSRange,
        sourceUTF16Length: Int
    ) -> Bool {
        guard selection.length == 0 else { return false }
        guard sourceUTF16Length > 0 else { return true }
        let caret = min(max(0, selection.location), sourceUTF16Length)
        let probe = caret < sourceUTF16Length
            ? NSRange(location: caret, length: 1)
            : NSRange(location: sourceUTF16Length - 1, length: 1)
        return !ranges.contains { NSIntersectionRange($0, probe).length > 0 }
    }

    static func editRangeIsOutsideProtectedRanges(
        _ range: NSRange,
        protectedRanges: [NSRange]
    ) -> Bool {
        if range.length == 0 {
            // NSRange is half-open. An insertion at either boundary is
            // outside the protected source; only an insertion strictly
            // between its bounds would alter protected syntax.
            return !protectedRanges.contains {
                range.location > $0.location
                    && range.location < NSMaxRange($0)
            }
        }
        return !protectedRanges.contains {
            NSIntersectionRange($0, range).length > 0
        }
    }

    static func insertionRemainsOutsideProtectedSyntax(
        in source: NSString,
        insertionLocation: Int,
        replacement: String,
        mode: FlowSourceMode
    ) -> Bool {
        let maximumExcerptLength = 2_048
        let replacementLength = (replacement as NSString).length
        let maximumSourceLength = maximumExcerptLength - replacementLength
        let tentativeStart = max(0, insertionLocation - maximumSourceLength / 2)
        let precedingNewline = source.range(
            of: "\n",
            options: .backwards,
            range: NSRange(
                location: tentativeStart,
                length: insertionLocation - tentativeStart
            )
        )
        let excerptStart = precedingNewline.location == NSNotFound
            ? tentativeStart
            : NSMaxRange(precedingNewline)
        let maximumEnd = min(source.length, excerptStart + maximumSourceLength)
        let followingNewline = source.range(
            of: "\n",
            range: NSRange(
                location: insertionLocation,
                length: maximumEnd - insertionLocation
            )
        )
        let excerptEnd = followingNewline.location == NSNotFound
            ? maximumEnd
            : NSMaxRange(followingNewline)
        let excerptRange = NSRange(
            location: excerptStart,
            length: excerptEnd - excerptStart
        )
        guard insertionLocation >= excerptStart,
              insertionLocation <= excerptEnd
        else { return false }
        let sourceExcerpt = source.substring(with: excerptRange) as NSString
        let localInsertedRange = NSRange(
            location: insertionLocation - excerptStart,
            length: replacementLength
        )
        let excerpt = sourceExcerpt.replacingCharacters(
            in: NSRange(location: localInsertedRange.location, length: 0),
            with: replacement
        )
        let excerptLength = (excerpt as NSString).length
        let localCaret = NSMaxRange(localInsertedRange)
        let caretProbe: NSRange?
        if localCaret < excerptLength {
            caretProbe = NSRange(location: localCaret, length: 1)
        } else if localCaret > 0 {
            caretProbe = NSRange(location: localCaret - 1, length: 1)
        } else {
            caretProbe = nil
        }
        let ranges = FlowProtectedRangeService().protectedRanges(
            in: excerpt,
            mode: mode
        )
        return !ranges.contains { protectedRange in
            NSIntersectionRange(protectedRange, localInsertedRange).length > 0
                || caretProbe.map {
                    NSIntersectionRange(protectedRange, $0).length > 0
                } == true
        }
    }

    static func isFlowAutocompleteTrigger(_ replacement: String) -> Bool {
        guard !replacement.isEmpty,
              !replacement.containsNewline,
              replacement != "\t",
              replacement.count == 1
        else { return false }
        return replacement.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func protectedFragments(
        in text: String,
        mode: FlowSourceMode
    ) -> [String] {
        let source = text as NSString
        return FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
            .compactMap { range in
                guard range.location != NSNotFound,
                      range.location >= 0,
                      range.length > 0,
                      NSMaxRange(range) <= source.length
                else { return nil }
                return source.substring(with: range)
            }
    }

    // MARK: - Fixes

    /// Apple's issues in the checked sentence that do not lie wholly inside protected Markdown. An
    /// issue that only partly overlaps protected source is reported, imprecise, so the sentence is
    /// left unresolved rather than half of a code span or link repaired.
    private static func unprotectedIssues(
        _ issues: [EditorFlowDetectedIssue],
        checkedRange: NSRange,
        protectedRanges: [NSRange]
    ) -> (issues: [EditorFlowDetectedIssue], hasPartiallyProtectedIssue: Bool) {
        var hasPartiallyProtectedIssue = false
        let unprotected = issues.compactMap { issue -> EditorFlowDetectedIssue? in
            let absoluteRange = NSRange(
                location: checkedRange.location + issue.range.location,
                length: issue.range.length
            )
            let protectedIntersection = protectedRanges.reduce(0) { length, protectedRange in
                length + NSIntersectionRange(protectedRange, absoluteRange).length
            }
            if protectedIntersection >= absoluteRange.length {
                return nil
            }
            if protectedIntersection > 0 {
                hasPartiallyProtectedIssue = true
                return EditorFlowDetectedIssue(
                    range: issue.range,
                    kind: issue.kind,
                    hasPreciseRange: false
                )
            }
            return issue
        }
        return (unprotected, hasPartiallyProtectedIssue)
    }

    private static func alternativeCandidateForValidation(
        _ candidate: EditorFlowAlternativeCandidate,
        concreteCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        protectedRanges: [NSRange],
        sourceUTF16Length: Int
    ) -> EditorFlowAlternativeCandidate? {
        let checksCandidateKind: Bool
        switch candidate.kind {
        case .spelling:
            checksCandidateKind = snapshot.options.checksSpelling
        case .grammar:
            checksCandidateKind = snapshot.options.checksGrammar
        }
        guard snapshot.offersSentenceBatch,
              checksCandidateKind,
              !candidate.replacementTexts.isEmpty,
              candidate.replacementTexts.count <= EditorFlowCorrectionResolver
                .maximumValidatedAlternatives,
              detectedIssues.contains(where: {
                $0.range == candidate.range && $0.kind == candidate.kind
              })
        else { return nil }

        let checkedSource = snapshot.checkedText as NSString
        guard candidate.range.location >= 0,
              candidate.range.length > 0,
              NSMaxRange(candidate.range) <= checkedSource.length,
              concreteCandidates.allSatisfy({
                NSIntersectionRange($0.range, candidate.range).length == 0
              })
        else { return nil }
        let absoluteRange = NSRange(
            location: snapshot.checkedRange.location + candidate.range.location,
            length: candidate.range.length
        )
        guard NSMaxRange(absoluteRange) <= sourceUTF16Length,
              !protectedRanges.contains(where: {
                NSIntersectionRange($0, absoluteRange).length > 0
              })
        else { return nil }

        return candidate
    }

    /// The concrete fixes once Apple's alternatives for one issue have been checked: the first
    /// alternative that leaves the sentence clean joins the other fixes, and two or more clean
    /// ones become the choices a review offers.
    static func resolvedAlternativeCandidates(
        _ candidate: EditorFlowAlternativeCandidate,
        cleanReplacements: [String],
        concreteCandidates: [EditorFlowCorrectionCandidate],
        checkedRange: NSRange
    ) -> (candidates: [EditorFlowCorrectionCandidate], reviewAlternatives: EditorFlowReviewAlternatives?) {
        var resolvedCandidates = concreteCandidates
        if let replacement = cleanReplacements.first {
            resolvedCandidates.append(EditorFlowCorrectionCandidate(
                range: candidate.range,
                replacementText: replacement,
                kind: candidate.kind
            ))
        }
        resolvedCandidates.sort { left, right in
            if left.range.location == right.range.location {
                return left.range.length < right.range.length
            }
            return left.range.location < right.range.location
        }
        let reviewAlternatives: EditorFlowReviewAlternatives?
        if cleanReplacements.count > 1 {
            reviewAlternatives = EditorFlowReviewAlternatives(
                absoluteRange: NSRange(
                    location: checkedRange.location + candidate.range.location,
                    length: candidate.range.length
                ),
                replacementTexts: cleanReplacements,
                kind: candidate.kind
            )
        } else {
            reviewAlternatives = nil
        }
        return (resolvedCandidates, reviewAlternatives)
    }

    /// The deterministic repair for a checked sentence, or nil when Apple's results do not resolve
    /// into one exact, conflict-free set of fixes covering every issue it found. A fix that
    /// deletes letters, any grammar fix that touches words, a fix with alternatives, and a forced
    /// review all wait for the user; the rest apply at once.
    static func deterministicSuggestion(
        candidates localCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        protectedRanges ranges: [NSRange],
        sourceUTF16Length sourceLength: Int,
        suppression: EditorFlowSuggestionSuppression?,
        reviewAlternatives: EditorFlowReviewAlternatives? = nil,
        forcesReview: Bool = false
    ) -> EditorFlowSuggestion? {
        guard !localCandidates.isEmpty,
              !detectedIssues.isEmpty,
              detectedIssues.allSatisfy(\.hasPreciseRange),
              snapshot.offersSentenceBatch
        else { return nil }
        let caretProbe: NSRange?
        if snapshot.caretUTF16Offset < sourceLength {
            caretProbe = NSRange(location: snapshot.caretUTF16Offset, length: 1)
        } else if snapshot.caretUTF16Offset > 0 {
            caretProbe = NSRange(location: snapshot.caretUTF16Offset - 1, length: 1)
        } else {
            caretProbe = nil
        }
        if !snapshot.checksCompletedStructuralSentence {
            guard caretProbe.map({ probe in
                !ranges.contains { NSIntersectionRange($0, probe).length > 0 }
            }) != false else { return nil }
        }

        let checkedSource = snapshot.checkedText as NSString
        let eligibleCandidates = localCandidates.compactMap { candidate -> EditorFlowCorrectionEdit? in
            guard (candidate.kind == .spelling && snapshot.options.checksSpelling) ||
                    (candidate.kind == .grammar && snapshot.options.checksGrammar)
            else { return nil }
            let absoluteRange = NSRange(
                location: snapshot.checkedRange.location + candidate.range.location,
                length: candidate.range.length
            )
            guard NSMaxRange(absoluteRange) <= sourceLength,
                  editRangeIsOutsideProtectedRanges(
                      absoluteRange,
                      protectedRanges: ranges
                  )
            else { return nil }
            let originalText = checkedSource.substring(with: candidate.range)
            return EditorFlowCorrectionEdit(
                range: absoluteRange,
                originalText: originalText,
                replacementText: candidate.replacementText,
                kind: candidate.kind
            )
        }
        let eligibleLocalCandidates = eligibleCandidates.map { edit in
            (
                range: NSRange(
                    location: edit.range.location - snapshot.checkedRange.location,
                    length: edit.range.length
                ),
                kind: edit.kind
            )
        }
        var eligibleEdits: [EditorFlowCorrectionEdit] = []
        for edit in eligibleCandidates {
            if let duplicateIndex = eligibleEdits.firstIndex(where: {
                $0.range == edit.range && $0.replacementText == edit.replacementText
            }) {
                if eligibleEdits[duplicateIndex].kind == .grammar, edit.kind == .spelling {
                    eligibleEdits[duplicateIndex] = edit
                }
            } else {
                eligibleEdits.append(edit)
            }
        }
        let conflictFreeEdits = eligibleEdits.enumerated().compactMap { index, edit in
            let overlapsAnother = eligibleEdits.enumerated().contains { otherIndex, other in
                guard index != otherIndex else { return false }
                return NSIntersectionRange(edit.range, other.range).length > 0
            }
            return overlapsAnother ? nil : edit
        }
        let unsuppressedEdits = conflictFreeEdits.filter {
            suppression?.suppresses($0) != true
        }
        guard unsuppressedEdits.count == eligibleEdits.count,
              conflictFreeEdits.count == eligibleEdits.count,
              !unsuppressedEdits.isEmpty
        else { return nil }
        let selectedLocalEdits = unsuppressedEdits.map { edit in
            (
                range: NSRange(
                    location: edit.range.location - snapshot.checkedRange.location,
                    length: edit.range.length
                ),
                kind: edit.kind
            )
        }
        func overlaps(_ left: NSRange, _ right: NSRange) -> Bool {
            NSIntersectionRange(left, right).length > 0
                || left.length == 0 && left.location >= right.location && left.location <= NSMaxRange(right)
                || right.length == 0 && right.location >= left.location && right.location <= NSMaxRange(left)
        }
        guard detectedIssues.allSatisfy({ issue in
            eligibleLocalCandidates.contains {
                $0.kind == issue.kind && overlaps($0.range, issue.range)
            }
        }), selectedLocalEdits.allSatisfy({ edit in
            detectedIssues.contains {
                $0.kind == edit.kind && overlaps(edit.range, $0.range)
            }
        }) else { return nil }
        let selectedEdits = unsuppressedEdits
        guard let correctedSentence = applying(
            selectedEdits,
            to: snapshot.checkedText,
            sentenceRange: snapshot.checkedRange
        ) else { return nil }
        let hasLetterDeletingSpellingRepair = selectedEdits.contains { edit in
            edit.kind == .spelling
                && edit.replacementText.filter { $0.isLetter || $0.isNumber }.count
                    < edit.originalText.filter { $0.isLetter || $0.isNumber }.count
        }
        let hasLexicalGrammarRepair = selectedEdits.contains { edit in
            guard edit.kind == .grammar else { return false }
            return edit.originalText.contains { $0.isLetter || $0.isNumber }
                || edit.replacementText.contains { $0.isLetter || $0.isNumber }
        }
        let acceptance: EditorFlowSuggestionAcceptance = forcesReview
            || reviewAlternatives != nil
            || hasLetterDeletingSpellingRepair
            || hasLexicalGrammarRepair
            ? .reviewOnly
            : .direct
        return EditorFlowSuggestion(
            documentID: snapshot.documentID,
            revision: snapshot.revision,
            selectedRange: snapshot.selectedRange,
            caretUTF16Offset: snapshot.caretUTF16Offset,
            sentenceRange: snapshot.checkedRange,
            originalSentence: snapshot.checkedText,
            correctedSentence: correctedSentence,
            source: .deterministic,
            acceptance: acceptance,
            edits: selectedEdits,
            reviewAlternatives: reviewAlternatives
        )
    }

    /// Whether a sentence with one of Apple's alternatives in it checks clean. The checker is asked
    /// for everything (`EditorFlowCheckingTypes.validation`); grammar counts only while it is
    /// checked, and with spelling off only a misspelling in the alternative itself counts.
    static func checkingValidationIsClean(
        _ results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        options: EditorTextCheckingOptions,
        requiredSpellingRange: NSRange,
        checkedUTF16Length: Int
    ) -> Bool {
        orthography != nil && !results.contains { result in
            switch result.resultType {
            case .grammar:
                return options.checksGrammar
            case .spelling, .correction:
                guard !options.checksSpelling else { return true }
                guard result.range.location != NSNotFound,
                      result.range.location >= 0,
                      result.range.length > 0,
                      NSMaxRange(result.range) <= checkedUTF16Length
                else { return true }
                return NSIntersectionRange(
                    result.range,
                    requiredSpellingRange
                ).length > 0
            default:
                return false
            }
        }
    }

    private static func allCheckingResultsAreClean(
        _ results: [NSTextCheckingResult]
    ) -> Bool {
        !results.contains {
            $0.resultType == .grammar
                || $0.resultType == .spelling
                || $0.resultType == .correction
        }
    }

    static func repairLocale(from orthography: NSOrthography?) -> Locale {
        guard let language = orthography?.dominantLanguage,
              !language.isEmpty,
              Locale(identifier: language).language.languageCode
                != Locale.LanguageCode("und")
        else { return .current }
        return Locale(identifier: language)
    }

    static func validationSentence(
        _ sentence: String,
        alternativeCandidate: EditorFlowAlternativeCandidate,
        alternativeReplacement: String,
        concreteCandidates: [EditorFlowCorrectionCandidate]
    ) -> (text: String, replacementRange: NSRange)? {
        var replacements = concreteCandidates
        replacements.append(EditorFlowCorrectionCandidate(
            range: alternativeCandidate.range,
            replacementText: alternativeReplacement,
            kind: alternativeCandidate.kind
        ))
        replacements.sort { left, right in
            if left.range.location == right.range.location {
                return left.range.length < right.range.length
            }
            return left.range.location < right.range.location
        }
        var unique: [EditorFlowCorrectionCandidate] = []
        for replacement in replacements {
            if let previous = unique.last {
                if previous.range == replacement.range,
                   previous.replacementText == replacement.replacementText {
                    continue
                }
                guard NSIntersectionRange(previous.range, replacement.range).length == 0 else {
                    return nil
                }
            }
            unique.append(replacement)
        }
        let result = NSMutableString(string: sentence)
        for replacement in unique.reversed() {
            guard replacement.range.location >= 0,
                  replacement.range.length > 0,
                  NSMaxRange(replacement.range) <= result.length
            else { return nil }
            result.replaceCharacters(
                in: replacement.range,
                with: replacement.replacementText
            )
        }
        let precedingDelta = unique.reduce(0) { delta, replacement in
            guard replacement.range.location < alternativeCandidate.range.location else {
                return delta
            }
            return delta
                + (replacement.replacementText as NSString).length
                - replacement.range.length
        }
        return (
            result as String,
            NSRange(
                location: alternativeCandidate.range.location + precedingDelta,
                length: (alternativeReplacement as NSString).length
            )
        )
    }

    static func applying(
        _ edits: [EditorFlowCorrectionEdit],
        to sentence: String,
        sentenceRange: NSRange
    ) -> String? {
        let result = NSMutableString(string: sentence)
        for edit in edits.reversed() {
            let localRange = NSRange(
                location: edit.range.location - sentenceRange.location,
                length: edit.range.length
            )
            guard localRange.location >= 0,
                  localRange.length >= 0,
                  NSMaxRange(localRange) <= result.length
            else { return nil }
            result.replaceCharacters(in: localRange, with: edit.replacementText)
        }
        return result as String
    }
}

/// A suggestion the user accepted or dismissed. It is kept while its sentence (or, once accepted,
/// its corrected words) is still in the document, so the same fix is not offered again: after an
/// undo, a Delete that takes a fix back, or Esc.
struct EditorFlowSuggestionSuppression {
    struct Anchor {
        let range: NSRange
        let text: String
    }

    let documentID: String
    let originalAnchor: Anchor
    let edits: [EditorFlowCorrectionEdit]
    let acceptedAnchors: [Anchor]?

    init(_ suggestion: EditorFlowSuggestion, accepted: Bool) {
        documentID = suggestion.documentID
        originalAnchor = Anchor(
            range: suggestion.sentenceRange,
            text: suggestion.originalSentence
        )
        edits = suggestion.edits
        guard accepted else {
            acceptedAnchors = nil
            return
        }
        var delta = 0
        acceptedAnchors = suggestion.edits.map { edit in
            let replacementLength = (edit.replacementText as NSString).length
            let anchor = Anchor(
                range: NSRange(
                    location: edit.range.location + delta,
                    length: replacementLength
                ),
                text: edit.replacementText
            )
            delta += replacementLength - edit.range.length
            return anchor
        }
    }

    func suppresses(_ candidateEdit: EditorFlowCorrectionEdit) -> Bool {
        edits.contains {
            $0.range == candidateEdit.range
                && $0.originalText == candidateEdit.originalText
                && $0.replacementText == candidateEdit.replacementText
        }
    }

    func targetStillExists(in text: String) -> Bool {
        let source = text as NSString
        let originalStillExists = originalAnchor.range.location >= 0
            && NSMaxRange(originalAnchor.range) <= source.length
            && source.substring(with: originalAnchor.range) == originalAnchor.text
        if originalStillExists { return true }
        guard let acceptedAnchors,
              acceptedAnchors.allSatisfy({
            $0.range.location >= 0
                && NSMaxRange($0.range) <= source.length
                && source.substring(with: $0.range) == $0.text
        })
        else { return false }
        return true
    }

    func matchesCheckedSource(
        documentID: String?,
        checkedRange: NSRange,
        checkedText: String
    ) -> Bool {
        self.documentID == documentID
            && originalAnchor.range == checkedRange
            && originalAnchor.text == checkedText
    }

    /// Whether this suppression covers what a check just found: the same sentence, or one of the
    /// same fixes.
    func applies(
        to candidates: [EditorFlowCorrectionCandidate],
        snapshot: EditorFlowCheckSnapshot
    ) -> Bool {
        if matchesCheckedSource(
            documentID: snapshot.documentID,
            checkedRange: snapshot.checkedRange,
            checkedText: snapshot.checkedText
        ) {
            return true
        }
        let checked = snapshot.checkedText as NSString
        return candidates.contains { candidate in
            guard candidate.range.location >= 0,
                  candidate.range.length >= 0,
                  NSMaxRange(candidate.range) <= checked.length
            else { return false }
            return suppresses(EditorFlowCorrectionEdit(
                range: NSRange(
                    location: snapshot.checkedRange.location + candidate.range.location,
                    length: candidate.range.length
                ),
                originalText: checked.substring(with: candidate.range),
                replacementText: candidate.replacementText,
                kind: candidate.kind
            ))
        }
    }
}
