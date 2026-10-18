import AppKit
import MonknotCore
import SwiftUI

// Writing assistance (Flow) while Preview edits Markdown in place. Source runs it in
// `MarkdownTextEditor.Coordinator` over its text view; Preview runs the same pipeline here, over the
// page's Markdown source and the caret the page reports as a source offset. The checker, the
// planners, Apple's on-device models and every repair decision (`EditorFlowRepairPolicy`) are
// Source's; only the presentation differs. The page shows what this coordinator sends and reports
// the keys that act on it, and whatever the user takes reaches the page as a source patch, like any
// edit the app makes, so it is one step in Preview's undo history.

/// What Preview's writing assistance runs with: macOS spelling and grammar and Apple's on-device
/// models in the app, fakes in tests. The environment carries it to the preview, the way Source's
/// coordinator takes injected clients.
struct MarkdownPreviewFlowDependencies {
    var checkingClient: EditorFlowCheckingClient = .system
    var proseCompletionService: FlowProseCompletionService = .system
    var sentenceRepairService: FlowSentenceRepairService = .system
    /// Replaces the planner's pause before a check, as `flowCheckDelayNanoseconds` does in Source.
    var checkDelayNanoseconds: UInt64?
    var proseCompletionDelayNanoseconds: UInt64 = 360_000_000
    var proseOfferDelayNanoseconds: UInt64 = 420_000_000
    var checkingTimeoutNanoseconds: UInt64 = 2_000_000_000
    var protectedRangesDelayNanoseconds: UInt64 = 140_000_000
    var protectedRangeProvider: @Sendable (String, FlowSourceMode) -> [NSRange] = { text, mode in
        FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
    }
    /// Whether the page's window gives it keyboard focus; the page reports its own focus.
    var windowFocusValidator: (NSView) -> Bool = { view in
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === view
    }
    var writingToolsAvailability: () -> Bool = {
        guard #available(macOS 15.2, *) else { return false }
        return NSWritingToolsCoordinator.isWritingToolsAvailable
    }

    static let system = MarkdownPreviewFlowDependencies()
}

private struct MarkdownPreviewFlowDependenciesKey: EnvironmentKey {
    static let defaultValue = MarkdownPreviewFlowDependencies.system
}

extension EnvironmentValues {
    var markdownPreviewFlowDependencies: MarkdownPreviewFlowDependencies {
        get { self[MarkdownPreviewFlowDependenciesKey.self] }
        set { self[MarkdownPreviewFlowDependenciesKey.self] = newValue }
    }
}

/// What the writing assistance needs from the preview hosting it.
@MainActor
protocol MarkdownPreviewFlowHost: AnyObject {
    /// The page's web view; its window decides whether the page has keyboard focus.
    var flowFocusView: NSView? { get }
    /// Preview's undo history, which Delete right after a fix steps back through.
    var flowUndoManager: UndoManager? { get }
    /// Sends one message to the page's writing-assistance layer (`MonknotEditor.flow`).
    func sendFlow(_ message: [String: Any])
}

@MainActor
final class MarkdownPreviewFlowCoordinator {
    private enum SentenceRepairGate: Equatable {
        case blocked
        case clear
        /// Apple found something Flow cannot resolve: no completion until the sentence changes.
        case nativeFallback

        var allowsAutocomplete: Bool { self == .clear }
    }

    private struct ProtectedRangesSnapshot {
        let revision: Int
        let ranges: [NSRange]
    }

    private struct PendingProtectedRangesRetry {
        let snapshot: EditorFlowCheckSnapshot
        let token: Int
    }

    private struct ProseCompletionSnapshot {
        let documentID: String
        let revision: Int
        let sourceUTF16Length: Int
        let selectedRange: NSRange
        let context: EditorFlowProseContext
        let options: EditorTextCheckingOptions
    }

    private struct PendingProseCompletionRetry {
        let token: Int
        let expiresAt: Date
    }

    private struct PendingProseRemainder {
        let documentID: String
        let revision: Int
        let sourceUTF16Length: Int
        let selectedRange: NSRange
        let continuation: String
        let wasRendered: Bool
    }

    private struct SentenceRepairFailureCooldown {
        let sentence: String
        let until: Date
    }

    /// A correction the page shows for review, with the suggestion each alternative makes of it.
    private struct PresentedRepair {
        let serial: Int
        let suggestion: EditorFlowSuggestion
        let variants: [EditorFlowSuggestion]
    }

    /// A completion the page shows after the caret.
    private struct PresentedProse {
        let serial: Int
        let suggestion: EditorFlowProseSuggestion
    }

    /// A patch sent to the page, until the page's edit for it comes back.
    private struct PendingApply {
        enum Kind {
            case repair(EditorFlowSuggestion)
            case prose(remainder: String, wasRendered: Bool)
        }

        let serial: Int
        let baseRevision: Int
        let range: NSRange
        let removed: String
        let inserted: String
        let selection: NSRange
        let label: String
        let isAutomatic: Bool
        let kind: Kind
        /// Protected ranges once the patch is in, for a completion's remainder.
        let rebasedProtectedRanges: [NSRange]?
    }

    /// A correction just applied, which Delete right after it takes back while the page shows its
    /// ⌫ undo hint.
    private struct Settlement {
        let serial: Int
        let revision: Int
        let selection: NSRange
        let actionName: String
        let suggestion: EditorFlowSuggestion
    }

    weak var host: MarkdownPreviewFlowHost?
    let dependencies: MarkdownPreviewFlowDependencies
    private let mode = FlowSourceMode.markdown
    private(set) var documentID: String?
    private(set) var options = EditorTextCheckingOptions.defaultValue
    private var text = ""
    private var textLength = 0
    private(set) var revision = 0
    private var selection: NSRange?
    private var pageFocused = false
    /// The caret is in a table cell. Source checks the words in cells (only a table's pipes are
    /// protected), but a sentence there starts in another cell, so Preview could never draw its
    /// review: it checks, fixes and completes nothing in a cell.
    private var caretInTableCell = false
    private var isPageReady = false
    private var isTornDown = false
    private let spellDocumentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var observers: [NSObjectProtocol] = []

    private var serial = 0
    private var gate = SentenceRepairGate.blocked
    private var flowRequestToken = 0
    private var flowCheckTask: Task<Void, Never>?
    private var flowSentenceRepairTask: Task<Void, Never>?
    private var pendingProtectedRangesRetry: PendingProtectedRangesRetry?
    private var protectedRangesSnapshot: ProtectedRangesSnapshot?
    private var protectedRangesTask: Task<Void, Never>?
    private var protectedRangesGeneration = 0
    private var protectedRangesDelayNanoseconds: UInt64 = 0
    private var flowProseCompletionTask: Task<Void, Never>?
    private var flowProseRequestToken = 0
    private var pendingProseCompletionRetry: PendingProseCompletionRetry?
    private var pendingProseRemainder: PendingProseRemainder?
    private var flowProseFailureCooldownUntil: Date?
    private var sentenceRepairFailureCooldown: SentenceRepairFailureCooldown?
    private var suppressedFlowSuggestion: EditorFlowSuggestionSuppression?
    private var presentedRepair: PresentedRepair?
    private var presentedProse: PresentedProse?
    private var pendingApply: PendingApply?
    private var settlement: Settlement?

    init(dependencies: MarkdownPreviewFlowDependencies) {
        self.dependencies = dependencies
        protectedRangesDelayNanoseconds = dependencies.protectedRangesDelayNanoseconds
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.host?.flowFocusView?.window else { return }
                self.cancelFlowForFocusLoss()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelFlowForFocusLoss()
            }
        })
    }

    /// Ends every check, model call and observer. The owner calls it when the page goes away.
    func tearDown() {
        guard !isTornDown else { return }
        cancelFlowSuggestion(notifyPage: false)
        protectedRangesTask?.cancel()
        protectedRangesTask = nil
        protectedRangesSnapshot = nil
        pendingApply = nil
        settlement = nil
        suppressedFlowSuggestion = nil
        isTornDown = true
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        NSSpellChecker.shared.closeSpellDocument(withTag: spellDocumentTag)
        host = nil
    }

    // MARK: - What the page and the settings report

    /// A page for `documentID` is about to be shown; nothing from another document carries over.
    func prepare(documentID: String) {
        guard self.documentID != documentID else { return }
        resetPageState()
        self.documentID = documentID
        suppressedFlowSuggestion = nil
        flowProseFailureCooldownUntil = nil
        sentenceRepairFailureCooldown = nil
    }

    func configure(options: EditorTextCheckingOptions) {
        guard self.options != options else { return }
        self.options = options
        suppressedFlowSuggestion = nil
        flowProseFailureCooldownUntil = nil
        sentenceRepairFailureCooldown = nil
        gate = .blocked
        cancelFlowSuggestion()
        clearSettlement()
        sendConfiguration()
        scheduleProtectedRangesRefresh(delayNanoseconds: 0)
    }

    /// The page is about to be replaced (a reload, or a reset after a mismatch): nothing shown so
    /// far applies to what comes next.
    func pageWillRender() {
        resetPageState()
    }

    /// The page shows `text` as its document, at `version` (0 for a fresh render).
    func pageDidRender(text: String, version: Int = 0) {
        resetPageState()
        adopt(text: text, version: version)
        isPageReady = true
        sendConfiguration()
        scheduleProtectedRangesRefresh(delayNanoseconds: 0)
    }

    /// The page replaced its document with the store's text after the two disagreed.
    func pageDidReset(text: String, version: Int) {
        pageDidRender(text: text, version: version)
    }

    func pageDidChangeFocus(_ focused: Bool) {
        guard pageFocused != focused else { return }
        pageFocused = focused
        if !focused {
            cancelFlowForFocusLoss()
        }
    }

    func pageDidChangeSelection(
        _ newSelection: MarkdownVisualEditorSelection,
        version: Int?,
        focused: Bool?,
        inTableCell: Bool? = nil
    ) {
        if let focused, focused != pageFocused {
            pageDidChangeFocus(focused)
        }
        guard version == nil || version == revision else { return }
        if let inTableCell {
            adoptCaretContext(inTableCell: inTableCell)
        }
        let range = newSelection.range
        guard range != selection else { return }
        selection = range
        guard isActive else { return }
        // As a caret move in Source: what was shown belonged to the old caret.
        settlement = nil
        cancelFlowSuggestion()
        refreshSuppressedFlowSuggestion()
        scheduleFlowCheck()
    }

    /// One patch the page applied, and the text it leaves: every edit, the page's own and the ones
    /// the app asked for (undo, redo, a change on disk, a fix).
    func pageDidChange(
        _ change: MarkdownVisualEditorChange,
        text newText: String,
        version: Int,
        inTableCell: Bool? = nil
    ) {
        let previousRevision = revision
        let previousLength = textLength
        let previousSelection = selection
        let previousProtectedRanges = protectedRangesSnapshot.flatMap {
            $0.revision == previousRevision ? $0.ranges : nil
        }
        adopt(text: newText, version: version)
        if let after = change.selectionAfter {
            selection = after.range
        }
        if let inTableCell {
            adoptCaretContext(inTableCell: inTableCell)
        }
        guard isActive else { return }

        if change.kind == .external {
            externalTextDidChange()
            return
        }
        if let pending = pendingApply {
            pendingApply = nil
            if change.kind == .flow,
               pending.baseRevision == previousRevision,
               change.range == pending.range,
               change.removed == pending.removed,
               change.inserted == pending.inserted {
                didApply(pending)
                return
            }
        }
        if let remainder = consumedProseRemainder(
            for: change,
            previousRevision: previousRevision,
            previousLength: previousLength
        ) {
            // Typing what the completion shows keeps the rest of it, as in Source.
            cancelFlowSuggestion(notifyPage: false)
            gate = .clear
            settlement = nil
            scheduleProtectedRangesRefresh()
            rebaseProtectedRanges(
                previousProtectedRanges,
                insertingAt: change.range.location,
                length: (change.inserted as NSString).length
            )
            presentedProse = remainder
            return
        }
        if let kept = repairKeptByTrailingSpace(
            for: change,
            previousRevision: previousRevision,
            previousSelection: previousSelection,
            previousProtectedRanges: previousProtectedRanges
        ) {
            // A space right after the reviewed sentence keeps the review, as in Source.
            flowRequestToken &+= 1
            flowCheckTask?.cancel()
            flowCheckTask = nil
            flowSentenceRepairTask?.cancel()
            flowSentenceRepairTask = nil
            pendingProtectedRangesRetry = nil
            _ = cancelProseCompletion()
            settlement = nil
            scheduleProtectedRangesRefresh()
            rebaseProtectedRanges(previousProtectedRanges, insertingAt: change.range.location, length: 1)
            presentedRepair = kept
            gate = .blocked
            return
        }

        settlement = nil
        let requestsAutocompleteAfterClear = change.kind == .typing
            && EditorFlowRepairPolicy.isFlowAutocompleteTrigger(change.inserted)
        gate = .blocked
        cancelFlowSuggestion()
        refreshSuppressedFlowSuggestion()
        scheduleProtectedRangesRefresh()
        if let end = completedSentenceEnd(for: change, previousLength: previousLength) {
            scheduleCompletedSentenceFlowCheck(endingAt: end)
        } else {
            scheduleFlowCheck(requestsAutocompleteAfterClear: requestsAutocompleteAfterClear)
        }
    }

    /// The page could not apply a patch the app sent (its text moved on first).
    func pageDidRefuseApply() {
        guard let pending = pendingApply else { return }
        pendingApply = nil
        if !pending.isAutomatic {
            NSSound.beep()
        }
        gate = .blocked
        cancelFlowSuggestion(notifyPage: false)
        // The review or completion it would have replaced may still be on the page.
        host?.sendFlow(["type": "clear"])
    }

    /// A `flow` message from the page: a key that acts on what it shows, or a presentation it
    /// dropped or could not draw.
    func handlePageMessage(_ body: [String: Any]) {
        guard isActive, let action = body["action"] as? String else { return }
        let messageSerial = WebViewBridge.integer(body["serial"]) ?? -1
        switch action {
        case "accept":
            if body["kind"] as? String == "completion" {
                acceptPresentedProse(
                    serial: messageSerial,
                    text: body["text"] as? String,
                    nextWordOnly: WebViewBridge.boolean(body["nextWordOnly"]) ?? true
                )
            } else {
                acceptPresentedRepair(
                    serial: messageSerial,
                    variant: WebViewBridge.integer(body["variant"]) ?? 0
                )
            }
        case "dismiss":
            guard presentedRepair?.serial == messageSerial || presentedProse?.serial == messageSerial else {
                return
            }
            dismissFlowSuggestion()
        case "cancel":
            switch body["scope"] as? String {
            case "repair":
                guard presentedRepair?.serial == messageSerial else { return }
                gate = .blocked
                cancelFlowSuggestion(notifyPage: false)
            case "completion":
                guard presentedProse?.serial == messageSerial else { return }
                _ = cancelProseCompletion(notifyPage: false)
            default:
                cancelFlowForFocusLoss(notifyPage: false)
            }
        case "unrendered":
            if presentedRepair?.serial == messageSerial {
                // As a repair whose sentence is out of view in Source.
                presentedRepair = nil
                finishSentenceRepairUnresolved()
            } else if presentedProse?.serial == messageSerial {
                _ = cancelProseCompletion(notifyPage: false)
            }
        case "declined":
            guard let pending = pendingApply, pending.serial == messageSerial else { return }
            pendingApply = nil
            if pending.isAutomatic {
                // As a fix whose sentence is out of view in Source: left for the user.
                finishSentenceRepairUnresolved()
            } else {
                // The text or caret moved before the patch arrived.
                NSSound.beep()
                gate = .blocked
                cancelFlowSuggestion(notifyPage: false)
                host?.sendFlow(["type": "clear"])
            }
        case "settled":
            guard let current = settlement, current.serial == messageSerial else { return }
            if WebViewBridge.boolean(body["revertible"]) == true {
                announce(current.suggestion.settlementAnnouncement, priority: .medium)
            } else {
                // No ⌫ undo hint where the caret is (an empty line), so ⌫ keeps deleting.
                settlement = nil
                announce(current.suggestion.settlementDescription, priority: .medium)
            }
        case "revert":
            revertSettlement(serial: messageSerial)
        default:
            break
        }
    }

    // MARK: - Commands

    var canCheckDocumentNow: Bool {
        isActive && hasFocus && assistsAtCaret && (options.checksSpelling || options.checksGrammar)
            && selection.map { NSMaxRange($0) > 0 } == true
    }

    /// Edit › Check Document Now (⌘;): checks the sentence before the caret at once, as though it
    /// were finished, and shows what it finds the way typing would.
    @discardableResult
    func checkDocumentNow() -> Bool {
        guard canCheckDocumentNow, let selection else { return false }
        clearSettlement()
        cancelFlowSuggestion()
        scheduleFlowCheck(completedSentenceEndingAt: NSMaxRange(selection), immediate: true)
        return true
    }

    var canShowWritingTools: Bool {
        isActive && hasFocus && dependencies.writingToolsAvailability()
    }

    // MARK: - State

    private var isActive: Bool {
        !isTornDown && isPageReady && documentID != nil && host != nil
    }

    private var hasFocus: Bool {
        guard pageFocused, let view = host?.flowFocusView else { return false }
        return dependencies.windowFocusValidator(view)
    }

    /// Whether writing assistance runs where the caret is: not in a table cell.
    private var assistsAtCaret: Bool {
        !caretInTableCell
    }

    /// Where the page says the caret is. Moving into a table cell ends what was running or shown.
    private func adoptCaretContext(inTableCell: Bool) {
        let assisted = assistsAtCaret
        caretInTableCell = inTableCell
        if assisted, !assistsAtCaret, isActive {
            gate = .blocked
            cancelFlowSuggestion()
        }
    }

    private var currentProtectedRanges: [NSRange]? {
        guard let snapshot = protectedRangesSnapshot, snapshot.revision == revision else { return nil }
        return snapshot.ranges
    }

    private var onDeviceProseCompletionIsAvailable: Bool {
        options.inlinePredictions
            && options.onDeviceProseCompletions
            && dependencies.proseCompletionService.isAvailable(for: .current)
    }

    private var isProseCompletionCoolingDown: Bool {
        guard let cooldownUntil = flowProseFailureCooldownUntil else { return false }
        guard cooldownUntil <= Date() else { return true }
        flowProseFailureCooldownUntil = nil
        return false
    }

    private func adopt(text newText: String, version: Int) {
        text = newText
        textLength = (newText as NSString).length
        revision = version
    }

    private func resetPageState() {
        cancelFlowSuggestion(notifyPage: false)
        protectedRangesGeneration &+= 1
        protectedRangesSnapshot = nil
        pendingApply = nil
        settlement = nil
        gate = .blocked
        isPageReady = false
        selection = nil
        caretInTableCell = false
    }

    private func sendConfiguration() {
        host?.sendFlow(["type": "configure", "spellcheck": options.checksSpelling])
    }

    private func externalTextDidChange() {
        clearSettlement()
        gate = .blocked
        cancelFlowSuggestion()
        refreshSuppressedFlowSuggestion()
        scheduleProtectedRangesRefresh()
    }

    private func clearSettlement() {
        guard settlement != nil else { return }
        settlement = nil
        host?.sendFlow(["type": "clear", "scope": "settle"])
    }

    func cancelFlowForFocusLoss(notifyPage: Bool = true) {
        gate = .blocked
        cancelFlowSuggestion(notifyPage: notifyPage)
    }

    private func cancelFlowSuggestion(notifyPage: Bool = true) {
        let hadRepair = presentedRepair != nil
        let hadProse = presentedProse != nil
        _ = cancelProseCompletion(notifyPage: false)
        flowRequestToken &+= 1
        flowCheckTask?.cancel()
        flowCheckTask = nil
        flowSentenceRepairTask?.cancel()
        flowSentenceRepairTask = nil
        pendingProtectedRangesRetry = nil
        presentedRepair = nil
        if notifyPage, hadRepair || hadProse {
            host?.sendFlow(["type": "clear"])
        }
    }

    @discardableResult
    private func cancelProseCompletion(notifyPage: Bool = true) -> Bool {
        let hadCompletion = flowProseCompletionTask != nil
            || presentedProse != nil
            || pendingProseCompletionRetry != nil
            || pendingProseRemainder != nil
        let hadPresentation = presentedProse != nil
        flowProseRequestToken &+= 1
        flowProseCompletionTask?.cancel()
        flowProseCompletionTask = nil
        pendingProseCompletionRetry = nil
        pendingProseRemainder = nil
        presentedProse = nil
        if notifyPage, hadPresentation {
            host?.sendFlow(["type": "clear", "scope": "completion"])
        }
        return hadCompletion
    }

    private func dismissFlowSuggestion() {
        if let presentedRepair {
            suppressedFlowSuggestion = EditorFlowSuggestionSuppression(
                presentedRepair.suggestion,
                accepted: false
            )
            gate = .blocked
        } else if presentedProse != nil {
            // Esc dismisses the completion lane for this revision.
            gate = .blocked
        }
        cancelFlowSuggestion()
    }

    private func refreshSuppressedFlowSuggestion() {
        guard let suppression = suppressedFlowSuggestion else { return }
        guard suppression.documentID == documentID,
              suppression.targetStillExists(in: text)
        else {
            suppressedFlowSuggestion = nil
            return
        }
    }

    private func caretIsOutsideProtectedRanges(_ ranges: [NSRange]) -> Bool {
        guard let selection, selection.length == 0 else { return false }
        guard textLength > 0 else { return true }
        let caret = min(max(0, selection.location), textLength)
        let probe = caret < textLength
            ? NSRange(location: caret, length: 1)
            : NSRange(location: textLength - 1, length: 1)
        return !ranges.contains { NSIntersectionRange($0, probe).length > 0 }
    }

    // MARK: - Edits the page reports

    private func didApply(_ pending: PendingApply) {
        if case let .repair(accepted) = pending.kind {
            suppressedFlowSuggestion = EditorFlowSuggestionSuppression(accepted, accepted: true)
        }
        gate = .blocked
        cancelFlowSuggestion(notifyPage: false)
        refreshSuppressedFlowSuggestion()
        scheduleProtectedRangesRefresh()
        switch pending.kind {
        case let .repair(suggestion):
            // VoiceOver hears the fix once the page says whether ⌫ takes it back ("settled").
            settlement = Settlement(
                serial: pending.serial,
                revision: revision,
                selection: pending.selection,
                actionName: pending.label,
                suggestion: suggestion
            )
            scheduleFlowCheck()
        case let .prose(remainder, wasRendered):
            settlement = nil
            if let ranges = pending.rebasedProtectedRanges {
                protectedRangesSnapshot = ProtectedRangesSnapshot(revision: revision, ranges: ranges)
            }
            scheduleFlowCheck()
            guard !remainder.isEmpty, let documentID else { return }
            pendingProseRemainder = PendingProseRemainder(
                documentID: documentID,
                revision: revision,
                sourceUTF16Length: textLength,
                selectedRange: pending.selection,
                continuation: remainder,
                wasRendered: wasRendered
            )
            _ = presentPendingProseRemainderIfReady()
        }
    }

    /// The completion left to show after typing the start of it, or nil when the edit was not that.
    private func consumedProseRemainder(
        for change: MarkdownVisualEditorChange,
        previousRevision: Int,
        previousLength: Int
    ) -> PresentedProse? {
        guard let presented = presentedProse,
              change.kind == .typing,
              change.removed.isEmpty,
              !change.inserted.isEmpty,
              presented.suggestion.revision == previousRevision,
              presented.suggestion.sourceUTF16Length == previousLength,
              presented.suggestion.selectedRange.length == 0,
              change.range.location == presented.suggestion.selectedRange.location
        else { return nil }
        let continuation = presented.suggestion.continuation as NSString
        let insertedLength = (change.inserted as NSString).length
        guard insertedLength < continuation.length,
              continuation.substring(to: insertedLength) == change.inserted,
              continuation.rangeOfComposedCharacterSequence(at: insertedLength).location == insertedLength
        else { return nil }
        let caret = change.range.location + insertedLength
        guard selection == NSRange(location: caret, length: 0) else { return nil }
        return PresentedProse(
            serial: presented.serial,
            suggestion: EditorFlowProseSuggestion(
                documentID: presented.suggestion.documentID,
                revision: revision,
                sourceUTF16Length: textLength,
                selectedRange: NSRange(location: caret, length: 0),
                continuation: continuation.substring(from: insertedLength),
                continuesTypedText: true
            )
        )
    }

    /// The reviewed correction a space typed right after its sentence keeps, or nil.
    private func repairKeptByTrailingSpace(
        for change: MarkdownVisualEditorChange,
        previousRevision: Int,
        previousSelection: NSRange?,
        previousProtectedRanges: [NSRange]?
    ) -> PresentedRepair? {
        guard let presented = presentedRepair,
              change.kind == .typing,
              change.removed.isEmpty,
              change.inserted == " ",
              let previousSelection,
              presented.suggestion.revision == previousRevision,
              presented.suggestion.selectedRange == previousSelection,
              change.range.location == previousSelection.location,
              change.range.location == NSMaxRange(presented.suggestion.sentenceRange),
              let ranges = previousProtectedRanges,
              EditorFlowRepairPolicy.editRangeIsOutsideProtectedRanges(change.range, protectedRanges: ranges)
        else { return nil }
        let resultingSelection = NSRange(location: change.range.location + 1, length: 0)
        let source = text as NSString
        guard selection == resultingSelection,
              NSMaxRange(presented.suggestion.sentenceRange) < source.length,
              source.substring(with: presented.suggestion.sentenceRange) == presented.suggestion.originalSentence
        else { return nil }
        return PresentedRepair(
            serial: presented.serial,
            suggestion: presented.suggestion.rebased(revision: revision, selectedRange: resultingSelection),
            variants: presented.variants.map {
                $0.rebased(revision: revision, selectedRange: resultingSelection)
            }
        )
    }

    /// Where a sentence ended when Return started a new line after it, as Source checks the
    /// sentence a line break completes.
    private func completedSentenceEnd(
        for change: MarkdownVisualEditorChange,
        previousLength: Int
    ) -> Int? {
        guard change.kind == .enter,
              let before = change.selectionBefore,
              before.anchor == before.head,
              let after = change.selectionAfter
        else { return nil }
        let end = before.head
        let source = text as NSString
        guard end > 0,
              source.length > previousLength,
              end < source.length,
              source.substring(with: NSRange(location: end, length: 1)).rangeOfCharacter(from: .newlines) != nil,
              after.head > end
        else { return nil }
        return end
    }

    /// Moves the protected ranges past an insertion the page just made, so what stays on screen can
    /// be taken before the next scan, as Source rebases its ranges after its own edits.
    private func rebaseProtectedRanges(_ ranges: [NSRange]?, insertingAt location: Int, length: Int) {
        guard let ranges else { return }
        protectedRangesSnapshot = ProtectedRangesSnapshot(
            revision: revision,
            ranges: ranges.map { range in
                guard range.location >= location else { return range }
                return NSRange(location: range.location + length, length: range.length)
            }
        )
    }

    // MARK: - Protected ranges

    private func scheduleProtectedRangesRefresh(delayNanoseconds: UInt64? = nil) {
        protectedRangesGeneration &+= 1
        protectedRangesDelayNanoseconds = delayNanoseconds ?? dependencies.protectedRangesDelayNanoseconds
        protectedRangesSnapshot = nil
        guard isActive, protectedRangesTask == nil else { return }

        let provider = dependencies.protectedRangeProvider
        let mode = self.mode
        protectedRangesTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else {
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
                guard self.isActive else {
                    self.protectedRangesTask = nil
                    return
                }
                let text = self.text
                let capturedRevision = self.revision
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
                      capturedRevision == self.revision
                else { continue }
                self.protectedRangesSnapshot = ProtectedRangesSnapshot(
                    revision: capturedRevision,
                    ranges: ranges
                )
                self.protectedRangesTask = nil
                if let retry = self.pendingProtectedRangesRetry,
                   retry.snapshot.revision == capturedRevision,
                   self.isCurrentFlowSnapshot(retry.snapshot, token: retry.token) {
                    self.pendingProtectedRangesRetry = nil
                    self.requestFlowCorrection(for: retry.snapshot, token: retry.token)
                } else if self.gate.allowsAutocomplete {
                    self.resumePendingProseCompletionIfReady()
                }
                return
            }
            self?.protectedRangesTask = nil
        }
    }

    private func protectedRanges(for snapshot: EditorFlowCheckSnapshot) -> [NSRange]? {
        guard let protectedSnapshot = protectedRangesSnapshot,
              protectedSnapshot.revision == snapshot.revision,
              snapshot.sourceMode == mode
        else { return nil }
        return protectedSnapshot.ranges
    }
}

// MARK: - Sentence repair: Source's pipeline, over the page's source

extension MarkdownPreviewFlowCoordinator {
    private func isCurrentFlowSnapshot(_ snapshot: EditorFlowCheckSnapshot, token: Int) -> Bool {
        guard token == flowRequestToken,
              isActive,
              mode == snapshot.sourceMode,
              options == snapshot.options,
              documentID == snapshot.documentID,
              revision == snapshot.revision,
              let selection,
              selection == snapshot.selectedRange,
              snapshot.caretUTF16Offset == NSMaxRange(snapshot.selectedRange),
              snapshot.checkedRange.location >= 0,
              NSMaxRange(snapshot.checkedRange) <= textLength,
              (text as NSString).substring(with: snapshot.checkedRange) == snapshot.checkedText,
              hasFocus,
              assistsAtCaret
        else { return false }
        return true
    }

    private func scheduleFlowCheck(
        completedSentenceEndingAt endOffset: Int? = nil,
        requestsAutocompleteAfterClear: Bool = false,
        immediate: Bool = false
    ) {
        guard isActive else { return }
        guard assistsAtCaret else {
            gate = .blocked
            _ = cancelProseCompletion()
            return
        }
        guard options.checksSpelling || options.checksGrammar else {
            finishSentenceRepairClear(requestsAutocomplete: requestsAutocompleteAfterClear)
            return
        }
        guard hasFocus,
              let documentID,
              let selection,
              let plan = EditorFlowCheckPlanner.plan(
                in: text,
                selectedRange: endOffset.map { NSRange(location: $0, length: 0) } ?? selection
              )
        else {
            gate = .blocked
            return
        }

        let offersSentenceBatch = plan.isBatchSafe
            && (endOffset != nil || plan.offersSentenceBatch)
        gate = .blocked
        _ = cancelProseCompletion()

        let token = flowRequestToken
        let checkedText = (text as NSString).substring(with: plan.range)
        let snapshot = EditorFlowCheckSnapshot(
            documentID: documentID,
            revision: revision,
            checkedText: checkedText,
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
        let delayNanoseconds = immediate ? 0 : dependencies.checkDelayNanoseconds ?? plan.delayNanoseconds
        flowCheckTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled,
                  self.isCurrentFlowSnapshot(snapshot, token: token)
            else { return }
            self.requestFlowCorrection(for: snapshot, token: token)
        }
    }

    /// Return finished a sentence: check it as complete, as Source does after a line break.
    private func scheduleCompletedSentenceFlowCheck(endingAt endOffset: Int) {
        guard endOffset > 0, endOffset <= textLength else { return }
        flowRequestToken &+= 1
        flowCheckTask?.cancel()
        flowCheckTask = nil
        flowSentenceRepairTask?.cancel()
        flowSentenceRepairTask = nil
        pendingProtectedRangesRetry = nil
        scheduleFlowCheck(completedSentenceEndingAt: endOffset)
    }

    private func requestFlowCorrection(for snapshot: EditorFlowCheckSnapshot, token: Int) {
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        let documentTag = spellDocumentTag
        armSentenceRepairCheckingDeadline(snapshot: snapshot, token: token)
        dependencies.checkingClient.request(
            snapshot.checkedText,
            NSRange(location: 0, length: (snapshot.checkedText as NSString).length),
            EditorFlowCheckingTypes.value(for: snapshot.options),
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                self?.receiveFlowResults(
                    results,
                    orthography: orthography,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag
                )
            }
        }
    }

    private func receiveFlowResults(
        _ results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int
    ) {
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        guard let ranges = protectedRanges(for: snapshot) else {
            // The scan for this text is still running; it retries with the same token.
            pendingProtectedRangesRetry = PendingProtectedRangesRetry(snapshot: snapshot, token: token)
            return
        }
        flowCheckTask?.cancel()
        flowCheckTask = nil
        pendingProtectedRangesRetry = nil
        let checkedLength = (snapshot.checkedText as NSString).length
        let allDetectedIssues = EditorFlowCorrectionResolver.detectedIssues(
            in: snapshot.checkedText,
            caretUTF16Offset: checkedLength,
            results: results,
            options: snapshot.options
        )
        let (detectedIssues, hasPartiallyProtectedIssue) = EditorFlowRepairPolicy.unprotectedIssues(
            allDetectedIssues,
            checkedRange: snapshot.checkedRange,
            protectedRanges: ranges
        )
        guard !hasPartiallyProtectedIssue else {
            finishSentenceRepairUnresolved()
            return
        }
        let repairLocale = EditorFlowRepairPolicy.repairLocale(from: orthography)
        guard !detectedIssues.isEmpty else {
            if !allDetectedIssues.isEmpty {
                finishSentenceRepairUnresolved()
                return
            }
            guard snapshot.coversWholeCurrentSentence else {
                finishSentenceRepairBlocked()
                return
            }
            if snapshot.offersSentenceBatch, options.onDeviceProseCompletions {
                attemptAISentenceRepair(
                    appleFoundIssues: false,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag,
                    locale: repairLocale
                )
            } else {
                finishSentenceRepairClear(requestsAutocomplete: snapshot.requestsAutocompleteAfterClear)
            }
            return
        }
        guard snapshot.offersSentenceBatch else {
            finishSentenceRepairUnresolved()
            return
        }
        let localCandidates = EditorFlowCorrectionResolver.concreteCorrections(
            in: snapshot.checkedText,
            caretUTF16Offset: checkedLength,
            results: results
        )
        let enabledLocalCandidates = localCandidates.filter { candidate in
            switch candidate.kind {
            case .spelling: return snapshot.options.checksSpelling
            case .grammar: return snapshot.options.checksGrammar
            }
        }
        let grammarAlternatives = EditorFlowCorrectionResolver.ambiguousGrammarCorrections(
            in: snapshot.checkedText,
            caretUTF16Offset: checkedLength,
            results: results
        )
        let spellingLookups = snapshot.options.checksSpelling
            ? EditorFlowCorrectionResolver.spellingCandidateLookups(
                in: snapshot.checkedText,
                caretUTF16Offset: checkedLength,
                results: results
            )
            : []
        guard let spellingLookups else {
            finishAppleCandidateResolution(
                concreteCandidates: [],
                alternativeCandidates: [],
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                protectedRanges: ranges
            )
            return
        }
        guard !spellingLookups.isEmpty else {
            finishAppleCandidateResolution(
                concreteCandidates: enabledLocalCandidates,
                alternativeCandidates: grammarAlternatives,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                protectedRanges: ranges
            )
            return
        }
        armSentenceRepairCheckingDeadline(snapshot: snapshot, token: token)
        requestSpellingCandidates(
            spellingLookups,
            nextIndex: 0,
            spellingAlternatives: [],
            grammarAlternatives: grammarAlternatives,
            concreteCandidates: enabledLocalCandidates,
            detectedIssues: detectedIssues,
            snapshot: snapshot,
            token: token,
            documentTag: documentTag,
            repairLocale: repairLocale,
            protectedRanges: ranges
        )
    }

    private func requestSpellingCandidates(
        _ lookups: [EditorFlowSpellingCandidateLookup],
        nextIndex: Int,
        spellingAlternatives: [EditorFlowAlternativeCandidate],
        grammarAlternatives: [EditorFlowAlternativeCandidate],
        concreteCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        repairLocale: Locale,
        protectedRanges: [NSRange]
    ) {
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        guard nextIndex < lookups.count else {
            finishAppleCandidateResolution(
                concreteCandidates: concreteCandidates,
                alternativeCandidates: spellingAlternatives + grammarAlternatives,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale,
                protectedRanges: protectedRanges
            )
            return
        }
        let lookup = lookups[nextIndex]
        let candidateTypes = NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
        dependencies.checkingClient.requestCandidates(
            snapshot.checkedText,
            lookup.range,
            candidateTypes,
            documentTag
        ) { [weak self] candidateResults in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentFlowSnapshot(snapshot, token: token) else { return }
                let replacements = EditorFlowCorrectionResolver.spellingReviewReplacements(
                    in: snapshot.checkedText,
                    lookup: lookup,
                    candidateResults: candidateResults
                )
                let hasAdditionalReplacement = replacements.contains { $0 != lookup.primaryReplacement }
                var nextAlternatives = spellingAlternatives
                if (!replacements.isEmpty && lookup.primaryReplacement == nil) || hasAdditionalReplacement {
                    nextAlternatives.append(EditorFlowAlternativeCandidate(
                        range: lookup.range,
                        replacementTexts: replacements,
                        kind: .spelling
                    ))
                }
                self.requestSpellingCandidates(
                    lookups,
                    nextIndex: nextIndex + 1,
                    spellingAlternatives: nextAlternatives,
                    grammarAlternatives: grammarAlternatives,
                    concreteCandidates: concreteCandidates,
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
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        if alternativeCandidates.count == 1, let candidate = alternativeCandidates.first {
            let remainingConcreteCandidates = concreteCandidates.filter {
                $0.range != candidate.range || $0.kind != candidate.kind
            }
            if let candidate = EditorFlowRepairPolicy.alternativeCandidateForValidation(
                candidate,
                concreteCandidates: remainingConcreteCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                protectedRanges: protectedRanges,
                sourceUTF16Length: textLength
            ) {
                if flowCheckTask == nil {
                    armSentenceRepairCheckingDeadline(snapshot: snapshot, token: token)
                }
                validateAlternatives(
                    candidate,
                    nextIndex: 0,
                    cleanReplacements: [],
                    concreteCandidates: remainingConcreteCandidates,
                    detectedIssues: detectedIssues,
                    snapshot: snapshot,
                    token: token,
                    documentTag: documentTag,
                    repairLocale: repairLocale,
                    forcesReview: candidate.kind == .spelling
                )
                return
            }
        }
        flowCheckTask?.cancel()
        flowCheckTask = nil
        let candidatesToPresent = alternativeCandidates.isEmpty ? concreteCandidates : []
        if !presentFlowCandidates(
            candidatesToPresent,
            detectedIssues: detectedIssues,
            snapshot: snapshot,
            token: token
        ) {
            finishAppleCandidatesUnresolved(
                candidatesToPresent,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                repairLocale: repairLocale
            )
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
        if suppressedFlowSuggestion?.applies(to: candidates, snapshot: snapshot) == true {
            finishSentenceRepairUnresolved()
        } else {
            attemptAISentenceRepair(
                appleFoundIssues: true,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag,
                locale: repairLocale
            )
        }
    }

    @discardableResult
    private func presentFlowCandidates(
        _ localCandidates: [EditorFlowCorrectionCandidate],
        detectedIssues: [EditorFlowDetectedIssue],
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        reviewAlternatives: EditorFlowReviewAlternatives? = nil,
        forcesReview: Bool = false
    ) -> Bool {
        guard isCurrentFlowSnapshot(snapshot, token: token),
              let ranges = protectedRanges(for: snapshot),
              let suggestion = EditorFlowRepairPolicy.deterministicSuggestion(
                candidates: localCandidates,
                detectedIssues: detectedIssues,
                snapshot: snapshot,
                protectedRanges: ranges,
                sourceUTF16Length: textLength,
                suppression: suppressedFlowSuggestion,
                reviewAlternatives: reviewAlternatives,
                forcesReview: forcesReview
              ),
              suggestion.matches(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                text: text,
                selectedRange: snapshot.selectedRange
              )
        else { return false }
        _ = cancelProseCompletion()
        gate = .blocked
        present(suggestion)
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
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
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
        // As in Source: ask for the complete checking set, then reject any issue the alternative
        // leaves in the sentence before it reaches the review.
        let validationTypes = NSTextCheckingResult.CheckingType.orthography.rawValue
            | NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
            | NSTextCheckingResult.CheckingType.grammar.rawValue
        dependencies.checkingClient.request(
            validation.text,
            NSRange(location: 0, length: (validation.text as NSString).length),
            validationTypes,
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentFlowSnapshot(snapshot, token: token) else { return }
                var nextCleanReplacements = cleanReplacements
                if orthography != nil,
                   EditorFlowRepairPolicy.checkingValidationIsClean(
                       results,
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
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        flowCheckTask?.cancel()
        flowCheckTask = nil
        let (resolvedCandidates, reviewAlternatives) = EditorFlowRepairPolicy.resolvedAlternativeCandidates(
            candidate,
            cleanReplacements: cleanReplacements,
            concreteCandidates: concreteCandidates,
            checkedRange: snapshot.checkedRange
        )
        if !presentFlowCandidates(
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

    private func armSentenceRepairCheckingDeadline(
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        recordsModelFailureCooldown: Bool = false
    ) {
        flowCheckTask?.cancel()
        let timeout = dependencies.checkingTimeoutNanoseconds
        flowCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentFlowSnapshot(snapshot, token: token)
            else { return }
            if recordsModelFailureCooldown {
                self.recordSentenceRepairFailureCooldown(for: snapshot)
            }
            self.flowRequestToken &+= 1
            self.flowCheckTask = nil
            self.flowSentenceRepairTask?.cancel()
            self.flowSentenceRepairTask = nil
            self.pendingProtectedRangesRetry = nil
            self.gate = .nativeFallback
            _ = self.cancelProseCompletion()
        }
    }

    private func finishSentenceRepairClear(requestsAutocomplete: Bool) {
        sentenceRepairFailureCooldown = nil
        gate = .clear
        if pendingProseRemainder != nil {
            if presentPendingProseRemainderIfReady() { return }
            pendingProseRemainder = nil
        }
        if requestsAutocomplete {
            scheduleProseCompletion()
        }
    }

    private func finishSentenceRepairUnresolved() {
        gate = .nativeFallback
        _ = cancelProseCompletion()
    }

    private func finishSentenceRepairBlocked() {
        gate = .blocked
        _ = cancelProseCompletion()
    }

    private func recordSentenceRepairFailureCooldown(for snapshot: EditorFlowCheckSnapshot) {
        sentenceRepairFailureCooldown = SentenceRepairFailureCooldown(
            sentence: snapshot.checkedText.trimmingCharacters(in: .whitespacesAndNewlines),
            until: Date().addingTimeInterval(30)
        )
    }

    private func isSentenceRepairCoolingDown(for snapshot: EditorFlowCheckSnapshot) -> Bool {
        guard let cooldown = sentenceRepairFailureCooldown else { return false }
        guard cooldown.until > Date() else {
            sentenceRepairFailureCooldown = nil
            return false
        }
        return cooldown.sentence == snapshot.checkedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - On-device sentence repair

extension MarkdownPreviewFlowCoordinator {
    private func attemptAISentenceRepair(
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int,
        locale: Locale
    ) {
        guard !isSentenceRepairCoolingDown(for: snapshot) else {
            finishAISentenceRepairWithoutSuggestion(appleFoundIssues: appleFoundIssues, snapshot: snapshot)
            return
        }
        guard snapshot.offersSentenceBatch,
              options.onDeviceProseCompletions,
              isCurrentFlowSnapshot(snapshot, token: token),
              protectedRanges(for: snapshot) != nil,
              let request = FlowSentenceRepairRequest(sentence: snapshot.checkedText, locale: locale),
              dependencies.sentenceRepairService.isAvailable(for: locale)
        else {
            finishAISentenceRepairWithoutSuggestion(appleFoundIssues: appleFoundIssues, snapshot: snapshot)
            return
        }
        gate = .blocked
        _ = cancelProseCompletion()
        flowSentenceRepairTask?.cancel()
        let service = dependencies.sentenceRepairService
        flowSentenceRepairTask = Task { @MainActor [weak self] in
            let outcome = await service.repair(for: request)
            guard !Task.isCancelled else { return }
            self?.receiveAISentenceRepair(
                outcome,
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot,
                token: token,
                documentTag: documentTag
            )
        }
    }

    private func receiveAISentenceRepair(
        _ outcome: FlowModelOutcome,
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        token: Int,
        documentTag: Int
    ) {
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        flowSentenceRepairTask = nil
        let candidateSentence: String
        switch outcome {
        case let .success(value):
            candidateSentence = value
        case .unavailable:
            finishAISentenceRepairWithoutSuggestion(appleFoundIssues: appleFoundIssues, snapshot: snapshot)
            return
        case .failed, .timedOut, .validationRejected:
            finishAISentenceRepairWithoutSuggestion(
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot,
                recordsCooldown: true
            )
            return
        }
        guard candidateSentence != snapshot.checkedText else {
            sentenceRepairFailureCooldown = nil
            if appleFoundIssues {
                finishSentenceRepairUnresolved()
            } else {
                finishSentenceRepairClear(requestsAutocomplete: snapshot.requestsAutocompleteAfterClear)
            }
            return
        }
        guard EditorFlowRepairPolicy.protectedFragments(in: candidateSentence, mode: snapshot.sourceMode)
                == EditorFlowRepairPolicy.protectedFragments(in: snapshot.checkedText, mode: snapshot.sourceMode),
              let validatedEdits = EditorFlowAIRepairValidator.edits(
                originalSentence: snapshot.checkedText,
                candidateSentence: candidateSentence
              )
        else {
            finishAISentenceRepairWithoutSuggestion(
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot,
                recordsCooldown: true
            )
            return
        }
        // The model's sentence must check clean with Apple's checker before anyone sees it.
        let unifiedTypes = NSTextCheckingResult.CheckingType.orthography.rawValue
            | NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
            | NSTextCheckingResult.CheckingType.grammar.rawValue
        armSentenceRepairCheckingDeadline(snapshot: snapshot, token: token, recordsModelFailureCooldown: true)
        dependencies.checkingClient.request(
            candidateSentence,
            NSRange(location: 0, length: (candidateSentence as NSString).length),
            unifiedTypes,
            documentTag
        ) { [weak self] results, orthography in
            DispatchQueue.main.async { [weak self] in
                self?.finishAISentenceRepairValidation(
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

    private func finishAISentenceRepairValidation(
        candidateSentence: String,
        validatedEdits: [EditorFlowCorrectionEdit],
        appleFoundIssues: Bool,
        results: [NSTextCheckingResult],
        orthography: NSOrthography?,
        snapshot: EditorFlowCheckSnapshot,
        token: Int
    ) {
        guard isCurrentFlowSnapshot(snapshot, token: token) else { return }
        flowCheckTask?.cancel()
        flowCheckTask = nil
        guard orthography != nil,
              EditorFlowRepairPolicy.allCheckingResultsAreClean(results),
              let protectedRanges = protectedRanges(for: snapshot)
        else {
            finishAISentenceRepairWithoutSuggestion(
                appleFoundIssues: appleFoundIssues,
                snapshot: snapshot,
                recordsCooldown: true
            )
            return
        }
        let absoluteEdits = validatedEdits.map { edit in
            EditorFlowCorrectionEdit(
                range: NSRange(
                    location: snapshot.checkedRange.location + edit.range.location,
                    length: edit.range.length
                ),
                originalText: edit.originalText,
                replacementText: edit.replacementText,
                kind: edit.kind
            )
        }
        if let suppression = suppressedFlowSuggestion,
           suppression.edits.count == absoluteEdits.count,
           absoluteEdits.allSatisfy(suppression.suppresses) {
            finishSentenceRepairUnresolved()
            return
        }
        guard absoluteEdits.allSatisfy({
            EditorFlowRepairPolicy.editRangeIsOutsideProtectedRanges($0.range, protectedRanges: protectedRanges)
        }) else {
            recordSentenceRepairFailureCooldown(for: snapshot)
            finishSentenceRepairUnresolved()
            return
        }
        sentenceRepairFailureCooldown = nil
        gate = .blocked
        // The model's repairs always wait for review.
        present(EditorFlowSuggestion(
            documentID: snapshot.documentID,
            revision: snapshot.revision,
            selectedRange: snapshot.selectedRange,
            caretUTF16Offset: snapshot.caretUTF16Offset,
            sentenceRange: snapshot.checkedRange,
            originalSentence: snapshot.checkedText,
            correctedSentence: candidateSentence,
            source: .ai,
            acceptance: .reviewOnly,
            edits: absoluteEdits
        ))
    }

    private func finishAISentenceRepairWithoutSuggestion(
        appleFoundIssues: Bool,
        snapshot: EditorFlowCheckSnapshot,
        recordsCooldown: Bool = false
    ) {
        if recordsCooldown, appleFoundIssues {
            recordSentenceRepairFailureCooldown(for: snapshot)
        }
        if appleFoundIssues {
            finishSentenceRepairUnresolved()
        } else {
            finishSentenceRepairClear(requestsAutocomplete: snapshot.requestsAutocompleteAfterClear)
        }
    }
}

// MARK: - On-device completion

extension MarkdownPreviewFlowCoordinator {
    private func scheduleProseCompletion(delayNanoseconds: UInt64? = nil, reusingToken: Int? = nil) {
        guard isActive,
              onDeviceProseCompletionIsAvailable,
              !isProseCompletionCoolingDown,
              gate.allowsAutocomplete,
              presentedRepair == nil,
              pendingApply == nil,
              hasFocus,
              assistsAtCaret,
              let selection,
              EditorFlowProseContextPlanner.context(in: text, selectedRange: selection, protectedRanges: []) != nil
        else { return }

        let token: Int
        if let reusingToken {
            guard reusingToken == flowProseRequestToken else { return }
            token = reusingToken
        } else {
            flowProseRequestToken &+= 1
            token = flowProseRequestToken
        }
        let delay = delayNanoseconds ?? dependencies.proseCompletionDelayNanoseconds
        let offerDelay = Double(dependencies.proseOfferDelayNanoseconds) / 1_000_000_000
        flowProseCompletionTask?.cancel()
        pendingProseCompletionRetry = nil
        flowProseCompletionTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            if self.currentProtectedRanges == nil {
                self.deferProseCompletionUntilProtectedRanges(token: token)
                return
            }
            guard let (snapshot, request) = self.prepareProseCompletion(token: token) else {
                if token == self.flowProseRequestToken {
                    self.flowProseCompletionTask = nil
                }
                return
            }
            let service = self.dependencies.proseCompletionService
            let requestStartedAt = Date()
            let outcome = await service.completion(for: request)
            guard !Task.isCancelled else { return }
            // A completion never appears sooner than this after it was asked for, as in Source.
            let elapsed = Date().timeIntervalSince(requestStartedAt)
            if elapsed < offerDelay {
                do {
                    try await Task.sleep(nanoseconds: UInt64((offerDelay - elapsed) * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.receiveProseCompletion(outcome, snapshot: snapshot, token: token)
        }
    }

    private func deferProseCompletionUntilProtectedRanges(token: Int) {
        guard token == flowProseRequestToken else { return }
        pendingProseCompletionRetry = PendingProseCompletionRetry(
            token: token,
            expiresAt: Date().addingTimeInterval(1)
        )
        flowProseCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  token == self.flowProseRequestToken,
                  self.pendingProseCompletionRetry?.token == token
            else { return }
            self.pendingProseCompletionRetry = nil
            self.flowProseCompletionTask = nil
        }
    }

    private func resumePendingProseCompletionIfReady() {
        guard let retry = pendingProseCompletionRetry else { return }
        pendingProseCompletionRetry = nil
        guard retry.token == flowProseRequestToken else { return }
        guard retry.expiresAt >= Date() else {
            flowProseCompletionTask?.cancel()
            flowProseCompletionTask = nil
            return
        }
        scheduleProseCompletion(delayNanoseconds: 0, reusingToken: retry.token)
    }

    private func prepareProseCompletion(token: Int) -> (ProseCompletionSnapshot, FlowProseCompletionRequest)? {
        guard token == flowProseRequestToken,
              onDeviceProseCompletionIsAvailable,
              !isProseCompletionCoolingDown,
              gate.allowsAutocomplete,
              let documentID,
              hasFocus,
              assistsAtCaret,
              presentedRepair == nil,
              pendingApply == nil,
              let protectedRanges = currentProtectedRanges,
              let selection,
              let context = EditorFlowProseContextPlanner.context(
                in: text,
                selectedRange: selection,
                protectedRanges: protectedRanges
              ),
              let request = FlowProseCompletionRequest(context: context.text, locale: .current)
        else { return nil }
        return (
            ProseCompletionSnapshot(
                documentID: documentID,
                revision: revision,
                sourceUTF16Length: textLength,
                selectedRange: selection,
                context: context,
                options: options
            ),
            request
        )
    }

    private func receiveProseCompletion(
        _ outcome: FlowModelOutcome,
        snapshot: ProseCompletionSnapshot,
        token: Int
    ) {
        guard token == flowProseRequestToken else { return }
        flowProseCompletionTask = nil
        guard isCurrentProseCompletionSnapshot(snapshot) else { return }
        let continuation: String
        switch outcome {
        case let .success(value):
            continuation = value
        case .unavailable:
            return
        case .failed, .timedOut, .validationRejected:
            flowProseFailureCooldownUntil = Date().addingTimeInterval(30)
            return
        }
        guard !continuation.isEmpty,
              !continuation.containsNewline,
              EditorFlowRepairPolicy.insertionRemainsOutsideProtectedSyntax(
                in: text as NSString,
                insertionLocation: snapshot.selectedRange.location,
                replacement: continuation,
                mode: mode
              )
        else { return }
        flowProseFailureCooldownUntil = nil
        presentProse(
            EditorFlowProseSuggestion(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                sourceUTF16Length: snapshot.sourceUTF16Length,
                selectedRange: snapshot.selectedRange,
                continuation: continuation
            ),
            alreadySeen: false
        )
    }

    private func isCurrentProseCompletionSnapshot(_ snapshot: ProseCompletionSnapshot) -> Bool {
        guard isActive,
              gate.allowsAutocomplete,
              documentID == snapshot.documentID,
              revision == snapshot.revision,
              options == snapshot.options,
              textLength == snapshot.sourceUTF16Length,
              selection == snapshot.selectedRange,
              presentedRepair == nil,
              pendingApply == nil,
              hasFocus,
              assistsAtCaret,
              let protectedRanges = currentProtectedRanges,
              EditorFlowProseContextPlanner.context(
                in: text,
                selectedRange: snapshot.selectedRange,
                protectedRanges: protectedRanges
              ) == snapshot.context
        else { return false }
        return true
    }

    @discardableResult
    private func presentPendingProseRemainderIfReady() -> Bool {
        guard gate.allowsAutocomplete,
              let pending = pendingProseRemainder,
              pendingApply == nil,
              presentedRepair == nil,
              documentID == pending.documentID,
              revision == pending.revision,
              textLength == pending.sourceUTF16Length,
              selection == pending.selectedRange,
              hasFocus,
              assistsAtCaret,
              let protectedRanges = currentProtectedRanges,
              caretIsOutsideProtectedRanges(protectedRanges),
              EditorFlowRepairPolicy.insertionRemainsOutsideProtectedSyntax(
                in: text as NSString,
                insertionLocation: pending.selectedRange.location,
                replacement: pending.continuation,
                mode: mode
              )
        else { return false }
        pendingProseRemainder = nil
        presentProse(
            EditorFlowProseSuggestion(
                documentID: pending.documentID,
                revision: pending.revision,
                sourceUTF16Length: pending.sourceUTF16Length,
                selectedRange: pending.selectedRange,
                continuation: pending.continuation
            ),
            alreadySeen: pending.wasRendered
        )
        return true
    }
}

// MARK: - What the page shows, and taking it

extension MarkdownPreviewFlowCoordinator {
    private func nextSerial() -> Int {
        serial &+= 1
        return serial
    }

    /// VoiceOver hears what the page shows, as Source announces it.
    private func announce(_ announcement: String, priority: NSAccessibilityPriorityLevel) {
        guard let view = host?.flowFocusView else { return }
        NSAccessibility.post(
            element: view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: priority.rawValue,
            ]
        )
    }

    private func present(_ suggestion: EditorFlowSuggestion) {
        switch suggestion.acceptance {
        case .direct:
            // A certain fix applies at once, as in Source; Delete right after takes it back.
            if !acceptFlowSuggestion(suggestion, isAutomatic: true) {
                gate = .nativeFallback
            }
        case .reviewOnly:
            let variants = reviewVariants(of: suggestion)
            let presented = PresentedRepair(serial: nextSerial(), suggestion: suggestion, variants: variants)
            presentedRepair = presented
            announce(suggestion.accessibilityAnnouncementText, priority: .medium)
            host?.sendFlow([
                "type": "review",
                "serial": presented.serial,
                "v": revision,
                "caret": suggestion.caretUTF16Offset,
                "sentence": [suggestion.sentenceRange.location, NSMaxRange(suggestion.sentenceRange)],
                "index": variants.firstIndex(of: suggestion) ?? 0,
                "variants": variants.map { ["changes": Self.reviewChanges(of: $0)] }
            ])
        }
    }

    private func presentProse(_ suggestion: EditorFlowProseSuggestion, alreadySeen: Bool) {
        let presented = PresentedProse(serial: nextSerial(), suggestion: suggestion)
        presentedProse = presented
        announce(suggestion.accessibilityText, priority: .low)
        host?.sendFlow([
            "type": "ghost",
            "serial": presented.serial,
            "v": revision,
            "at": suggestion.selectedRange.location,
            "text": suggestion.continuation,
            "rendered": alreadySeen
        ])
    }

    /// The suggestion each of Apple's validated alternatives makes, in its order; the one shown
    /// first is among them.
    private func reviewVariants(of suggestion: EditorFlowSuggestion) -> [EditorFlowSuggestion] {
        guard let alternatives = suggestion.reviewAlternatives else { return [suggestion] }
        let variants = alternatives.replacementTexts.compactMap {
            suggestion.selectingReviewAlternative($0)
        }
        return variants.contains(suggestion) ? variants : [suggestion]
    }

    /// The page's instructions for showing a corrected sentence in place: for each change, the
    /// source it hides and the text it shows; a deletion marks the nearest word instead, from the
    /// side the removed text was on.
    private static func reviewChanges(of suggestion: EditorFlowSuggestion) -> [[String: Any]] {
        let sentenceStart = suggestion.sentenceRange.location
        let changes = suggestion.displayChanges
        let correctedWords = EditorFlowSuggestion.lexicalWordRanges(in: suggestion.correctedSentence)
        // Corrected-sentence offsets back to the original: unchanged text moves by every change
        // that ends before it.
        func originalOffset(forCorrected offset: Int) -> Int {
            changes.reduce(offset) { result, change in
                guard NSMaxRange(change.correctedRange) <= offset else { return result }
                return result - (change.correctedRange.length - change.originalRange.length)
            }
        }
        return changes.map { change in
            var entry: [String: Any] = [
                "from": sentenceStart + change.originalRange.location,
                "to": sentenceStart + NSMaxRange(change.originalRange),
                "insert": change.replacementText
            ]
            if change.replacementText.isEmpty,
               !change.originalText.isEmpty,
               let anchor = EditorFlowSuggestion.deletionAnchor(
                at: change.correctedRange.location,
                wordRanges: correctedWords
               ) {
                let start = sentenceStart + originalOffset(forCorrected: anchor.range.location)
                entry["mark"] = [start, start + anchor.range.length]
            }
            return entry
        }
    }

    private func acceptPresentedRepair(serial: Int, variant: Int) {
        guard let presented = presentedRepair,
              presented.serial == serial,
              presented.variants.indices.contains(variant)
        else {
            NSSound.beep()
            return
        }
        if !acceptFlowSuggestion(presented.variants[variant], isAutomatic: false) {
            NSSound.beep()
        }
    }

    private func acceptPresentedProse(serial: Int, text displayed: String?, nextWordOnly: Bool) {
        guard let presented = presentedProse,
              presented.serial == serial,
              displayed == nil || displayed == presented.suggestion.continuation
        else {
            NSSound.beep()
            cancelFlowSuggestion()
            return
        }
        if !acceptFlowProseSuggestion(presented.suggestion, nextWordOnly: nextWordOnly) {
            NSSound.beep()
        }
    }

    /// Sends a correction to the page as one source patch, after checking the text it changes is
    /// still exactly what was checked. `isAutomatic` is a certain fix applying itself; otherwise the
    /// user pressed Tab on the review.
    @discardableResult
    private func acceptFlowSuggestion(_ candidate: EditorFlowSuggestion, isAutomatic: Bool) -> Bool {
        let presented = isAutomatic ? candidate : presentedRepair?.suggestion
        guard pendingApply == nil,
              hasFocus,
              let presented,
              let accepted = presented.approvedReviewVariant(candidate),
              let protectedRanges = currentProtectedRanges,
              accepted.edits.allSatisfy({
                EditorFlowRepairPolicy.editRangeIsOutsideProtectedRanges($0.range, protectedRanges: protectedRanges)
              }),
              let selection,
              accepted.matches(documentID: documentID, revision: revision, text: text, selectedRange: selection),
              let firstEdit = accepted.edits.first,
              let lastEdit = accepted.edits.last
        else {
            gate = .blocked
            cancelFlowSuggestion()
            return false
        }

        let replacementRange = NSRange(
            location: firstEdit.range.location,
            length: NSMaxRange(lastEdit.range) - firstEdit.range.location
        )
        let original = (text as NSString).substring(with: replacementRange)
        let replacement = NSMutableString(string: original)
        for edit in accepted.edits.reversed() {
            replacement.replaceCharacters(
                in: NSRange(location: edit.range.location - replacementRange.location, length: edit.range.length),
                with: edit.replacementText
            )
        }
        let caretDelta = accepted.edits.reduce(0) { delta, edit in
            guard edit.range.location < accepted.caretUTF16Offset else { return delta }
            return delta + (edit.replacementText as NSString).length - edit.range.length
        }
        let nextSelection = NSRange(location: max(0, accepted.caretUTF16Offset + caretDelta), length: 0)
        let actionName = accepted.edits.count == 1
            ? "Accept Flow Correction"
            : "Fix \(accepted.edits.count) Flow Issues"
        let correctedLength = textLength - replacementRange.length + replacement.length
        let marks = accepted.correctionHighlights(correctedDocumentUTF16Length: correctedLength)
            .filter { $0.range.length > 0 }
            .map { [$0.range.location - replacementRange.location, $0.range.length] }

        // The fix counts as taken (and is not offered again) only once the page has made it; see
        // `didApply`. A patch the page declines or refuses leaves it to be offered again.
        cancelFlowSuggestion(notifyPage: false)
        let applySerial = nextSerial()
        pendingApply = PendingApply(
            serial: applySerial,
            baseRevision: revision,
            range: replacementRange,
            removed: original,
            inserted: replacement as String,
            selection: nextSelection,
            label: actionName,
            isAutomatic: isAutomatic,
            kind: .repair(accepted),
            rebasedProtectedRanges: nil
        )
        host?.sendFlow([
            "type": "apply",
            "serial": applySerial,
            "base": revision,
            "from": replacementRange.location,
            "to": NSMaxRange(replacementRange),
            "expected": original,
            "insert": replacement as String,
            "selection": ["anchor": nextSelection.location, "head": nextSelection.location],
            "expectedSelection": ["anchor": selection.location, "head": NSMaxRange(selection)],
            "label": actionName,
            "requireVisible": isAutomatic,
            "settle": ["marks": marks]
        ])
        return true
    }

    /// Sends the completion (or its next word) to the page as one source patch.
    @discardableResult
    private func acceptFlowProseSuggestion(_ suggestion: EditorFlowProseSuggestion, nextWordOnly: Bool) -> Bool {
        guard pendingApply == nil,
              gate.allowsAutocomplete,
              presentedRepair == nil,
              presentedProse?.suggestion == suggestion,
              let selection,
              suggestion.matches(documentID: documentID, revision: revision, text: text, selectedRange: selection),
              hasFocus,
              let protectedRanges = currentProtectedRanges,
              caretIsOutsideProtectedRanges(protectedRanges)
        else {
            cancelFlowSuggestion()
            return false
        }
        let insertionRange = suggestion.selectedRange
        let source = text as NSString
        guard insertionRange.location >= 0,
              insertionRange.length == 0,
              insertionRange.location <= source.length,
              let normalizedContinuation = suggestion.continuesTypedText
                ? suggestion.continuation
                : FlowProseCompletionSanitizer.insertionReadyContinuation(
                    suggestion.continuation,
                    after: source.substring(to: insertionRange.location)
                )
        else {
            cancelFlowSuggestion()
            return false
        }
        let acceptedText: String
        let remainingText: String
        if nextWordOnly {
            guard let split = FlowProseCompletionSanitizer.splitNextWord(from: normalizedContinuation) else {
                cancelFlowSuggestion()
                return false
            }
            acceptedText = split.acceptedPrefix
            remainingText = split.remainingSuffix
        } else {
            acceptedText = normalizedContinuation
            remainingText = ""
        }
        guard EditorFlowRepairPolicy.insertionRemainsOutsideProtectedSyntax(
            in: source,
            insertionLocation: insertionRange.location,
            replacement: acceptedText,
            mode: mode
        ) else {
            cancelFlowSuggestion()
            return false
        }
        let insertionLength = (acceptedText as NSString).length
        let rebasedProtectedRanges = protectedRanges.map { range in
            guard range.location >= insertionRange.location else { return range }
            return NSRange(location: range.location + insertionLength, length: range.length)
        }
        let nextSelection = NSRange(location: insertionRange.location + insertionLength, length: 0)
        let label = nextWordOnly ? "Accept Flow Word" : "Accept Flow Completion"
        // The page keeps showing the completion until the patch replaces it.
        cancelFlowSuggestion(notifyPage: false)
        let applySerial = nextSerial()
        pendingApply = PendingApply(
            serial: applySerial,
            baseRevision: revision,
            range: insertionRange,
            removed: "",
            inserted: acceptedText,
            selection: nextSelection,
            label: label,
            isAutomatic: false,
            kind: .prose(remainder: remainingText, wasRendered: true),
            rebasedProtectedRanges: rebasedProtectedRanges
        )
        host?.sendFlow([
            "type": "apply",
            "serial": applySerial,
            "base": revision,
            "from": insertionRange.location,
            "to": insertionRange.location,
            "expected": "",
            "insert": acceptedText,
            "selection": ["anchor": nextSelection.location, "head": nextSelection.location],
            "expectedSelection": ["anchor": selection.location, "head": NSMaxRange(selection)],
            "label": label,
            "flash": [0, insertionLength]
        ])
        return true
    }

    /// Delete right after a correction applied: one undo, while nothing has changed since. When it
    /// cannot be taken back, the page deletes as Delete would have, as Source falls through to an
    /// ordinary Backspace.
    private func revertSettlement(serial: Int) {
        guard let settlement,
              settlement.serial == serial,
              revision == settlement.revision,
              selection == settlement.selection,
              let undoManager = host?.flowUndoManager,
              undoManager.canUndo,
              undoManager.undoActionName == settlement.actionName
        else {
            self.settlement = nil
            host?.sendFlow(["type": "revertRefused", "serial": serial])
            return
        }
        self.settlement = nil
        undoManager.undo()
    }
}
