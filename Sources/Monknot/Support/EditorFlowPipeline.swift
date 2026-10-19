import AppKit
import MonknotCore

/// Whether the sentence at the caret leaves room for a completion.
enum EditorFlowRepairGate: Equatable {
    /// A check is running or was cut short, or a fix is shown: nothing is completed.
    case blocked
    /// Nothing for Flow to fix: a completion may follow.
    case clear
    /// Apple found something Flow does not fix, or ran out of time: the system's own marks stay,
    /// and nothing is completed until the sentence changes.
    case nativeFallback

    var allowsAutocomplete: Bool { self == .clear }
    /// Source lets AppKit's own inline predictions show unless a check is still running.
    var allowsNativePrediction: Bool { self != .blocked }
}

/// What keeps writing assistance from checking or completing at the caret right now. Checks wait
/// for `suspended`, `paused`, `unfocused` and `composing` to clear; completions for all of them.
struct EditorFlowHold: OptionSet {
    let rawValue: Int

    /// Flow leaves the text alone and keeps its state: Writing Tools have the text (Source), or
    /// no page is shown (Preview). Nothing is scheduled, checked or scanned.
    static let suspended = EditorFlowHold(rawValue: 1 << 0)
    /// Flow runs nothing where the caret is, and a check asked for ends what was running: a
    /// Preview table cell, or a menu open over the page.
    static let paused = EditorFlowHold(rawValue: 1 << 1)
    /// The editor does not have keyboard focus.
    static let unfocused = EditorFlowHold(rawValue: 1 << 2)
    /// An input method is composing text (Source's marked text).
    static let composing = EditorFlowHold(rawValue: 1 << 3)
    /// Something the editor started holds completions back: Writing Tools about to open
    /// (Source), or a patch on its way to the page (Preview).
    static let completionsDeferred = EditorFlowHold(rawValue: 1 << 4)
    /// A fix is shown: no completion beside it.
    static let repairShown = EditorFlowHold(rawValue: 1 << 5)
}

/// The text a protected-range scan was made of. Its ranges count only while the editor still
/// shows exactly that text.
struct EditorFlowTextStamp: Equatable {
    let revision: Int
    /// Source's count of storage edits, which also sees edits that bypass `textDidChange`.
    let editCount: Int
    let mode: FlowSourceMode
    /// The storage the text is in (Source); nil for Preview's adopted copy.
    let storage: ObjectIdentifier?
}

/// The rest of a completion after the user took its next word, shown again once the sentence
/// checks clear.
struct EditorFlowPendingProseRemainder {
    let documentID: String
    let revision: Int
    let sourceUTF16Length: Int
    let selectedRange: NSRange
    let continuation: String
    /// The completion was on screen when its word was taken, so its rest counts as seen.
    let wasShown: Bool
}

/// What `EditorFlowPipeline` needs from the editor it runs in: the text and caret, what holds
/// Flow back, how a fix or completion is shown, and where an attempt's end is recorded.
@MainActor
protocol EditorFlowPipelineHost: AnyObject {
    var flowDocumentID: String? { get }
    /// nil while Flow is off for the text (Source with no source mode).
    var flowSourceMode: FlowSourceMode? { get }
    var flowOptions: EditorTextCheckingOptions { get }
    var flowText: String { get }
    var flowRevision: Int { get }
    /// nil while there is no caret to check at.
    var flowSelection: NSRange? { get }
    /// The text protected ranges are scanned for now, or nil while none can be.
    var flowTextStamp: EditorFlowTextStamp? { get }
    /// The spelling document Flow's checks run in.
    var flowSpellDocumentTag: Int { get }
    var flowHold: EditorFlowHold { get }

    /// Whether the sentence a fix changes is in view (Source scrolls; Preview always shows it).
    func flowRepairIsVisible(_ suggestion: EditorFlowSuggestion) -> Bool
    /// Shows a fix for review, or applies a direct one. False when that did not happen.
    func flowPresentRepair(_ suggestion: EditorFlowSuggestion) -> Bool
    /// The part of a model's completion the editor can show at `location`, or nil for none.
    func flowVisibleCompletion(_ continuation: String, at location: Int) -> String?
    /// `alreadyShown` is the rest of a completion that was on screen before its word was taken.
    func flowPresentCompletion(_ suggestion: EditorFlowProseSuggestion, alreadyShown: Bool)
    /// Removes the completion shown, if any; true when there was one.
    func flowWithdrawCompletion() -> Bool

    /// A scan's ranges were just adopted.
    func flowDidScanProtectedRanges(_ ranges: [NSRange])
    /// The gate, a completion request or the protected ranges changed (Source's AppKit
    /// predictions and Writing Tools follow them).
    func flowAvailabilityDidChange()
    /// An attempt of `owner` runs for `token`; the same token again continues it (a check that
    /// waited for the protected ranges).
    func flowAttemptDidStart(_ owner: EditorFlowDiagnosticOwner, token: Int)
    /// An attempt ended for `reason`; with a `token`, only that attempt. `refreshingAvailability`
    /// refreshes availability first and notes whether AppKit's predictions came back.
    func flowAttemptDidEnd(
        _ owner: EditorFlowDiagnosticOwner,
        reason: EditorFlowTerminalReason,
        token: Int?,
        refreshingAvailability: Bool
    )
}

/// Writing assistance (Flow) as it runs in either editor: the request tokens, tasks and deadlines,
/// the checker → candidates → validation chain, the on-device model's repairs and completions, and
/// the scan of protected Markdown. Every decision, pause and cooldown comes from
/// `EditorFlowRepairPolicy`; `MarkdownTextEditor.Coordinator` (Source) and
/// `MarkdownPreviewFlowCoordinator` (Preview) supply the text and show what this finds.
///
/// `@preconcurrency`: Source's coordinator is not actor-isolated, like the AppKit delegate it is,
/// and calls in on the main thread as it calls AppKit.
@preconcurrency @MainActor
final class EditorFlowPipeline {
    struct Configuration {
        var checkingClient: EditorFlowCheckingClient = .system
        var proseCompletionService: FlowProseCompletionService = .system
        var sentenceRepairService: FlowSentenceRepairService = .system
        var protectedRangeProvider: @Sendable (String, FlowSourceMode) -> [NSRange] = { text, mode in
            FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
        }
        /// Replaces the planner's pause before a check.
        var checkDelayNanoseconds: UInt64?
        var proseCompletionDelayNanoseconds = EditorFlowTiming.proseCompletionDelayNanoseconds
        var proseOfferDelayNanoseconds = EditorFlowTiming.proseOfferDelayNanoseconds
        var checkingTimeoutNanoseconds = EditorFlowTiming.checkingTimeoutNanoseconds
        var protectedRangesDelayNanoseconds = EditorFlowTiming.protectedRangesDelayNanoseconds
    }

    private struct PendingProtectedRangesRetry {
        let snapshot: EditorFlowCheckSnapshot
        let token: Int
    }

    private struct ProtectedRangesSnapshot {
        let stamp: EditorFlowTextStamp
        let ranges: [NSRange]
    }

    private struct ProseCompletionSnapshot {
        let documentID: String
        let revision: Int
        let sourceUTF16Length: Int
        let selectedRange: NSRange
        let context: EditorFlowProseContext
        let mode: FlowSourceMode
        let options: EditorTextCheckingOptions
    }

    private struct PreparedProseCompletion {
        let snapshot: ProseCompletionSnapshot
        let request: FlowProseCompletionRequest
        let service: FlowProseCompletionService
    }

    private enum ProseCompletionPreparation {
        case prepared(PreparedProseCompletion)
        case terminal(EditorFlowTerminalReason)
    }

    private struct PendingProseCompletionRetry {
        let token: Int
        let expiresAt: Date
    }

    weak var host: EditorFlowPipelineHost?
    let configuration: Configuration
    var gate = EditorFlowRepairGate.blocked
    /// A fix the user took or turned down, not offered again while its sentence is there.
    var suppression: EditorFlowSuggestionSuppression?

    private var requestToken = 0
    private var checkTask: Task<Void, Never>?
    private var repairTask: Task<Void, Never>?
    private var pendingProtectedRangesRetry: PendingProtectedRangesRetry?
    private var proseRequestToken = 0
    private var proseCompletionTask: Task<Void, Never>?
    private var pendingProseCompletionRetry: PendingProseCompletionRetry?
    private var pendingProseRemainder: EditorFlowPendingProseRemainder?
    private var proseCompletionCooldown = EditorFlowModelCooldown()
    private var sentenceRepairCooldown = EditorFlowModelCooldown()
    private var protectedRangesSnapshot: ProtectedRangesSnapshot?
    private var protectedRangesTask: Task<Void, Never>?
    private var protectedRangesGeneration = 0
    private var protectedRangesDelayNanoseconds: UInt64

    init(configuration: Configuration) {
        self.configuration = configuration
        protectedRangesDelayNanoseconds = configuration.protectedRangesDelayNanoseconds
    }

    /// Whether the on-device model is being asked for a completion, or waits to be.
    var isRequestingProseCompletion: Bool {
        proseCompletionTask != nil
    }

    /// Forgets which fixes the user took or turned down and which models failed: the editor
    /// shows another document, or the settings changed.
    func forgetDecisions() {
        suppression = nil
        proseCompletionCooldown.end()
        sentenceRepairCooldown.end()
    }

    /// Drops the suppressed fix once its sentence and corrected words are gone from the text.
    func refreshSuppression() {
        guard let suppression else { return }
        guard let host,
              suppression.documentID == host.flowDocumentID,
              suppression.targetStillExists(in: host.flowText)
        else {
            self.suppression = nil
            return
        }
    }

    // MARK: - Cancelling

    /// Ends every check, model call and completion. Returns whether a completion was running,
    /// waiting or shown.
    @discardableResult
    func cancel(reason: EditorFlowTerminalReason = .stale) -> Bool {
        let hadProseCompletion = cancelProseCompletion(reason: reason)
        attemptEnded(.sentenceRepair, reason)
        cancelChecks()
        return hadProseCompletion
    }

    /// Ends the sentence check in flight and the model's repair, and leaves what is shown.
    func cancelChecks() {
        requestToken &+= 1
        checkTask?.cancel()
        checkTask = nil
        repairTask?.cancel()
        repairTask = nil
        pendingProtectedRangesRetry = nil
    }

    /// Ends the completion asked for, waiting or shown. Returns whether there was one.
    @discardableResult
    func cancelProseCompletion(reason: EditorFlowTerminalReason = .stale) -> Bool {
        let hadCompletion = proseCompletionTask != nil
            || pendingProseCompletionRetry != nil
            || pendingProseRemainder != nil
        proseRequestToken &+= 1
        proseCompletionTask?.cancel()
        proseCompletionTask = nil
        pendingProseCompletionRetry = nil
        pendingProseRemainder = nil
        let hadPresentation = host?.flowWithdrawCompletion() == true
        attemptEnded(.autocomplete, reason)
        return hadCompletion || hadPresentation
    }

    // MARK: - Sentence checks

    /// Checks the sentence at the caret after the planner's pause, or the one ending at
    /// `endOffset` as finished. `immediate` checks at once (Check Document Now).
    func scheduleCheck(
        completedSentenceEndingAt endOffset: Int? = nil,
        requestsAutocompleteAfterClear: Bool = false,
        immediate: Bool = false
    ) {
        guard let host else { return }
        let hold = host.flowHold
        if hold.contains(.suspended) { return }
        if hold.contains(.paused) {
            gate = .blocked
            cancelProseCompletion()
            return
        }
        let options = host.flowOptions
        guard let mode = host.flowSourceMode,
              options.checksSpelling || options.checksGrammar
        else {
            finishSentenceRepairClear(requestsAutocomplete: requestsAutocompleteAfterClear)
            return
        }
        let text = host.flowText
        guard hold.isDisjoint(with: [.unfocused, .composing]),
              let documentID = host.flowDocumentID,
              let selection = host.flowSelection,
              let plan = EditorFlowCheckPlanner.plan(
                in: text,
                selectedRange: endOffset.map { NSRange(location: $0, length: 0) } ?? selection
              )
        else {
            gate = .blocked
            host.flowAvailabilityDidChange()
            return
        }

        let offersSentenceBatch = plan.isBatchSafe
            && (endOffset != nil || plan.offersSentenceBatch)
        gate = .blocked
        cancelProseCompletion()
        host.flowAvailabilityDidChange()

        let token = requestToken
        let snapshot = EditorFlowCheckSnapshot(
            documentID: documentID,
            revision: host.flowRevision,
            checkedText: (text as NSString).substring(with: plan.range),
            checkedRange: plan.range,
            selectedRange: selection,
            caretUTF16Offset: NSMaxRange(selection),
            options: options,
            sourceMode: mode,
            coversWholeCurrentSentence: plan.coversWholeCurrentSentence,
            offersSentenceBatch: offersSentenceBatch,
            checksCompletedStructuralSentence: endOffset != nil,
            requestsAutocompleteAfterClear: requestsAutocompleteAfterClear
        )
        let delayNanoseconds = immediate ? 0 : configuration.checkDelayNanoseconds ?? plan.delayNanoseconds
        checkTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard self.isCurrent(snapshot, token: token) else {
                self.attemptEnded(.sentenceRepair, .stale, token: token)
                return
            }
            self.requestCorrection(for: snapshot, token: token)
        }
    }

    /// A line break finished a sentence: check it as complete.
    func scheduleCompletedSentenceCheck(endingAt endOffset: Int) {
        guard let host,
              endOffset > 0,
              endOffset <= (host.flowText as NSString).length
        else { return }
        cancelChecks()
        scheduleCheck(completedSentenceEndingAt: endOffset)
    }

    private func isCurrent(_ snapshot: EditorFlowCheckSnapshot, token: Int) -> Bool {
        guard token == requestToken,
              let host,
              host.flowHold.isDisjoint(with: [.suspended, .paused, .unfocused, .composing]),
              host.flowSourceMode == snapshot.sourceMode,
              host.flowOptions == snapshot.options,
              host.flowDocumentID == snapshot.documentID,
              host.flowRevision == snapshot.revision,
              host.flowSelection == snapshot.selectedRange,
              snapshot.caretUTF16Offset == NSMaxRange(snapshot.selectedRange),
              snapshot.checkedRange.location >= 0
        else { return false }
        let text = host.flowText as NSString
        return NSMaxRange(snapshot.checkedRange) <= text.length
            && text.substring(with: snapshot.checkedRange) == snapshot.checkedText
    }

    private func requestCorrection(for snapshot: EditorFlowCheckSnapshot, token: Int) {
        guard let host, isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        host.flowAttemptDidStart(.sentenceRepair, token: token)
        let documentTag = host.flowSpellDocumentTag
        armCheckingDeadline(snapshot: snapshot, token: token)
        configuration.checkingClient.request(
            snapshot.checkedText,
            NSRange(location: 0, length: (snapshot.checkedText as NSString).length),
            EditorFlowCheckingTypes.value(for: snapshot.options),
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                self?.receiveResults(
                    results,
                    orthography: orthography,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag
                )
            }
        }
    }

    private func receiveResults(
        _ results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int
    ) {
        guard isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        guard let ranges = currentProtectedRanges else {
            // The scan for this text is still running; it retries with the same token.
            pendingProtectedRangesRetry = PendingProtectedRangesRetry(snapshot: snapshot, token: token)
            return
        }
        checkTask?.cancel()
        checkTask = nil
        pendingProtectedRangesRetry = nil
        let repairLocale = EditorFlowRepairPolicy.repairLocale(from: orthography)
        let detectedIssues: [EditorFlowDetectedIssue]
        switch EditorFlowRepairPolicy.step(afterChecking: results, snapshot: snapshot, protectedRanges: ranges) {
        case let .end(end):
            finish(end, snapshot: snapshot)
            return
        case .modelRepair:
            attemptModelRepair(
                appleFoundIssues: false,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                locale: repairLocale
            )
            return
        case let .resolve(issues):
            detectedIssues = issues
        }
        let candidates = EditorFlowRepairPolicy.appleCandidates(in: results, snapshot: snapshot)
        guard !candidates.spellingLookups.isEmpty else {
            finishAppleCandidateResolution(
                concreteCandidates: candidates.concrete,
                alternativeCandidates: candidates.alternatives,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                protectedRanges: ranges
            )
            return
        }
        armCheckingDeadline(snapshot: snapshot, token: token)
        requestSpellingCandidates(
            candidates,
            nextIndex: 0,
            spellingAlternatives: [],
            detectedIssues: detectedIssues,
            snapshot: snapshot,
            token: token,
            documentTag: documentTag,
            repairLocale: repairLocale,
            protectedRanges: ranges
        )
    }

    private func requestSpellingCandidates(
        _ candidates: EditorFlowAppleCandidates,
        nextIndex: Int,
        spellingAlternatives: [EditorFlowAlternativeCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale,
        protectedRanges: [NSRange]
    ) {
        guard isCurrent(snapshot, token: token) else { return }
        guard nextIndex < candidates.spellingLookups.count else {
            finishAppleCandidateResolution(
                concreteCandidates: candidates.concrete,
                alternativeCandidates: spellingAlternatives + candidates.alternatives,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                protectedRanges: protectedRanges
            )
            return
        }
        let lookup = candidates.spellingLookups[nextIndex]
        configuration.checkingClient.requestCandidates(
            snapshot.checkedText,
            lookup.range,
            EditorFlowCheckingTypes.spellingCandidates,
            documentTag
        ) { [weak self] candidateResults in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(snapshot, token: token) else { return }
                var nextAlternatives = spellingAlternatives
                if let alternative = EditorFlowRepairPolicy.spellingAlternative(
                    for: lookup,
                    candidateResults: candidateResults,
                    in: snapshot.checkedText
                ) {
                    nextAlternatives.append(alternative)
                }
                self.requestSpellingCandidates(
                    candidates,
                    nextIndex: nextIndex + 1,
                    spellingAlternatives: nextAlternatives,
                    detectedIssues: detectedIssues,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag,
                    repairLocale: repairLocale,
                    protectedRanges: protectedRanges
                )
            }
        }
    }

    private func finishAppleCandidateResolution(
        concreteCandidates: [EditorFlowCorrectionCandidate],
        alternativeCandidates: [EditorFlowAlternativeCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale,
        protectedRanges: [NSRange]
    ) {
        guard let host, isCurrent(snapshot, token: token) else { return }
        switch EditorFlowRepairPolicy.step(
            concreteCandidates: concreteCandidates,
            alternatives: alternativeCandidates,
            detectedIssues: detectedIssues,
            snapshot: snapshot,
            protectedRanges: protectedRanges,
            sourceUTF16Length: (host.flowText as NSString).length
        ) {
        case let .validate(candidate, remainingCandidates, forcesReview):
            if checkTask == nil {
                armCheckingDeadline(snapshot: snapshot, token: token)
            }
            validateAlternatives(
                candidate,
                nextIndex: 0,
                cleanReplacements: [],
                concreteCandidates: remainingCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                forcesReview: forcesReview
            )
        case let .present(candidates):
            checkTask?.cancel()
            checkTask = nil
            if !presentCandidates(candidates, detectedIssues: detectedIssues, snapshot: snapshot, token: token) {
                finishAppleCandidatesUnresolved(
                    candidates,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag,
                    repairLocale: repairLocale
                )
            }
        }
    }

    private func finishAppleCandidatesUnresolved(
        _ candidates: [EditorFlowCorrectionCandidate],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale
    ) {
        guard gate != .nativeFallback else { return }
        if let end = EditorFlowRepairPolicy.end(
            afterUnresolvedFixes: candidates,
            snapshot: snapshot,
            suppression: suppression
        ) {
            finish(end, snapshot: snapshot)
        } else {
            attemptModelRepair(
                appleFoundIssues: true,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                locale: repairLocale
            )
        }
    }

    /// Shows the fix Apple's results make, or applies it when it is certain. False when there is
    /// none to show, it is out of view, or the editor did not show it.
    private func presentCandidates(
        _ localCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        reviewAlternatives: EditorFlowReviewAlternatives? = nil,
        forcesReview: Bool = false
    ) -> Bool {
        guard let host,
              isCurrent(snapshot, token: token),
              let ranges = currentProtectedRanges,
              let suggestion = EditorFlowRepairPolicy.deterministicSuggestion(
                candidates: localCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                protectedRanges: ranges,
                sourceUTF16Length: (host.flowText as NSString).length,
                suppression: suppression,
                reviewAlternatives: reviewAlternatives,
                forcesReview: forcesReview
              ),
              suggestion.matches(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                text: host.flowText,
                selectedRange: snapshot.selectedRange
              )
        else { return false }
        guard host.flowRepairIsVisible(suggestion) else {
            finishSentenceRepairUnresolved()
            return false
        }
        cancelProseCompletion()
        gate = .blocked
        attemptEnded(.sentenceRepair, .visibleDeterministicRepair)
        guard host.flowPresentRepair(suggestion) else {
            gate = .nativeFallback
            host.flowAvailabilityDidChange()
            return false
        }
        host.flowAvailabilityDidChange()
        return true
    }

    private func validateAlternatives(
        _ candidate: EditorFlowAlternativeCandidate,
        nextIndex: Int,
        cleanReplacements: [String],
        concreteCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale,
        forcesReview: Bool
    ) {
        guard isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        if nextIndex >= candidate.replacementTexts.count {
            finishAlternativeValidation(
                candidate,
                cleanReplacements: cleanReplacements,
                concreteCandidates: concreteCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                forcesReview: forcesReview
            )
            return
        }
        let replacement = candidate.replacementTexts[nextIndex]
        guard let validation = EditorFlowRepairPolicy.validationSentence(
            snapshot.checkedText,
            alternativeCandidate: candidate,
            alternativeReplacement: replacement,
            concreteCandidates: concreteCandidates
        ) else {
            validateAlternatives(
                candidate,
                nextIndex: nextIndex + 1,
                cleanReplacements: cleanReplacements,
                concreteCandidates: concreteCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                forcesReview: forcesReview
            )
            return
        }
        configuration.checkingClient.request(
            validation.text,
            NSRange(location: 0, length: (validation.text as NSString).length),
            EditorFlowCheckingTypes.validation,
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(snapshot, token: token) else { return }
                var nextCleanReplacements = cleanReplacements
                if EditorFlowRepairPolicy.checkingValidationIsClean(
                       results,
                       orthography: orthography,
                       options: snapshot.options,
                       requiredSpellingRange: validation.replacementRange,
                       checkedUTF16Length: (validation.text as NSString).length
                   ),
                   !nextCleanReplacements.contains(replacement) {
                    nextCleanReplacements.append(replacement)
                }
                self.validateAlternatives(
                    candidate,
                    nextIndex: nextIndex + 1,
                    cleanReplacements: nextCleanReplacements,
                    concreteCandidates: concreteCandidates,
                    detectedIssues: detectedIssues,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag,
                    repairLocale: repairLocale,
                    forcesReview: forcesReview
                )
            }
        }
    }

    private func finishAlternativeValidation(
        _ candidate: EditorFlowAlternativeCandidate,
        cleanReplacements: [String],
        concreteCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale,
        forcesReview: Bool
    ) {
        guard isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        checkTask?.cancel()
        checkTask = nil
        let (resolvedCandidates, reviewAlternatives) = EditorFlowRepairPolicy.resolvedAlternativeCandidates(
            candidate,
            cleanReplacements: cleanReplacements,
            concreteCandidates: concreteCandidates,
            checkedRange: snapshot.checkedRange
        )
        if !presentCandidates(
            resolvedCandidates,
            detectedIssues: detectedIssues,
            snapshot: snapshot,
            token: token,
            reviewAlternatives: reviewAlternatives,
            forcesReview: forcesReview
        ) {
            finishAppleCandidatesUnresolved(
                resolvedCandidates,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale
            )
        }
    }

    /// Leaves the sentence to the system if Apple's checker has not answered in time.
    private func armCheckingDeadline(
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        recordsModelFailureCooldown: Bool = false
    ) {
        checkTask?.cancel()
        let timeout = configuration.checkingTimeoutNanoseconds
        checkTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, self.isCurrent(snapshot, token: token) else { return }
            if recordsModelFailureCooldown {
                self.sentenceRepairCooldown.start(for: snapshot.checkedText)
            }
            self.requestToken &+= 1
            self.checkTask = nil
            self.repairTask?.cancel()
            self.repairTask = nil
            self.pendingProtectedRangesRetry = nil
            self.gate = .nativeFallback
            self.cancelProseCompletion()
            self.attemptEndedAfterRefresh(.sentenceRepair, .checkerTimedOut)
        }
    }

    private func finishSentenceRepairClear(
        requestsAutocomplete: Bool,
        reason: EditorFlowTerminalReason = .clean
    ) {
        sentenceRepairCooldown.end()
        gate = .clear
        attemptEnded(.sentenceRepair, reason)
        if pendingProseRemainder != nil {
            if presentPendingProseRemainderIfReady() {
                return
            }
            pendingProseRemainder = nil
        }
        host?.flowAvailabilityDidChange()
        if requestsAutocomplete {
            scheduleProseCompletion()
        }
    }

    /// Leaves the sentence to the system: its own marks stay, and nothing is completed until the
    /// sentence changes.
    func finishSentenceRepairUnresolved(reason: EditorFlowTerminalReason = .unresolvedAppleResult) {
        gate = .nativeFallback
        cancelProseCompletion()
        attemptEndedAfterRefresh(.sentenceRepair, reason)
    }

    private func finishSentenceRepairBlocked(reason: EditorFlowTerminalReason = .unresolvedAppleResult) {
        gate = .blocked
        cancelProseCompletion()
        attemptEnded(.sentenceRepair, reason)
        host?.flowAvailabilityDidChange()
    }

    /// Ends a sentence check that shows nothing, as `EditorFlowRepairPolicy` decided.
    private func finish(_ end: EditorFlowRepairEnd, snapshot: EditorFlowCheckSnapshot) {
        switch end {
        case let .clear(reason):
            finishSentenceRepairClear(
                requestsAutocomplete: snapshot.requestsAutocompleteAfterClear,
                reason: reason
            )
        case let .unresolved(reason):
            finishSentenceRepairUnresolved(reason: reason)
        case .blocked:
            finishSentenceRepairBlocked()
        }
    }

    // MARK: - The on-device model's repairs

    private func attemptModelRepair(
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        locale: Locale
    ) {
        guard !sentenceRepairCooldown.applies(to: snapshot.checkedText) else {
            finishWithoutModelRepair(
                EditorFlowModelFailure(.retryCoolingDown),
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot
            )
            return
        }
        guard snapshot.offersSentenceBatch,
              host?.flowOptions.onDeviceProseCompletions == true,
              isCurrent(snapshot, token: token),
              currentProtectedRanges != nil,
              let request = FlowSentenceRepairRequest(sentence: snapshot.checkedText, locale: locale)
        else {
            finishWithoutModelRepair(
                EditorFlowModelFailure(.unresolvedAppleResult),
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot
            )
            return
        }
        guard configuration.sentenceRepairService.isAvailable(for: locale) else {
            finishWithoutModelRepair(
                EditorFlowModelFailure(.modelUnavailable),
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot
            )
            return
        }

        gate = .blocked
        cancelProseCompletion()
        repairTask?.cancel()
        let service = configuration.sentenceRepairService
        repairTask = Task { @MainActor [weak self] in
            let outcome = await service.repair(for: request)
            guard !Task.isCancelled else { return }
            self?.receiveModelRepair(
                outcome,
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag
            )
        }
        host?.flowAvailabilityDidChange()
    }

    private func receiveModelRepair(
        _ outcome: FlowModelOutcome,
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int
    ) {
        guard isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        repairTask = nil
        let candidateSentence: String
        let validatedEdits: [EditorFlowCorrectionEdit]
        switch EditorFlowRepairPolicy.modelRepairAnswer(outcome, snapshot: snapshot) {
        case let .failure(failure):
            finishWithoutModelRepair(failure, appleFoundIssues: appleFoundIssues, snapshot: snapshot)
            return
        case .unchanged:
            sentenceRepairCooldown.end()
            finish(
                EditorFlowRepairPolicy.end(forUnchangedSentenceAfterAppleFoundIssues: appleFoundIssues),
                snapshot: snapshot
            )
            return
        case let .candidate(sentence, edits):
            candidateSentence = sentence
            validatedEdits = edits
        }
        // The model's sentence must check clean with Apple's checker before anyone sees it.
        armCheckingDeadline(snapshot: snapshot, token: token, recordsModelFailureCooldown: true)
        configuration.checkingClient.request(
            candidateSentence,
            NSRange(location: 0, length: (candidateSentence as NSString).length),
            EditorFlowCheckingTypes.validation,
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                self?.finishModelRepairValidation(
                    candidateSentence: candidateSentence,
                    validatedEdits: validatedEdits,
                    appleFoundIssues: appleFoundIssues,
                    results: results,
                    orthography: orthography,
                    snapshot: snapshot,
                    token: token
                )
            }
        }
    }

    private func finishModelRepairValidation(
        candidateSentence: String,
        validatedEdits: [EditorFlowCorrectionEdit],
        appleFoundIssues: Bool,
        results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        snapshot: EditorFlowCheckSnapshot,
        token: Int
    ) {
        guard isCurrent(snapshot, token: token) else {
            attemptEnded(.sentenceRepair, .stale, token: token)
            return
        }
        checkTask?.cancel()
        checkTask = nil
        guard let host, let protectedRanges = currentProtectedRanges else {
            finishWithoutModelRepair(
                EditorFlowModelFailure(.validationRejected, startsCooldown: true),
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot
            )
            return
        }
        let suggestion: EditorFlowSuggestion
        switch EditorFlowRepairPolicy.modelSuggestion(
            sentence: candidateSentence,
            edits: validatedEdits,
            checkResults: results,
            orthography: orthography,
            appleFoundIssues: appleFoundIssues,
            snapshot: snapshot,
            protectedRanges: protectedRanges,
            suppression: suppression
        ) {
        case let .rejected(end, startsCooldown):
            if startsCooldown {
                sentenceRepairCooldown.start(for: snapshot.checkedText)
            }
            finish(end, snapshot: snapshot)
            return
        case let .review(value):
            suggestion = value
        }
        guard host.flowRepairIsVisible(suggestion) else {
            finishSentenceRepairUnresolved(reason: .stale)
            return
        }
        sentenceRepairCooldown.end()
        gate = .blocked
        attemptEnded(.sentenceRepair, .visibleAIReviewOnlyRepair)
        guard host.flowPresentRepair(suggestion) else {
            gate = .nativeFallback
            host.flowAvailabilityDidChange()
            return
        }
        host.flowAvailabilityDidChange()
    }

    private func finishWithoutModelRepair(
        _ failure: EditorFlowModelFailure,
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot
    ) {
        let outcome = EditorFlowRepairPolicy.end(withoutModelRepair: failure, appleFoundIssues: appleFoundIssues)
        if outcome.startsCooldown {
            sentenceRepairCooldown.start(for: snapshot.checkedText)
        }
        finish(outcome.end, snapshot: snapshot)
    }

    // MARK: - On-device completions

    private var onDeviceProseCompletionIsAvailable: Bool {
        guard let options = host?.flowOptions else { return false }
        return options.inlinePredictions
            && options.onDeviceProseCompletions
            && configuration.proseCompletionService.isAvailable(for: .current)
    }

    /// Asks the on-device model for a completion after the pause, once the protected ranges are
    /// known; `reusingToken` resumes a request that waited for them.
    func scheduleProseCompletion(delayNanoseconds: UInt64? = nil, reusingToken: Int? = nil) {
        guard onDeviceProseCompletionIsAvailable,
              !proseCompletionCooldown.applies(),
              gate.allowsAutocomplete,
              let host,
              host.flowHold.isEmpty,
              let selection = host.flowSelection,
              EditorFlowProseContextPlanner.context(
                in: host.flowText,
                selectedRange: selection,
                protectedRanges: []
              ) != nil
        else { return }

        let token: Int
        if let reusingToken {
            guard reusingToken == proseRequestToken else { return }
            token = reusingToken
        } else {
            proseRequestToken &+= 1
            token = proseRequestToken
        }
        let delay = delayNanoseconds ?? configuration.proseCompletionDelayNanoseconds
        proseCompletionTask?.cancel()
        pendingProseCompletionRetry = nil
        proseCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.host?.flowAttemptDidStart(.autocomplete, token: token)
            if self?.currentProtectedRanges == nil {
                self?.deferProseCompletionUntilProtectedRanges(token: token)
                return
            }
            guard let self else { return }
            let prepared: PreparedProseCompletion
            switch self.prepareProseCompletion(token: token) {
            case let .prepared(value):
                prepared = value
            case let .terminal(reason):
                self.finishProseCompletionAttempt(token: token, reason: reason)
                return
            }
            let requestStartedAt = Date()
            let outcome = await prepared.service.completion(for: prepared.request)
            guard !Task.isCancelled else { return }
            // A completion never appears sooner than this after it was asked for.
            let elapsed = Date().timeIntervalSince(requestStartedAt)
            let offerDelay = Double(self.configuration.proseOfferDelayNanoseconds) / 1_000_000_000
            if elapsed < offerDelay {
                do {
                    try await Task.sleep(nanoseconds: UInt64((offerDelay - elapsed) * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.receiveProseCompletion(outcome, snapshot: prepared.snapshot, token: token)
        }
        host.flowAvailabilityDidChange()
    }

    private func deferProseCompletionUntilProtectedRanges(token: Int) {
        guard token == proseRequestToken else { return }
        let retryNanoseconds = EditorFlowTiming.protectedRangesRetryNanoseconds
        pendingProseCompletionRetry = PendingProseCompletionRetry(
            token: token,
            expiresAt: Date().addingTimeInterval(Double(retryNanoseconds) / 1_000_000_000)
        )
        proseCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return
            }
            guard let self,
                  token == self.proseRequestToken,
                  self.pendingProseCompletionRetry?.token == token
            else { return }
            self.pendingProseCompletionRetry = nil
            self.proseCompletionTask = nil
            self.attemptEndedAfterRefresh(.autocomplete, .protected)
        }
        host?.flowAvailabilityDidChange()
    }

    private func resumePendingProseCompletionIfReady() {
        guard let retry = pendingProseCompletionRetry else { return }
        pendingProseCompletionRetry = nil
        guard retry.token == proseRequestToken else { return }
        guard retry.expiresAt >= Date() else {
            proseCompletionTask?.cancel()
            proseCompletionTask = nil
            attemptEndedAfterRefresh(.autocomplete, .protected, token: retry.token)
            return
        }
        scheduleProseCompletion(delayNanoseconds: 0, reusingToken: retry.token)
    }

    private func prepareProseCompletion(token: Int) -> ProseCompletionPreparation {
        guard token == proseRequestToken else { return .terminal(.stale) }
        guard onDeviceProseCompletionIsAvailable else { return .terminal(.modelUnavailable) }
        guard !proseCompletionCooldown.applies() else { return .terminal(.modelFailed) }
        guard let host else { return .terminal(.stale) }
        let hold = host.flowHold
        guard hold.isDisjoint(with: [.suspended, .paused, .completionsDeferred]) else {
            return .terminal(.userCancelled)
        }
        guard gate.allowsAutocomplete else { return .terminal(.unresolvedAppleResult) }
        guard let documentID = host.flowDocumentID,
              let mode = host.flowSourceMode,
              let selectedRange = host.flowSelection
        else { return .terminal(.stale) }
        guard !hold.contains(.unfocused) else { return .terminal(.focusLost) }
        guard hold.isDisjoint(with: [.repairShown, .composing]) else { return .terminal(.stale) }
        guard let protectedRanges = currentProtectedRanges else { return .terminal(.protected) }
        let text = host.flowText
        guard let context = EditorFlowProseContextPlanner.context(
            in: text,
            selectedRange: selectedRange,
            protectedRanges: protectedRanges
        ) else {
            let caret = selectedRange.location
            let probe = caret > 0 ? NSRange(location: caret - 1, length: 1) : nil
            return .terminal(probe.map { candidate in
                protectedRanges.contains {
                    NSIntersectionRange($0, candidate).length > 0
                }
            } == true ? .protected : .validationRejected)
        }
        guard let request = FlowProseCompletionRequest(context: context.text, locale: .current) else {
            return .terminal(.validationRejected)
        }
        return .prepared(PreparedProseCompletion(
            snapshot: ProseCompletionSnapshot(
                documentID: documentID,
                revision: host.flowRevision,
                sourceUTF16Length: (text as NSString).length,
                selectedRange: selectedRange,
                context: context,
                mode: mode,
                options: host.flowOptions
            ),
            request: request,
            service: configuration.proseCompletionService
        ))
    }

    private func receiveProseCompletion(
        _ outcome: FlowModelOutcome,
        snapshot: ProseCompletionSnapshot,
        token: Int
    ) {
        guard token == proseRequestToken else {
            attemptEnded(.autocomplete, .stale, token: token)
            return
        }
        proseCompletionTask = nil
        guard isCurrent(snapshot) else {
            attemptEnded(.autocomplete, .stale, token: token)
            host?.flowAvailabilityDidChange()
            return
        }
        if let failure = EditorFlowModelFailure(outcome) {
            if failure.startsCooldown {
                proseCompletionCooldown.start()
            }
            attemptEndedAfterRefresh(.autocomplete, failure.reason)
            return
        }
        guard case let .success(continuation) = outcome,
              let host,
              let visibleContinuation = host.flowVisibleCompletion(
                continuation,
                at: snapshot.selectedRange.location
              ),
              EditorFlowRepairPolicy.insertionRemainsOutsideProtectedSyntax(
                in: host.flowText as NSString,
                insertionLocation: snapshot.selectedRange.location,
                replacement: visibleContinuation,
                mode: snapshot.mode
              )
        else {
            attemptEndedAfterRefresh(.autocomplete, .validationRejected)
            return
        }
        proseCompletionCooldown.end()
        host.flowPresentCompletion(
            EditorFlowProseSuggestion(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                sourceUTF16Length: snapshot.sourceUTF16Length,
                selectedRange: snapshot.selectedRange,
                continuation: visibleContinuation
            ),
            alreadyShown: false
        )
        attemptEnded(.autocomplete, .visibleAutocomplete)
        host.flowAvailabilityDidChange()
    }

    private func finishProseCompletionAttempt(token: Int, reason: EditorFlowTerminalReason) {
        guard token == proseRequestToken else { return }
        proseCompletionTask = nil
        attemptEndedAfterRefresh(.autocomplete, reason)
    }

    private func isCurrent(_ snapshot: ProseCompletionSnapshot) -> Bool {
        guard gate.allowsAutocomplete,
              let host,
              host.flowHold.isEmpty,
              host.flowDocumentID == snapshot.documentID,
              host.flowRevision == snapshot.revision,
              host.flowSourceMode == snapshot.mode,
              host.flowOptions == snapshot.options,
              let selection = host.flowSelection,
              selection == snapshot.selectedRange,
              let protectedRanges = currentProtectedRanges
        else { return false }
        let text = host.flowText
        return (text as NSString).length == snapshot.sourceUTF16Length
            && EditorFlowProseContextPlanner.context(
                in: text,
                selectedRange: selection,
                protectedRanges: protectedRanges
            ) == snapshot.context
    }

    /// Shows the rest of a completion whose next word was just taken, now or once the sentence
    /// checks clear.
    func showProseRemainder(_ remainder: EditorFlowPendingProseRemainder) {
        pendingProseRemainder = remainder
        presentPendingProseRemainderIfReady()
    }

    @discardableResult
    private func presentPendingProseRemainderIfReady() -> Bool {
        guard gate.allowsAutocomplete,
              let pending = pendingProseRemainder,
              let host,
              host.flowHold.isEmpty,
              host.flowDocumentID == pending.documentID,
              host.flowRevision == pending.revision,
              let selection = host.flowSelection,
              selection == pending.selectedRange,
              let mode = host.flowSourceMode,
              let protectedRanges = currentProtectedRanges
        else { return false }
        let text = host.flowText as NSString
        guard text.length == pending.sourceUTF16Length,
              EditorFlowRepairPolicy.caretIsOutsideProtectedRanges(
                protectedRanges,
                selection: selection,
                sourceUTF16Length: text.length
              ),
              EditorFlowRepairPolicy.insertionRemainsOutsideProtectedSyntax(
                in: text,
                insertionLocation: pending.selectedRange.location,
                replacement: pending.continuation,
                mode: mode
              ),
              host.flowVisibleCompletion(
                pending.continuation,
                at: pending.selectedRange.location
              ) == pending.continuation
        else { return false }
        pendingProseRemainder = nil
        host.flowPresentCompletion(
            EditorFlowProseSuggestion(
                documentID: pending.documentID,
                revision: pending.revision,
                sourceUTF16Length: pending.sourceUTF16Length,
                selectedRange: pending.selectedRange,
                continuation: pending.continuation
            ),
            alreadyShown: pending.wasShown
        )
        host.flowAvailabilityDidChange()
        return true
    }

    // MARK: - Protected Markdown

    /// The protected ranges of the text the editor shows now, or nil until a scan of it is in.
    var currentProtectedRanges: [NSRange]? {
        guard let snapshot = protectedRangesSnapshot,
              let stamp = host?.flowTextStamp,
              snapshot.stamp == stamp
        else { return nil }
        return snapshot.ranges
    }

    /// Takes ranges the editor rebased past its own insertion, so what stays on screen can be
    /// taken before the next scan.
    func adoptProtectedRanges(_ ranges: [NSRange]) {
        protectedRangesSnapshot = host?.flowTextStamp.map {
            ProtectedRangesSnapshot(stamp: $0, ranges: ranges)
        }
    }

    /// Forgets the ranges and any scan in flight; the scan, if running, finds nothing to do.
    func invalidateProtectedRanges() {
        protectedRangesGeneration &+= 1
        protectedRangesSnapshot = nil
    }

    /// Stops scanning for good, as the editor goes away.
    func stopProtectedRangeScan() {
        protectedRangesTask?.cancel()
        protectedRangesTask = nil
        protectedRangesSnapshot = nil
    }

    private var canScanProtectedRanges: Bool {
        guard let host else { return false }
        return !host.flowHold.contains(.suspended) && host.flowTextStamp != nil
    }

    /// Rescans the protected Markdown after the pause. `scans` false only forgets the ranges
    /// (Preview reads none with every part of the writing assistance off).
    func scheduleProtectedRangesRefresh(delayNanoseconds: UInt64? = nil, scans: Bool = true) {
        protectedRangesGeneration &+= 1
        protectedRangesDelayNanoseconds = delayNanoseconds ?? configuration.protectedRangesDelayNanoseconds
        protectedRangesSnapshot = nil
        host?.flowAvailabilityDidChange()
        guard scans, protectedRangesTask == nil, canScanProtectedRanges else { return }

        let provider = configuration.protectedRangeProvider
        protectedRangesTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.canScanProtectedRanges else {
                    self?.protectedRangesTask = nil
                    return
                }
                let generation = self.protectedRangesGeneration
                let delay = self.protectedRangesDelayNanoseconds
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        self.protectedRangesTask = nil
                        return
                    }
                }
                guard !Task.isCancelled else {
                    self.protectedRangesTask = nil
                    return
                }
                guard generation == self.protectedRangesGeneration else { continue }
                guard let host = self.host,
                      !host.flowHold.contains(.suspended),
                      let stamp = host.flowTextStamp
                else {
                    self.protectedRangesTask = nil
                    return
                }
                let text = host.flowText
                let mode = stamp.mode
                let worker = Task.detached(priority: .utility) {
                    provider(text, mode)
                }
                let ranges = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else {
                    self.protectedRangesTask = nil
                    return
                }
                guard generation == self.protectedRangesGeneration,
                      self.host?.flowTextStamp == stamp
                else { continue }
                self.protectedRangesSnapshot = ProtectedRangesSnapshot(stamp: stamp, ranges: ranges)
                self.protectedRangesTask = nil
                self.host?.flowDidScanProtectedRanges(ranges)
                if let retry = self.pendingProtectedRangesRetry,
                   retry.snapshot.revision == stamp.revision,
                   self.isCurrent(retry.snapshot, token: retry.token) {
                    self.pendingProtectedRangesRetry = nil
                    self.requestCorrection(for: retry.snapshot, token: retry.token)
                } else if self.gate.allowsAutocomplete {
                    self.resumePendingProseCompletionIfReady()
                }
                return
            }
            self?.protectedRangesTask = nil
        }
    }

    // MARK: - Recording

    private func attemptEnded(
        _ owner: EditorFlowDiagnosticOwner,
        _ reason: EditorFlowTerminalReason,
        token: Int? = nil
    ) {
        host?.flowAttemptDidEnd(owner, reason: reason, token: token, refreshingAvailability: false)
    }

    private func attemptEndedAfterRefresh(
        _ owner: EditorFlowDiagnosticOwner,
        _ reason: EditorFlowTerminalReason,
        token: Int? = nil
    ) {
        host?.flowAttemptDidEnd(owner, reason: reason, token: token, refreshingAvailability: true)
    }
}
