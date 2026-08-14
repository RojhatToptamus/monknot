import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownEditorInteractionTests: XCTestCase {
    func testWritingToolsPinsSourceModeAgainstSharedPreferenceChanges() {
        XCTAssertEqual(
            EditorWritingToolsPresentationPolicy.resolvedMode(
                .preview,
                writingToolsActive: true
            ),
            .source
        )
        XCTAssertEqual(
            EditorWritingToolsPresentationPolicy.resolvedMode(
                .preview,
                writingToolsActive: false
            ),
            .preview
        )
    }

    func testFlowEligibilityIsLimitedToMarkdownAndActualPlainTextFiles() {
        let root = URL(fileURLWithPath: "/tmp/monknot-flow-eligibility", isDirectory: true)
        let markdown = WorkspaceDocument(url: root.appendingPathComponent("Note.md"), rootURL: root)
        let plainText = WorkspaceDocument(url: root.appendingPathComponent("Draft.txt"), rootURL: root)
        let alternatePlainText = WorkspaceDocument(url: root.appendingPathComponent("Draft.text"), rootURL: root)
        let sourceCode = WorkspaceDocument(url: root.appendingPathComponent("App.swift"), rootURL: root)
        let html = WorkspaceDocument(url: root.appendingPathComponent("index.html"), rootURL: root)

        XCTAssertEqual(EditorFlowEligibility.sourceMode(for: markdown), .markdown)
        XCTAssertEqual(EditorFlowEligibility.sourceMode(for: plainText), .plainText)
        XCTAssertEqual(EditorFlowEligibility.sourceMode(for: alternatePlainText), .plainText)
        XCTAssertNil(EditorFlowEligibility.sourceMode(for: sourceCode))
        XCTAssertNil(EditorFlowEligibility.sourceMode(for: html))
    }

    func testMarkdownContextMenuExposesLinkInspectionWithoutASelection() throws {
        let textView = MarkdownNSTextView()
        textView.string = "[Guide](Guide.md)"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        var inspectionCount = 0
        textView.inspectLinksHandler = { inspectionCount += 1 }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(textView.menu(for: event))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Inspect Links" })

        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
        XCTAssertEqual(inspectionCount, 1)
    }

    func testContextMenuWithoutHandlerDoesNotExposeLinkInspection() throws {
        let textView = MarkdownNSTextView()
        textView.string = "Plain text"
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertFalse(
            try XCTUnwrap(textView.menu(for: event)).items.contains { $0.title == "Inspect Links" }
        )
    }

    func testNativeTextCheckingPreferencesNeverEnableAutomaticRewriting() {
        let textView = MarkdownNSTextView()
        textView.flowSourceMode = .markdown
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true

        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        textView.applyInlinePredictionEligibility(true)

        XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.flowSourceMode = nil
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        ))
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testInlinePredictionsStayDisabledInProtectedMarkdownRanges() async {
        let source = "Prose words.\n`code value`\nhttps://example.com/path"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: true
        ))
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(
                checksSpelling: true,
                checksGrammar: false,
                inlinePredictions: true
            )
        )

        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        let proseRange = (source as NSString).range(of: "Prose words")
        textView.setSelectedRange(NSRange(location: NSMaxRange(proseRange), length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        let codeRange = (source as NSString).range(of: "code value")
        textView.setSelectedRange(NSRange(location: codeRange.location + 2, length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)

        let urlRange = (source as NSString).range(of: "example.com")
        textView.setSelectedRange(NSRange(location: urlRange.location + 2, length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testProtectedRangeRefreshesStaySerializedAcrossRapidInvalidations() async {
        let source = "Prose `code`"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, _) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }

        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let firstScanStarted = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(firstScanStarted)

        coordinator.externalTextDidChange()
        coordinator.externalTextDidChange()
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.maximumConcurrentCallCount, 1)

        provider.resumeBlockedCall()
        let scansFinished = await waitUntil(timeout: 3) {
            provider.callCount >= 2 && provider.activeCallCount == 0
        }
        XCTAssertTrue(scansFinished)
        XCTAssertEqual(provider.maximumConcurrentCallCount, 1)
    }

    func testInlinePredictionsRemainEnabledForProseTypingWhileRangeScanIsBlocked() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText("a", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText("1", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .yes)
        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .yes)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)
    }

    func testInlinePredictionsFailClosedWhenFourthLeadingSpaceFormsIndentedCode() async {
        let source = "   x"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "    x")
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testInlinePredictionsFailClosedWhenLetterStartsAnHTMLTag() async {
        let source = "<"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText("c", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "<c")
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testInlinePredictionsFailClosedWhenLetterCompletesAURL() async {
        await assertInlinePredictionURLCompletionFailsClosed(mode: .markdown)
        await assertInlinePredictionURLCompletionFailsClosed(mode: .plainText)
    }

    private func assertInlinePredictionURLCompletionFailsClosed(mode: FlowSourceMode) async {
        let source = "example.c"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = mode
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: mode, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText("o", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "example.co")
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testPendingProseEditKeepsInlinePredictionsDuringSelectionNotification() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        let insertionRange = textView.selectedRange()
        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: insertionRange,
            replacementString: "a"
        ))
        textView.textStorage?.replaceCharacters(in: insertionRange, with: "a")
        textView.setSelectedRange(NSRange(location: insertionRange.location + 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))

        XCTAssertEqual(textView.inlinePredictionType, .yes)
        textView.didChangeText()
        XCTAssertEqual(textView.inlinePredictionType, .yes)
    }

    func testInlinePredictionsFailClosedForPunctuationUntilRangeScanFinishes() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialScanFinished = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)

        textView.insertText(".", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .yes)
    }

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
        XCTAssertEqual(grammar & NSTextCheckingResult.CheckingType.spelling.rawValue, 0)
        XCTAssertEqual(grammar & NSTextCheckingResult.CheckingType.correction.rawValue, 0)
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.grammar.rawValue, 0)
    }

    func testConcreteCorrectionResolverUsesNearestResultAndExactGrammarRange() throws {
        let source = "teh sentence are here"
        let spellingRange = (source as NSString).range(of: "teh")
        let sentenceRange = (source as NSString).range(of: "sentence are")
        let grammarRange = (source as NSString).range(of: "are")
        let relativeGrammarRange = NSRange(
            location: grammarRange.location - sentenceRange.location,
            length: grammarRange.length
        )
        let spelling = NSTextCheckingResult.spellCheckingResult(range: spellingRange)
        let grammar = NSTextCheckingResult.grammarCheckingResult(
            range: sentenceRange,
            details: [[
                NSGrammarRange: NSValue(range: relativeGrammarRange),
                NSGrammarCorrections: ["is"],
            ]]
        )

        let correction = try XCTUnwrap(EditorFlowCorrectionResolver.nearestConcreteCorrection(
            in: source,
            caretUTF16Offset: (source as NSString).length,
            results: [spelling, grammar],
            orthography: nil,
            spellingCorrection: { range, _ in range == spellingRange ? "the" : nil }
        ))

        XCTAssertEqual(correction.range, grammarRange)
        XCTAssertEqual(correction.replacementText, "is")
        XCTAssertEqual(correction.kind, .grammar)
    }

    func testCorrectionResolverRejectsAmbiguousGrammarChoices() {
        let source = "They is ready"
        let range = (source as NSString).range(of: "is")
        let result = NSTextCheckingResult.grammarCheckingResult(
            range: range,
            details: [[NSGrammarCorrections: ["are", "were"]]]
        )

        XCTAssertNil(EditorFlowCorrectionResolver.nearestConcreteCorrection(
            in: source,
            caretUTF16Offset: NSMaxRange(range),
            results: [result],
            orthography: nil,
            spellingCorrection: { _, _ in nil }
        ))
    }

    func testFlowSuggestionRejectsEveryStaleIdentityDimension() {
        let source = "Fix teh "
        let checkedRange = (source as NSString).range(of: "teh")
        let selection = NSRange(location: (source as NSString).length, length: 0)
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 4,
            checkedRange: checkedRange,
            selectedRange: selection,
            caretUTF16Offset: selection.location,
            checkedText: "teh",
            replacementText: "the",
            kind: .spelling
        )

        XCTAssertTrue(suggestion.matches(
            documentID: "note.md",
            revision: 4,
            text: source,
            selectedRange: selection
        ))
        XCTAssertFalse(suggestion.matches(
            documentID: "other.md",
            revision: 4,
            text: source,
            selectedRange: selection
        ))
        XCTAssertFalse(suggestion.matches(
            documentID: "note.md",
            revision: 5,
            text: source,
            selectedRange: selection
        ))
        XCTAssertFalse(suggestion.matches(
            documentID: "note.md",
            revision: 4,
            text: "Fix ten ",
            selectedRange: selection
        ))
        XCTAssertFalse(suggestion.matches(
            documentID: "note.md",
            revision: 4,
            text: source,
            selectedRange: NSRange(location: selection.location - 1, length: 0)
        ))
    }

    func testDelayedCheckerResultIsDiscardedAfterContinuedTyping() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let requestBox = FlowCheckingRequestBox()
        let checkerRequested = expectation(description: "Native checker requested")
        requestBox.onRequest = { checkerRequested.fulfill() }
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                requestBox.capture(completion)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        )

        textView.insertText(" ", replacementRange: textView.selectedRange())
        await fulfillment(of: [checkerRequested], timeout: 2)
        let completion = try XCTUnwrap(requestBox.completion)
        XCTAssertNil(textView.flowSuggestion)

        textView.insertText("x", replacementRange: textView.selectedRange())
        completion([
            NSTextCheckingResult.correctionCheckingResult(
                range: NSRange(location: 0, length: 3),
                replacementString: "the"
            ),
        ], nil)
        let didDisplayStaleSuggestion = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }
        XCTAssertFalse(didDisplayStaleSuggestion)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh x")
    }

    func testDelayedCheckerResultDisplaysConcreteSuggestionWhenSnapshotIsCurrent() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let requestBox = FlowCheckingRequestBox()
        let checkerRequested = expectation(description: "Native checker requested")
        requestBox.onRequest = { checkerRequested.fulfill() }
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                requestBox.capture(completion)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        )

        textView.insertText(" ", replacementRange: textView.selectedRange())
        await fulfillment(of: [checkerRequested], timeout: 2)
        try XCTUnwrap(requestBox.completion)([
            NSTextCheckingResult.correctionCheckingResult(
                range: NSRange(location: 0, length: 3),
                replacementString: "the"
            ),
        ], nil)
        let didDisplaySuggestion = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(didDisplaySuggestion)

        XCTAssertNotNil(textView.flowSuggestion)
        XCTAssertEqual(textView.flowSuggestion?.replacementText, "the")
        XCTAssertEqual(textView.string, "teh ")
    }

    func testDelayedCheckerResultIsRejectedWhenCaretIsInProtectedMarkdown() async throws {
        let source = "teh `code"
        let box = EditorTextBox(source)
        let requestBox = FlowCheckingRequestBox()
        let checkerRequested = expectation(description: "Native checker requested")
        requestBox.onRequest = { checkerRequested.fulfill() }
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                requestBox.capture(completion)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        )

        textView.insertText(" ", replacementRange: textView.selectedRange())
        await fulfillment(of: [checkerRequested], timeout: 2)
        try XCTUnwrap(requestBox.completion)([
            NSTextCheckingResult.correctionCheckingResult(
                range: NSRange(location: 0, length: 3),
                replacementString: "the"
            ),
        ], nil)
        let didDisplayProtectedSuggestion = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }
        XCTAssertFalse(didDisplayProtectedSuggestion)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh `code ")
    }

    func testRapidTypingKeepsCheckerSilentBeforeIdleDebounce() async {
        let box = EditorTextBox("")
        let checkerRequested = expectation(description: "Native checker stays silent")
        checkerRequested.isInverted = true
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, _ in
                checkerRequested.fulfill()
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: "")
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        )

        textView.insertText("t", replacementRange: textView.selectedRange())
        textView.insertText("e", replacementRange: textView.selectedRange())
        textView.insertText("h", replacementRange: textView.selectedRange())

        await fulfillment(of: [checkerRequested], timeout: 0.2)
        XCTAssertNil(textView.flowSuggestion)
    }

    func testFlowTabReplacesCheckedWordBeforeListIndentationAsOneUndoableEdit() throws {
        let source = "- teh "
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.markdownShortcutsEnabled = true
        textView.undoManager?.removeAllActions()
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "- the ")
        XCTAssertEqual(box.value, "- the ")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testWikilinkTabKeepsPriorityOverVisibleFlowSuggestion() throws {
        let source = "[[Al"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let root = URL(fileURLWithPath: "/tmp/monknot-flow-wikilink", isDirectory: true)
        textView.wikilinkDocuments = [
            WorkspaceDocument(url: root.appendingPathComponent("Alpha.md"), rootURL: root)
        ]
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "Al",
            replacement: "All"
        )

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "[[Alpha]]")
        XCTAssertEqual(box.value, "[[Alpha]]")
    }

    func testWritingToolsLetsAppKitOwnTabAndReturnInsteadOfMarkdownHandlers() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "[[Al"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: ActiveWritingToolsTextView(frame: .zero)
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let root = URL(fileURLWithPath: "/tmp/monknot-writing-tools-keys", isDirectory: true)
        textView.markdownShortcutsEnabled = true
        textView.wikilinkDocuments = [
            WorkspaceDocument(url: root.appendingPathComponent("Alpha.md"), rootURL: root)
        ]
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertNotEqual(textView.string, "[[Alpha]]")

        textView.string = "- item"
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))
        XCTAssertNotEqual(textView.string, "- item\n- ")
    }

    func testTabFallsBackToNativeEditingWithoutWikilinkOrFlowSuggestion() throws {
        let source = "plain"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "plain\t")
        XCTAssertEqual(box.value, "plain\t")
    }

    func testEscapeDismissesFlowAndSpaceRemainsNativeInput() throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, source)

        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: " ",
            modifiers: [],
            keyCode: 49,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh ")
        XCTAssertEqual(box.value, "teh ")
    }

    func testFlowClearsOnDocumentSwitchFocusLossAndTeardown() {
        let source = "teh"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )

        _ = coordinator.prepareForDocument("other.md", in: scrollView)
        XCTAssertNil(textView.flowSuggestion)

        coordinator.documentID = "note.md"
        coordinator.externalTextDidChange()
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        window.makeFirstResponder(nil)
        XCTAssertNil(textView.flowSuggestion)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        window.resignKey()
        XCTAssertNil(textView.flowSuggestion)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        XCTAssertNil(textView.flowSuggestion)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        XCTAssertNil(textView.flowSuggestion)
    }

    func testWritingToolsConfigurationIgnoredRangesAndSingleFinalPublication() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "Prose `code` [link](Guide.md)"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        textView.flowSourceMode = .markdown
        var states: [Bool] = []
        var commits: [(String, String)] = []
        coordinator.onWritingToolsStateChange = { _, isActive in
            states.append(isActive)
            return true
        }
        coordinator.onWritingToolsTextCommit = { documentID, text in
            commits.append((documentID, text))
            box.value = text
        }

        textView.applyWritingTools(nil, protectedRangesReady: false)
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        textView.applyWritingTools(.markdown, protectedRangesReady: true)
        XCTAssertEqual(textView.writingToolsBehavior, .limited)
        XCTAssertEqual(textView.allowedWritingToolsResultOptions, [.plainText])
        textView.applyWritingTools(.markdown, protectedRangesReady: false)
        if #available(macOS 15.2, *) {
            XCTAssertTrue(textView.responds(to: #selector(NSResponder.showWritingTools(_:))))
        }
        let codeRange = (source as NSString).range(of: "`code`")
        let enclosingRange = NSRange(location: codeRange.location + 1, length: codeRange.length)
        let cacheMissIgnored = coordinator.textView(
            textView,
            writingToolsIgnoredRangesInEnclosingRange: enclosingRange
        ).map(\.rangeValue)
        XCTAssertEqual(cacheMissIgnored, [NSRange(location: 0, length: enclosingRange.length)])

        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)
        let ignored = coordinator.textView(
            textView,
            writingToolsIgnoredRangesInEnclosingRange: enclosingRange
        ).map(\.rangeValue)
        XCTAssertEqual(ignored, [NSRange(location: 0, length: codeRange.length - 1)])

        coordinator.textViewWritingToolsWillBegin(textView)
        textView.textStorage?.replaceCharacters(
            in: (textView.string as NSString).range(of: "Prose"),
            with: "Clear prose"
        )
        textView.didChangeText()
        XCTAssertEqual(box.value, source)
        XCTAssertTrue(coordinator.isWritingToolsActive)

        coordinator.textViewWritingToolsDidEnd(textView)
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0, "note.md")
        XCTAssertEqual(commits.first?.1, "Clear prose `code` [link](Guide.md)")
        XCTAssertEqual(box.value, "Clear prose `code` [link](Guide.md)")
        XCTAssertFalse(coordinator.isWritingToolsActive)
    }

    func testWritingToolsRebasesProtectedRangesAfterEarlierTextChanges() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "Draft `code` tail"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        coordinator.textViewWritingToolsWillBegin(textView)

        let proseRange = (textView.string as NSString).range(of: "Draft")
        let replacement = "A much clearer draft"
        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: proseRange,
            replacementString: replacement
        ))
        textView.textStorage?.replaceCharacters(in: proseRange, with: replacement)
        textView.didChangeText()

        let enclosingRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let expectedCodeRange = (textView.string as NSString).range(of: "`code`")
        let ignoredRanges = coordinator.textView(
            textView,
            writingToolsIgnoredRangesInEnclosingRange: enclosingRange
        ).map(\.rangeValue)
        XCTAssertTrue(ignoredRanges.contains(expectedCodeRange))
        XCTAssertFalse(coordinator.textView(
            textView,
            shouldChangeTextIn: expectedCodeRange,
            replacementString: "plain text"
        ))
        XCTAssertTrue(coordinator.textView(
            textView,
            writingToolsIgnoredRangesInEnclosingRange: enclosingRange
        ).map(\.rangeValue).contains(expectedCodeRange))

        coordinator.textViewWritingToolsDidEnd(textView)
    }

    func testWritingToolsEndKeepsNativeUndoAndAllowsSyntaxRefresh() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "# Draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        coordinator.onWritingToolsStateChange = { _, _ in true }
        coordinator.onWritingToolsTextCommit = { _, text in box.value = text }
        textView.undoManager?.removeAllActions()

        coordinator.textViewWritingToolsWillBegin(textView)
        textView.insertText(" polished", replacementRange: textView.selectedRange())
        XCTAssertEqual(box.value, source)
        coordinator.textViewWritingToolsDidEnd(textView)

        XCTAssertEqual(box.value, "# Draft polished")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        coordinator.applySyntaxHighlighting(
            enabled: true,
            theme: .defaultDark,
            font: font,
            in: textView
        )
        let headingColor = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(headingColor, NSColor(hex: AppTheme.defaultDark.accent))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testWritingToolsExternalConflictPreservesHostedTextAndNativeUndo() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-writing-tools-undo-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Flow.md")
        let baseline = "Original\n"
        let localDraft = "A substantially longer local draft\n"
        let diskText = "X\n"
        try baseline.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        XCTAssertTrue(didLoad)
        let documentID = try XCTUnwrap(store.selectedDocumentID)
        store.testing_stopFileWatcher()
        store.setDocumentText(localDraft)
        try diskText.write(to: fileURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        XCTAssertTrue(didDetectConflict)
        XCTAssertEqual(store.documentText, localDraft)

        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { store.documentText },
                set: { store.setDocumentText($0) }
            )
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: store.documentText
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        coordinator.documentID = documentID
        coordinator.onWritingToolsStateChange = { id, isActive in
            store.setWritingToolsActive(isActive, documentID: id)
        }
        coordinator.onWritingToolsTextCommit = { id, text in
            store.commitWritingToolsText(text, documentID: id)
        }
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        textView.undoManager?.removeAllActions()

        coordinator.textViewWritingToolsWillBegin(textView)
        XCTAssertTrue(coordinator.isWritingToolsActive)
        textView.insertText(
            baseline,
            replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        coordinator.textViewWritingToolsDidEnd(textView)

        XCTAssertEqual(textView.string, baseline)
        XCTAssertEqual(store.documentText, baseline)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), diskText)

        if textView.string != store.documentText {
            let selectedRanges = textView.selectedRanges
            textView.string = store.documentText
            textView.selectedRanges = selectedRanges
            coordinator.externalTextDidChange()
        }
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()

        XCTAssertEqual(textView.string, localDraft)
        XCTAssertEqual(store.documentText, localDraft)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), diskText)
    }

    func testWritingToolsTeardownPublishesFinalTextExactlyOnce() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "Draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        var commits: [String] = []
        var states: [Bool] = []
        coordinator.onWritingToolsStateChange = { _, isActive in
            states.append(isActive)
            return true
        }
        coordinator.onWritingToolsTextCommit = { _, text in commits.append(text) }

        coordinator.textViewWritingToolsWillBegin(textView)
        textView.insertText(" final", replacementRange: textView.selectedRange())
        dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        coordinator.textViewWritingToolsDidEnd(textView)

        XCTAssertEqual(commits, ["Draft final"])
        XCTAssertEqual(states, [true, false])
    }

    func testWritingToolsContextMenuFollowsEditorEligibility() throws {
        guard #available(macOS 15.2, *) else {
            throw XCTSkip("Writing Tools menu integration requires macOS 15.2.")
        }
        let box = EditorTextBox("Text")
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: box.value)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.flowSourceMode = nil
        let ineligibleMenu = try XCTUnwrap(textView.menu(for: event))
        XCTAssertFalse(ineligibleMenu.automaticallyInsertsWritingToolsItems)

        textView.flowSourceMode = .markdown
        textView.applyWritingTools(.markdown, protectedRangesReady: true)
        let eligibleMenu = try XCTUnwrap(textView.menu(for: event))
        XCTAssertTrue(eligibleMenu.automaticallyInsertsWritingToolsItems)
    }

    func testWritingToolsDoesNotEnterPublicationPauseWhenOwnerRejectsStart() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let box = EditorTextBox("Text")
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: box.value)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        coordinator.onWritingToolsStateChange = { _, _ in false }

        coordinator.textViewWritingToolsWillBegin(textView)

        XCTAssertFalse(coordinator.isWritingToolsActive)
    }

    func testWritingToolsDropsDeferredToolbarCommandInsteadOfApplyingItAfterEnd() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "Draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)

        coordinator.textViewWritingToolsWillBegin(textView)
        let request = MarkdownTextEditorCommandRequest(serial: 1, command: .bold)
        coordinator.apply(request)
        coordinator.textViewWritingToolsDidEnd(textView)
        coordinator.apply(request)

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testDocumentEditorSupportsNativeSpellingActions() {
        let source = "A misspeled sentence."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }

        XCTAssertTrue(textView.responds(to: #selector(NSText.checkSpelling(_:))))
        XCTAssertTrue(textView.responds(to: #selector(NSText.showGuessPanel(_:))))
        textView.checkSpelling(nil)
        XCTAssertEqual(textView.string, source)
        withExtendedLifetime(window) {}
    }

    func testCommandLinkActivationUsesSharedParserAndLeavesNormalTextUntouched() {
        let source = """
        See [[Daily Note#Plan]], [guide](Guide.md#Setup), and [reference][guide ref].

        [guide ref]: Reference.md#Details
        """
        let textView = MarkdownNSTextView()
        textView.string = source
        var requests: [MarkdownEditorLinkRequest] = []
        textView.workspaceLinkHandler = { link in
            requests.append(MarkdownEditorLinkRequest(documentID: "note.md", revision: 0, link: link))
            return true
        }

        let wikilinkOffset = (source as NSString).range(of: "Daily Note").location
        XCTAssertTrue(textView.activateMarkdownLink(atUTF16Offset: wikilinkOffset))
        XCTAssertEqual(requests.last?.link.kind, .wikilink)
        XCTAssertEqual(requests.last?.link.destination, "Daily Note#Plan")

        let regularOffset = (source as NSString).range(of: "guide").location
        XCTAssertTrue(textView.activateMarkdownLink(atUTF16Offset: regularOffset))
        XCTAssertEqual(requests.last?.link.kind, .markdown)
        XCTAssertEqual(requests.last?.link.destination, "Guide.md#Setup")

        let referenceOffset = (source as NSString).range(of: "reference").location
        XCTAssertTrue(textView.activateMarkdownLink(atUTF16Offset: referenceOffset))
        XCTAssertEqual(requests.last?.link.kind, .referenceUsage)
        XCTAssertEqual(requests.last?.link.destination, "Reference.md#Details")
        XCTAssertFalse(textView.activateMarkdownLink(atUTF16Offset: 0))
        XCTAssertEqual(textView.string, source)
    }

    func testSelectionReportsDocumentRevisionRangeAndExactMarkdown() {
        let source = "before **selected** after"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var selection: MarkdownEditorSelectionSnapshot?
        coordinator.onSelectionChange = { selection = $0 }

        textView.setSelectedRange((source as NSString).range(of: "**selected**"))
        coordinator.publishSelection()

        XCTAssertEqual(selection?.documentID, "note.md")
        XCTAssertEqual(selection?.selectedMarkdown, "**selected**")
        XCTAssertEqual(selection?.caretUTF16Offset, NSMaxRange((source as NSString).range(of: "**selected**")))
        withExtendedLifetime(window) {}
    }

    func testPersistedSelectionRestoresOnceWithUTF16ClampingAndDoesNotFightLiveSelection() throws {
        let source = "A😀BC"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var published: MarkdownEditorSelectionSnapshot?
        coordinator.onSelectionChange = { published = $0 }

        coordinator.restoreSelectionIfNeeded(
            DocumentTextSelection(location: 3, length: 99),
            in: textView
        )

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 2))
        XCTAssertEqual(published?.selectedRange, NSRange(location: 3, length: 2))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.restoreSelectionIfNeeded(
            DocumentTextSelection(location: 4, length: 1),
            in: textView
        )
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
        withExtendedLifetime(window) {}
    }

    func testImagePasteRequestDoesNotMutateUntilValidatedNativeInsertionAndSupportsUndo() throws {
        let source = "before selected after"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.setSelectedRange((source as NSString).range(of: "selected"))
        var request: MarkdownImagePasteRequest?
        coordinator.onImagePasteRequest = { request = $0 }
        textView.imagePasteHandler = { coordinator.requestImagePaste($0) }
        XCTAssertTrue(coordinator.requestImagePaste(testImage()))
        XCTAssertEqual(textView.string, source)
        let captured = try XCTUnwrap(request)
        XCTAssertEqual(captured.sourceText, source)
        XCTAssertEqual(captured.selectedRange, (source as NSString).range(of: "selected"))

        XCTAssertTrue(captured.insertMarkdown("![](../assets/pasted-image.png)"))
        XCTAssertEqual(textView.string, "before ![](../assets/pasted-image.png) after")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        withExtendedLifetime(window) {}
    }

    func testImagePasteInsertionRejectsStaleEditorRevisionAndSelection() throws {
        let source = "draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var request: MarkdownImagePasteRequest?
        coordinator.onImagePasteRequest = { request = $0 }
        textView.imagePasteHandler = { coordinator.requestImagePaste($0) }

        XCTAssertTrue(coordinator.requestImagePaste(testImage()))
        let captured = try XCTUnwrap(request)
        textView.insertText(" changed", replacementRange: textView.selectedRange())

        XCTAssertFalse(captured.insertMarkdown("![](assets/stale.png)"))
        XCTAssertEqual(textView.string, "draft changed")
        withExtendedLifetime(window) {}
    }

    func testWritingToolsRejectsImageAndFileDropInsertionsCapturedBeforeItStarts() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Writing Tools requires macOS 15.")
        }
        let source = "draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var imageRequest: MarkdownImagePasteRequest?
        var fileDropRequest: MarkdownFileDropRequest?
        coordinator.onImagePasteRequest = { imageRequest = $0 }
        coordinator.onFileDropRequest = { fileDropRequest = $0 }

        XCTAssertTrue(coordinator.requestImagePaste(testImage()))
        XCTAssertTrue(coordinator.requestFileDrop(
            [URL(fileURLWithPath: "/tmp/Guide.md")],
            atUTF16Offset: (source as NSString).length
        ))
        let capturedImage = try XCTUnwrap(imageRequest)
        let capturedDrop = try XCTUnwrap(fileDropRequest)
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        coordinator.textViewWritingToolsWillBegin(textView)

        XCTAssertFalse(capturedImage.insertMarkdown("![](assets/pasted.png)"))
        XCTAssertFalse(capturedDrop.insertMarkdown("[Guide](Guide.md)"))
        XCTAssertEqual(textView.string, source)

        coordinator.textViewWritingToolsDidEnd(textView)
        XCTAssertEqual(box.value, source)
    }

    func testFileDropCapturesInsertionOffsetAndCommitsOneUndoableChange() throws {
        let source = "before after"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        var request: MarkdownFileDropRequest?
        coordinator.onFileDropRequest = { request = $0 }
        let urls = [URL(fileURLWithPath: "/tmp/Guide.md"), URL(fileURLWithPath: "/tmp/Map.png")]

        XCTAssertTrue(coordinator.requestFileDrop(urls, atUTF16Offset: 7))
        XCTAssertEqual(textView.string, source)
        let captured = try XCTUnwrap(request)
        XCTAssertEqual(captured.urls, urls)
        XCTAssertEqual(captured.insertionRange, NSRange(location: 7, length: 0))

        XCTAssertTrue(captured.insertMarkdown("[Guide](Guide.md)\n![Map](Map.png)"))
        XCTAssertEqual(textView.string, "before [Guide](Guide.md)\n![Map](Map.png)after")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        withExtendedLifetime(window) {}
    }

    func testFileDropInsertionRejectsStaleEditorRevision() throws {
        let source = "draft"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var request: MarkdownFileDropRequest?
        coordinator.onFileDropRequest = { request = $0 }

        XCTAssertTrue(coordinator.requestFileDrop([URL(fileURLWithPath: "/tmp/Guide.md")], atUTF16Offset: 2))
        let captured = try XCTUnwrap(request)
        textView.insertText(" changed", replacementRange: textView.selectedRange())

        XCTAssertFalse(captured.insertMarkdown("[Guide](Guide.md)"))
        XCTAssertEqual(textView.string, "draft changed")
        withExtendedLifetime(window) {}
    }

    func testCurrentDocumentSearchHonorsCaseAndWholeWordOptions() {
        let source = "Cat cat scatter cat_2 cat-café"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("cat")
        let options = MonknotSearchOptions(isCaseSensitive: true, isWholeWord: true)

        let result = coordinator.applySearch(
            search,
            options: options,
            theme: .defaultDark,
            in: textView
        )
        search.updateResult(result)

        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(textView.string, source)
        withExtendedLifetime(window) {}
    }

    func testStructuralListCommandUsesOneNativeUndoGroup() {
        let source = "- first"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.markdownShortcutsEnabled = true
        textView.undoManager?.removeAllActions()

        XCTAssertTrue(textView.performMarkdownListEdit(.newline))
        XCTAssertEqual(textView.string, "- first\n- ")
        XCTAssertEqual(box.value, "- first\n- ")
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "- first\n- ")
        XCTAssertEqual(box.value, "- first\n- ")
        withExtendedLifetime(window) {}
    }

    func testWikilinkCompletionKeepsPriorityOverListIndentationOnTab() throws {
        let source = "- [[Al"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let root = URL(fileURLWithPath: "/tmp/monknot-list-wikilink", isDirectory: true)
        textView.markdownShortcutsEnabled = true
        textView.wikilinkDocuments = [
            WorkspaceDocument(url: root.appendingPathComponent("Alpha.md"), rootURL: root)
        ]

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "- [[Alpha]]")
        XCTAssertEqual(box.value, "- [[Alpha]]")
        withExtendedLifetime(window) {}
    }

    private func prepareWritingTools(
        _ coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView
    ) async -> Bool {
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        return await waitUntil { textView.flowWritingToolsReady }
    }

    private func makeCoordinator(_ box: EditorTextBox) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            )
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeHostedTextView(
        coordinator: MarkdownTextEditor.Coordinator,
        text: String,
        textView: MarkdownNSTextView? = nil
    ) -> (NSWindow, NSScrollView, MarkdownNSTextView) {
        let window = FlowTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = textView ?? MarkdownNSTextView(frame: scrollView.bounds)
        textView.frame = scrollView.bounds
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.flowSuggestionAcceptanceHandler = { coordinator.acceptFlowSuggestion($0) }
        textView.flowSuggestionDismissalHandler = { coordinator.cancelFlowSuggestion() }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scrollView.documentView = textView
        window.contentView = scrollView
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.externalTextDidChange()
        coordinator.attach(to: scrollView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        return (window, scrollView, textView)
    }

    private func flowSuggestion(
        coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView,
        checkedText: String,
        replacement: String
    ) -> EditorFlowSuggestion {
        return EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            checkedRange: (textView.string as NSString).range(of: checkedText),
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location + textView.selectedRange().length,
            checkedText: checkedText,
            replacementText: replacement,
            kind: .spelling
        )
    }

    private func dismantleHostedTextView(
        _ window: NSWindow,
        scrollView: NSScrollView,
        coordinator: MarkdownTextEditor.Coordinator
    ) {
        MarkdownTextEditor.dismantleNSView(scrollView, coordinator: coordinator)
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.orderOut(nil)
    }

    private func testImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

private final class EditorTextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

private final class FlowCheckingRequestBox {
    var completion: EditorFlowCheckingClient.Completion?
    var onRequest: (() -> Void)?

    func capture(_ completion: @escaping EditorFlowCheckingClient.Completion) {
        self.completion = completion
        onRequest?()
    }
}

private final class BlockingProtectedRangeProvider: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockingCall: Int
    private var storedCallCount = 0
    private var storedActiveCallCount = 0
    private var storedMaximumConcurrentCallCount = 0
    private var callBlocked = false
    private var blockedCallReleased = false

    init(blockingCall: Int = 1) {
        self.blockingCall = blockingCall
    }

    var callCount: Int {
        condition.withLock { storedCallCount }
    }

    var activeCallCount: Int {
        condition.withLock { storedActiveCallCount }
    }

    var maximumConcurrentCallCount: Int {
        condition.withLock { storedMaximumConcurrentCallCount }
    }

    var isCallBlocked: Bool {
        condition.withLock { callBlocked }
    }

    func protectedRanges(in text: String, mode: FlowSourceMode) -> [NSRange] {
        condition.lock()
        storedCallCount += 1
        storedActiveCallCount += 1
        storedMaximumConcurrentCallCount = max(
            storedMaximumConcurrentCallCount,
            storedActiveCallCount
        )
        let shouldBlock = storedCallCount == blockingCall
        if shouldBlock {
            callBlocked = true
            condition.broadcast()
            while !blockedCallReleased {
                condition.wait()
            }
        }
        condition.unlock()

        let ranges = FlowProtectedRangeService().protectedRanges(in: text, mode: mode)
        condition.withLock {
            storedActiveCallCount -= 1
            condition.broadcast()
        }
        return ranges
    }

    func resumeBlockedCall() {
        condition.withLock {
            blockedCallReleased = true
            condition.broadcast()
        }
    }
}

private final class FlowTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@available(macOS 15.0, *)
private final class ActiveWritingToolsTextView: MarkdownNSTextView {
    override var isWritingToolsActive: Bool { true }
}
