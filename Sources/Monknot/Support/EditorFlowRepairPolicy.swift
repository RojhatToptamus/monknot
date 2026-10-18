import AppKit
import MonknotCore

/// Decisions writing assistance (Flow) makes the same way in Source and in Preview: which checker
/// results become a fix, whether a fix applies at once or waits for review, and which edits keep
/// clear of Markdown syntax. Source's `MarkdownTextEditor.Coordinator` and Preview's
/// `MarkdownPreviewFlowCoordinator` run the same checker, planners and models through these; only
/// how a suggestion is shown and taken differs between the two editors.
enum EditorFlowRepairPolicy {
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

    static func isOrdinaryProseInsertion(
        _ replacement: String,
        in source: NSString,
        at insertionLocation: Int,
        mode: FlowSourceMode
    ) -> Bool {
        guard replacement.count == 1 else { return false }
        if replacement == " " {
            guard mode == .markdown else { return true }
            let precedingRange = NSRange(location: 0, length: insertionLocation)
            let newlineRange = source.range(
                of: "\n",
                options: .backwards,
                range: precedingRange
            )
            let lineStart = newlineRange.location == NSNotFound ? 0 : NSMaxRange(newlineRange)
            let linePrefix = source.substring(with: NSRange(
                location: lineStart,
                length: insertionLocation - lineStart
            ))
            return linePrefix.unicodeScalars.contains {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }
        let scalars = replacement.unicodeScalars
        let isProseScalar: (Unicode.Scalar) -> Bool = {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return scalars.contains(where: isProseScalar)
            && scalars.allSatisfy {
                isProseScalar($0) || CharacterSet.nonBaseCharacters.contains($0)
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

    /// Apple's issues in the checked sentence that do not lie wholly inside protected Markdown. An
    /// issue that only partly overlaps protected source is reported, imprecise, so the caller can
    /// leave the sentence unresolved rather than repair half of a code span or link.
    static func unprotectedIssues(
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

    static func alternativeCandidateForValidation(
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

    static func checkingValidationIsClean(
        _ results: [NSTextCheckingResult],
        options: EditorTextCheckingOptions,
        requiredSpellingRange: NSRange,
        checkedUTF16Length: Int
    ) -> Bool {
        !results.contains { result in
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

    static func allCheckingResultsAreClean(
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
