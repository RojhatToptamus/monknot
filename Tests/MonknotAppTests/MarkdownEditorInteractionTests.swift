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
        XCTAssertEqual(textView.inlinePredictionType, .default)

        textView.flowSourceMode = nil
        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        ))
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
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

    func testDefaultTextCheckingEnablesSpellingGrammarAndSystemInlinePredictions() {
        XCTAssertTrue(EditorTextCheckingOptions.defaultValue.checksSpelling)
        XCTAssertTrue(EditorTextCheckingOptions.defaultValue.checksGrammar)
        XCTAssertTrue(EditorTextCheckingOptions.defaultValue.inlinePredictions)
        XCTAssertFalse(EditorTextCheckingOptions.defaultValue.onDeviceProseCompletions)
    }

    func testUnavailableOnDeviceCompletionKeepsNativePredictionAndNeverCallsClient() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(isAvailable: false, result: "clearer prose.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)
    }

    func testOnDeviceCompletionTabAcceptsOnlyVisibleTextAndUndoIsOneStep() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "clearer prose.")
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertEqual(prose.requests.map(\.context), ["We can write "])

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearer prose.")
        XCTAssertEqual(box.value, "We can write clearer prose.")
        XCTAssertNil(textView.flowProseSuggestion)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "We can write ")
        XCTAssertEqual(box.value, "We can write ")
    }

    func testOnDeviceCompletionOptionRightAcceptsOneWordThenTabAcceptsRemainder() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearly, with confidence.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.option, .numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "We can write clearly, ")
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "with confidence.")
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(try XCTUnwrap(
            textView.flowProseSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, with confidence.")
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testDefaultChecksDelayThenRestoreOptionRightCompletionRemainder() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearly, with confidence.")
        var checkedTexts: [String] = []
        var completions: [EditorFlowCheckingClient.Completion] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                checkedTexts.append(checkedText)
                completions.append(completion)
            },
            proseCompletion: prose.service
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let initialCheckStarted = await waitUntil { completions.count == 1 }
        XCTAssertTrue(initialCheckStarted)
        XCTAssertNil(textView.flowProseSuggestion)
        completions[0]([], englishOrthography())
        let completionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(completionReady)
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "clearly, with confidence.")
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(try XCTUnwrap(
            textView.flowProseSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.option, .numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, ")
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        let partialCheckStarted = await waitUntil { completions.count == 2 }
        XCTAssertTrue(partialCheckStarted)
        XCTAssertEqual(checkedTexts.last, "We can write clearly,")
        XCTAssertNil(textView.flowProseSuggestion)
        completions[1]([], englishOrthography())
        let remainderRestored = await waitUntil {
            textView.flowProseSuggestion?.continuation == "with confidence."
        }
        XCTAssertTrue(remainderRestored)
        let alreadySeenRemainder = try XCTUnwrap(textView.flowProseSuggestion)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(alreadySeenRemainder))

        // The remainder was part of the ghost the user already saw. The clean
        // repair check may gate its reappearance, but must not require a second
        // paint before the immediately following hardware Tab can accept it.
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, with confidence.")
        XCTAssertEqual(box.value, "We can write clearly, with confidence.")
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testPendingOptionRightRemainderIsDiscardedWhenItNoLongerFitsBeforeCleanRelease() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearly, with confidence.")
        var completions: [EditorFlowCheckingClient.Completion] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completions.append(completion)
            },
            proseCompletion: prose.service
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let initialCheckStarted = await waitUntil { completions.count == 1 }
        XCTAssertTrue(initialCheckStarted)
        completions[0]([], englishOrthography())
        let completionReady = await waitUntil {
            textView.flowProseSuggestion?.continuation == "clearly, with confidence."
        }
        XCTAssertTrue(completionReady)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.option, .numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, ")
        XCTAssertNil(textView.flowProseSuggestion)
        let partialCheckStarted = await waitUntil { completions.count == 2 }
        XCTAssertTrue(partialCheckStarted)

        window.setContentSize(NSSize(width: 150, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        textView.refreshContentWidthLayout()
        completions[1]([], englishOrthography())

        let nativePredictionRestored = await waitUntil {
            textView.flowProseSuggestion == nil && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(nativePredictionRestored)
        XCTAssertEqual(textView.string, "We can write clearly, ")
        XCTAssertEqual(box.value, "We can write clearly, ")

        window.setContentSize(NSSize(width: 700, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        textView.refreshContentWidthLayout()
        await nextMainRunLoopTurn()
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testCustomAutocompleteTabBeforeFirstPaintDoesNotInsertUnseenText() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: nil)
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let cleanGateReady = await waitUntil {
            prose.requestCount == 1 && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(cleanGateReady)
        let unchangedText = source + " "
        let suggestion = EditorFlowProseSuggestion(
            documentID: "note.md",
            revision: coordinator.revision,
            sourceUTF16Length: (unchangedText as NSString).length,
            selectedRange: textView.selectedRange(),
            continuation: "with confidence."
        )
        textView.flowProseSuggestion = suggestion
        coordinator.refreshNativeFlowAvailability()

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, unchangedText + "\t")
        XCTAssertEqual(box.value, unchangedText + "\t")
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertFalse(textView.string.contains("confidence"))
    }

    func testCustomAutocompleteOptionRightBeforeFirstPaintRoutesNativeWithoutUnseenInsertion() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: nil)
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)
        let caret = (source as NSString).range(of: "write").location
        let selection = NSRange(location: caret, length: 0)
        textView.setSelectedRange(selection)
        let suggestion = EditorFlowProseSuggestion(
            documentID: "note.md",
            revision: coordinator.revision,
            sourceUTF16Length: (source as NSString).length,
            selectedRange: selection,
            continuation: "clearly "
        )
        textView.flowProseSuggestion = suggestion
        coordinator.refreshNativeFlowAvailability()
        XCTAssertFalse(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.option, .numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertFalse(textView.string.contains("clearly"))
        XCTAssertGreaterThan(textView.selectedRange().location, caret)
    }

    func testNilOnDeviceCompletionFallsBackToNativeAndUsesCooldown() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: nil)
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let firstRequestFinished = await waitUntil {
            prose.requestCount == 1 && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(firstRequestFinished)
        XCTAssertNil(textView.flowProseSuggestion)

        textView.insertText("x", replacementRange: textView.selectedRange())
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(prose.requestCount, 1)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)
    }

    func testValidCompletionThatCannotFitDoesNotStartFailureCooldown() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "extraordinarilylongword")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 120, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let firstAttemptFinished = await waitUntil {
            prose.requestCount == 1 && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(firstAttemptFinished)
        XCTAssertNil(textView.flowProseSuggestion)

        window.setContentSize(NSSize(width: 700, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        textView.refreshContentWidthLayout()
        textView.insertText("x", replacementRange: textView.selectedRange())
        let secondAttemptFinished = await waitUntil { prose.requestCount == 2 }
        XCTAssertTrue(secondAttemptFinished)
        XCTAssertNotNil(textView.flowProseSuggestion)
    }

    func testOnDeviceCompletionResumesOnceWhenProtectedRangesBecomeReady() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowProseCompletionService: prose.service,
            flowProseCompletionDelayNanoseconds: 0,
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertEqual(textView.inlinePredictionType, .default)

        provider.resumeBlockedCall()
        let suggestionReady = await waitUntil(timeout: 3) {
            prose.requestCount == 1 && textView.flowProseSuggestion != nil
        }
        XCTAssertTrue(suggestionReady)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(prose.requestCount, 1)
    }

    func testPendingProtectedRangeRetryCannotReviveAfterSelectionChange() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowProseCompletionService: prose.service,
            flowProseCompletionDelayNanoseconds: 0,
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        try? await Task.sleep(nanoseconds: 40_000_000)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        provider.resumeBlockedCall()
        let refreshFinished = await waitUntil(timeout: 3) { provider.activeCallCount == 0 }
        XCTAssertTrue(refreshFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testOnDeviceCompletionContextIncludesPreviousHardWrappedLine() async {
        let source = "Earlier line gives useful context\nContinue this"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "with a useful ending.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let requestArrived = await waitUntil { prose.requestCount == 1 }
        XCTAssertTrue(requestArrived)
        guard let context = prose.requests.first?.context else {
            return XCTFail("Expected a prose-completion request")
        }
        XCTAssertEqual(context, source + " ")
    }

    func testOnDeviceCompletionEscapeDismissesWithoutChangingText() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))

        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.string, "We can write ")
        XCTAssertEqual(box.value, "We can write ")
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testOnDeviceCompletionOrdinaryTypingDismissesAndKeepsTypedText() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "x",
            modifiers: [],
            keyCode: 7,
            windowNumber: window.windowNumber
        )))

        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.string, "We can write x")
        XCTAssertEqual(box.value, "We can write x")
    }

    func testLateOnDeviceCompletionDoesNotReappearAfterFocusLeavesAndReturns() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(
            result: "clearer prose.",
            delayNanoseconds: 200_000_000,
            ignoresCancellation: true
        )
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let requestStarted = await waitUntil { prose.requestCount == 1 }
        XCTAssertTrue(requestStarted)
        window.makeFirstResponder(nil)
        window.makeFirstResponder(textView)
        try? await Task.sleep(nanoseconds: 260_000_000)

        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.string, "We can write ")
        XCTAssertEqual(box.value, "We can write ")
    }

    func testOnDeviceCompletionExposesExactAccessibleActions() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "precisely and safely.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        let names = (textView.accessibilityCustomActions() ?? []).map(\.name)

        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("Accept completion: precisely and safely."))
        XCTAssertTrue(names.contains("Accept next completion word"))
        XCTAssertTrue(names.contains("Dismiss completion"))
    }

    func testOnDeviceCompletionContextIsBoundedForLargeDocuments() throws {
        let prefix = String(repeating: "earlier words ", count: 2_000)
        let source = prefix + "current sentence"
        let context = try XCTUnwrap(EditorFlowProseContextPlanner.context(
            in: source,
            selectedRange: NSRange(location: (source as NSString).length, length: 0),
            protectedRanges: []
        ))

        XCTAssertLessThanOrEqual(
            (context.text as NSString).length,
            FlowProseCompletionRequest.maximumContextUTF16Length
        )
        XCTAssertTrue(source.hasSuffix(context.text))
        XCTAssertTrue(context.text.hasPrefix("earlier") || context.text.hasPrefix("words"))
    }

    func testOnDeviceCompletionProtectsCodeAndLinksAndExcludesEarlierProtectedContext() async {
        let prose = FlowProseCompletionSpy(result: "with a useful ending.")
        let protectedCases: [(String, String)] = [
            ("Plain words `code value`", "value"),
            ("Plain words [guide](Target.md)", "Target.md"),
        ]
        for (source, protectedText) in protectedCases {
            let box = EditorTextBox(source)
            let coordinator = makeCoordinator(box, proseCompletion: prose.service)
            let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
            let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
            XCTAssertTrue(rangesReady)
            let protectedRange = (source as NSString).range(of: protectedText)
            textView.setSelectedRange(NSRange(location: NSMaxRange(protectedRange), length: 0))
            coordinator.textViewDidChangeSelection(Notification(
                name: NSTextView.didChangeSelectionNotification,
                object: textView
            ))
            textView.insertText("x", replacementRange: textView.selectedRange())
            try? await Task.sleep(nanoseconds: 60_000_000)
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        XCTAssertEqual(prose.requestCount, 0)

        let source = "Secret prefix `private token` Continue this"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)
        textView.insertText(" ", replacementRange: textView.selectedRange())
        let requestArrived = await waitUntil { prose.requestCount == 1 }
        XCTAssertTrue(requestArrived)

        guard let request = prose.requests.first else {
            return XCTFail("Expected one bounded prose-completion request")
        }
        XCTAssertFalse(request.context.contains("Secret prefix"))
        XCTAssertFalse(request.context.contains("private token"))
        XCTAssertTrue(request.context.contains("Continue this"))
    }

    func testOnDeviceCompletionNeverGhostsTextThatFormsBareDomainOrEmailSyntax() async {
        let cases = [
            (source: "Visit exampl", inserted: "e", completion: ".com"),
            (source: "Contact use", inserted: "r", completion: "@example.com"),
        ]

        for testCase in cases {
            let box = EditorTextBox(testCase.source)
            let prose = FlowProseCompletionSpy(result: testCase.completion)
            let coordinator = makeCoordinator(box, proseCompletion: prose.service)
            let (window, scrollView, textView) = makeHostedTextView(
                coordinator: coordinator,
                text: testCase.source
            )
            let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
            XCTAssertTrue(rangesReady)

            textView.insertText(testCase.inserted, replacementRange: textView.selectedRange())
            let requestFinished = await waitUntil {
                prose.requestCount == 1
                    && textView.inlinePredictionType == .default
                    && textView.flowProseSuggestion == nil
            }

            XCTAssertTrue(requestFinished, "Unsafe completion was not rejected: \(testCase.completion)")
            XCTAssertNil(textView.flowProseSuggestion)
            XCTAssertEqual(textView.string, testCase.source + testCase.inserted)
            XCTAssertEqual(box.value, testCase.source + testCase.inserted)
            XCTAssertTrue((textView.accessibilityCustomActions() ?? []).isEmpty)
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
    }

    func testVisibleCorrectionWinsOverPendingOnDeviceCompletion() async {
        let source = "teh draft"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(
            result: "with a polished ending.",
            delayNanoseconds: 700_000_000
        )
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: checker.client,
            proseCompletion: prose.service
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(
            coordinator,
            textView: textView,
            checksSpelling: true
        )
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        textView.flowProseSuggestion = EditorFlowProseSuggestion(
            documentID: "note.md",
            revision: coordinator.revision,
            sourceUTF16Length: (textView.string as NSString).length,
            selectedRange: textView.selectedRange(),
            continuation: " A polished ending."
        )
        XCTAssertNotNil(textView.flowProseSuggestion)
        let correctionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(correctionReady)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        try? await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertNotNil(textView.flowSuggestion)
    }

    func testNarrowViewportStoresAndAcceptsOnlyFittedCompletionPrefix() async throws {
        let source = "We can write"
        let fullCompletion = "one two three four five six seven eight nine ten"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: fullCompletion)
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 320, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        let visiblePrefix = try XCTUnwrap(textView.flowProseSuggestion?.continuation)
        XCTAssertTrue(fullCompletion.hasPrefix(visiblePrefix))
        XCTAssertLessThan(visiblePrefix.count, fullCompletion.count)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write " + visiblePrefix)
        XCTAssertFalse(textView.string.contains("ten"))
    }

    func testCompletionCannotBeAcceptedAfterCaretScrollsOffscreen() async throws {
        let source = (0..<60).map { "Context line \($0)" }.joined(separator: "\n")
            + "\nWe can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "with confidence.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: 1_600)
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowProseSuggestion)
        XCTAssertEqual(
            textView.visibleFlowProseContinuation(
                suggestion.continuation,
                atUTF16Offset: suggestion.caretUTF16Offset
            ),
            suggestion.continuation
        )

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let completionCleared = await waitUntil { textView.flowProseSuggestion == nil }
        XCTAssertTrue(completionCleared)
        XCTAssertEqual(textView.inlinePredictionType, .default)
        XCTAssertTrue((textView.accessibilityCustomActions() ?? []).isEmpty)
        XCTAssertFalse(coordinator.acceptFlowProseSuggestion(suggestion, nextWordOnly: false))
        XCTAssertEqual(textView.string, source + " ")
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testResizeAfterVisibleCustomCompletionCancelsGhostAndRestoresNativePrediction() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "with confidence.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowProseSuggestion)
        XCTAssertEqual(
            textView.visibleFlowProseContinuation(
                suggestion.continuation,
                atUTF16Offset: suggestion.caretUTF16Offset
            ),
            suggestion.continuation
        )
        await renderFlowSuggestion(in: textView, window: window)

        window.setContentSize(NSSize(width: 150, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        textView.refreshContentWidthLayout()

        let completionCancelled = await waitUntil {
            textView.flowProseSuggestion == nil && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(completionCancelled)
        XCTAssertEqual(textView.string, source + " ")
        XCTAssertEqual(box.value, source + " ")
        XCTAssertTrue((textView.accessibilityCustomActions() ?? []).isEmpty)
    }

    func testContentWidthChangeInvalidatesRenderedRepairUntilRepaint() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        textView.contentWidthPercent = 64
        XCTAssertFalse(textView.canDirectlyAcceptFlowSuggestion(suggestion))
        XCTAssertFalse(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowSuggestion, suggestion)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)

        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the.")
        XCTAssertEqual(box.value, "the.")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testFontChangeInvalidatesRenderedRepairUntilRepaint() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        textView.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        textView.invalidateFlowPresentationForGeometryChange()
        XCTAssertFalse(textView.canDirectlyAcceptFlowSuggestion(suggestion))
        XCTAssertFalse(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowSuggestion, suggestion)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)

        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the.")
        XCTAssertEqual(box.value, "the.")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testFontChangeCancelsProseGhostThatNoLongerFits() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "with confidence and precision.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowProseSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowProseSuggestion)
        XCTAssertEqual(
            textView.visibleFlowProseContinuation(
                suggestion.continuation,
                atUTF16Offset: suggestion.caretUTF16Offset
            ),
            suggestion.continuation
        )
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))

        textView.font = .monospacedSystemFont(ofSize: 36, weight: .regular)
        textView.invalidateFlowPresentationForGeometryChange()

        let completionCancelled = await waitUntil {
            textView.flowProseSuggestion == nil && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(completionCancelled)
        XCTAssertEqual(textView.string, source + " ")
        XCTAssertEqual(box.value, source + " ")
        XCTAssertTrue((textView.accessibilityCustomActions() ?? []).isEmpty)
    }

    func testMasterInlinePreferenceDisablesOnDeviceCompletion() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let coordinator = makeCoordinator(box, proseCompletion: prose.service)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(
            coordinator,
            textView: textView,
            inlinePredictions: false
        )
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testInlinePredictionsStayDisabledInProtectedMarkdownRanges() async {
        let source = "Prose words.\n`code value`\nhttps://example.com/path\nPlain"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
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
        textView.insertText("x", replacementRange: textView.selectedRange())
        let cleanGateReady = await waitUntil { textView.inlinePredictionType == .default }
        XCTAssertTrue(cleanGateReady)

        let proseRange = (source as NSString).range(of: "Prose words")
        textView.setSelectedRange(NSRange(location: NSMaxRange(proseRange), length: 0))
        let prosePredictionReady = await waitUntil {
            textView.inlinePredictionType == .default
        }
        XCTAssertTrue(prosePredictionReady)

        let codeRange = (source as NSString).range(of: "code value")
        textView.setSelectedRange(NSRange(location: codeRange.location + 2, length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)

        let urlRange = (source as NSString).range(of: "example.com")
        textView.setSelectedRange(NSRange(location: urlRange.location + 2, length: 0))
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)
    }

    func testNativeSpellingAndGrammarIndicatorsSkipCachedMarkdownCodeAndLinks() async {
        let source = "teh prose `teh code` [guide](GuideTeh.md) tail"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        let proseRange = (source as NSString).range(of: "teh prose")
        let proseTypoRange = NSRange(location: proseRange.location, length: 3)
        let codeRange = (source as NSString).range(of: "teh code")
        let codeEdgeIntersection = NSRange(location: codeRange.location - 1, length: 2)
        let linkDestinationRange = (source as NSString).range(of: "GuideTeh.md")
        let states = [
            NSAttributedString.SpellingState.spelling.rawValue,
            NSAttributedString.SpellingState.grammar.rawValue,
        ]

        for state in states {
            XCTAssertEqual(
                coordinator.textView(
                    textView,
                    shouldSetSpellingState: state,
                    range: proseTypoRange
                ),
                state
            )
            for protectedRange in [codeRange, codeEdgeIntersection, linkDestinationRange] {
                XCTAssertEqual(
                    coordinator.textView(
                        textView,
                        shouldSetSpellingState: state,
                        range: protectedRange
                    ),
                    0
                )
            }
        }
        XCTAssertTrue(coordinator.nativeTextCheckingAllows(proseTypoRange))
        XCTAssertFalse(coordinator.nativeTextCheckingAllows(codeRange))
        XCTAssertFalse(coordinator.nativeTextCheckingAllows(linkDestinationRange))

        let protectedMenu = NSMenu()
        for (title, action) in [
            ("the", "changeSpelling:"),
            ("Ignore", "ignoreSpelling:"),
            ("Learn", "learnWord:"),
        ] {
            protectedMenu.addItem(NSMenuItem(
                title: title,
                action: NSSelectorFromString(action),
                keyEquivalent: ""
            ))
        }
        protectedMenu.addItem(.separator())
        protectedMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: ""
        ))
        let spellingSubmenu = NSMenu(title: "Spelling and Grammar")
        spellingSubmenu.addItem(NSMenuItem(
            title: "Show Spelling and Grammar",
            action: NSSelectorFromString("showGuessPanel:"),
            keyEquivalent: ""
        ))
        spellingSubmenu.addItem(NSMenuItem(
            title: "Check Spelling",
            action: NSSelectorFromString("checkSpelling:"),
            keyEquivalent: ""
        ))
        let spellingParent = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        spellingParent.submenu = spellingSubmenu
        protectedMenu.addItem(spellingParent)
        MarkdownNSTextView.removeNativeSpellingItems(from: protectedMenu)
        XCTAssertEqual(protectedMenu.items.map(\.title), ["Copy"])

        let excludedTypes = NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.grammar.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
        var codeCheckingTypes = excludedTypes
        _ = coordinator.textView(
            textView,
            willCheckTextIn: codeRange,
            options: [:],
            types: &codeCheckingTypes
        )
        XCTAssertEqual(codeCheckingTypes & excludedTypes, 0)

        let sourceRange = NSRange(location: 0, length: (source as NSString).length)
        var mixedCheckingTypes = excludedTypes
        _ = coordinator.textView(
            textView,
            willCheckTextIn: sourceRange,
            options: [:],
            types: &mixedCheckingTypes
        )
        XCTAssertEqual(mixedCheckingTypes & excludedTypes, excludedTypes)

        let checkedRange = NSRange(location: 4, length: sourceRange.length - 4)
        let tailRange = (source as NSString).range(of: "tail")
        let orthography = NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["en"]]
        )
        let filteredResults = coordinator.textView(
            textView,
            didCheckTextIn: checkedRange,
            types: excludedTypes,
            options: [:],
            results: [
                NSTextCheckingResult.orthographyCheckingResult(
                    range: codeRange,
                    orthography: orthography
                ),
                NSTextCheckingResult.spellCheckingResult(range: codeRange),
                NSTextCheckingResult.spellCheckingResult(range: linkDestinationRange),
                NSTextCheckingResult.spellCheckingResult(range: tailRange),
            ],
            orthography: orthography,
            wordCount: 3
        )
        XCTAssertEqual(filteredResults.map(\.resultType), [.orthography, .spelling])
        XCTAssertEqual(filteredResults.map(\.range), [codeRange, tailRange])

        coordinator.externalTextDidChange()
        var unavailableCheckingTypes = excludedTypes
        _ = coordinator.textView(
            textView,
            willCheckTextIn: proseTypoRange,
            options: [:],
            types: &unavailableCheckingTypes
        )
        XCTAssertEqual(unavailableCheckingTypes & excludedTypes, 0)

        coordinator.configureFlow(mode: nil, options: .defaultValue)
        XCTAssertEqual(
            coordinator.textView(
                textView,
                shouldSetSpellingState: NSAttributedString.SpellingState.spelling.rawValue,
                range: proseTypoRange
            ),
            0
        )
    }

    func testProtectedRangePublishClearsStaleNativeStateBeforeBoundedRecheck() async throws {
        let source = "teh prose `teh code` tail"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let recordingTextView = NativeCheckingRecordingTextView()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: recordingTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let protectedRanges = FlowProtectedRangeService().protectedRanges(
            in: source,
            mode: .markdown
        )
        XCTAssertFalse(protectedRanges.isEmpty)
        for range in protectedRanges {
            recordingTextView.setSpellingState(
                NSAttributedString.SpellingState.spelling.rawValue,
                range: range
            )
        }
        recordingTextView.nativeCheckingEvents.removeAll()

        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let publishFinished = await waitUntil {
            textView.flowWritingToolsReady
                && recordingTextView.nativeCheckingEvents.contains { event in
                    if case .check = event { return true }
                    return false
                }
        }
        XCTAssertTrue(publishFinished)

        let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
            in: source,
            selectedRange: textView.selectedRange()
        ))
        let clearIndices = recordingTextView.nativeCheckingEvents.indices.filter { index in
            if case .clear = recordingTextView.nativeCheckingEvents[index] { return true }
            return false
        }
        let checkIndex = try XCTUnwrap(recordingTextView.nativeCheckingEvents.firstIndex { event in
            if case .check = event { return true }
            return false
        })
        XCTAssertFalse(clearIndices.isEmpty)
        XCTAssertTrue(clearIndices.allSatisfy { $0 < checkIndex })
        XCTAssertEqual(
            recordingTextView.nativeCheckingEvents.compactMap { event -> NSRange? in
                guard case let .clear(range) = event else { return nil }
                return range
            },
            protectedRanges
        )
        guard case let .check(range, types) = recordingTextView.nativeCheckingEvents[checkIndex] else {
            return XCTFail("Expected a bounded native text-checking request")
        }
        XCTAssertEqual(range, plan.range)
        XCTAssertNotEqual(types & NSTextCheckingResult.CheckingType.spelling.rawValue, 0)
        XCTAssertNotEqual(types & NSTextCheckingResult.CheckingType.grammar.rawValue, 0)
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
            },
            flowFocusValidator: { _ in true }
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

    func testInlinePredictionsStayDisabledWhileRepairCheckIsPendingThenReleaseWhenClean() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: .max)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            },
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
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
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.insertText("a", replacementRange: textView.selectedRange())
        let cleanGateReady = await waitUntil {
            textView.flowWritingToolsReady && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(cleanGateReady)

        provider.blockNextCall()
        textView.insertText("1", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady
                && provider.activeCallCount == 0
                && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .default)
    }

    func testInlinePredictionsFailClosedWhenFourthLeadingSpaceFormsIndentedCode() async {
        let source = "   x"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            },
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
        XCTAssertEqual(textView.inlinePredictionType, .no)

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
        XCTAssertEqual(textView.inlinePredictionType, .no)

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
        XCTAssertEqual(textView.inlinePredictionType, .no)

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

    func testPendingProseEditSuppressesInlinePredictionsUntilCleanCheckFinishes() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
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
        XCTAssertEqual(textView.inlinePredictionType, .no)
        textView.insertText("x", replacementRange: textView.selectedRange())
        let cleanGateReady = await waitUntil { textView.inlinePredictionType == .default }
        XCTAssertTrue(cleanGateReady)

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

        XCTAssertEqual(textView.inlinePredictionType, .no)
        textView.didChangeText()
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let cleanCheckFinished = await waitUntil {
            textView.flowWritingToolsReady && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(cleanCheckFinished)
    }

    func testInlinePredictionsFailClosedForPunctuationUntilRangeScanFinishes() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            },
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
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
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.insertText(".", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .no)
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady
                && provider.activeCallCount == 0
                && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(currentScanFinished)
        XCTAssertEqual(textView.inlinePredictionType, .default)
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

    func testLowercaseTypoAfterPunctuationChecksFullFoundationRangeWithoutPartialRepair() async throws {
        let source = "Ths is good. teh"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        let aiRequestCount = EditorIntBox()
        var checkedTexts: [String] = []
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                aiRequestCount.value += 1
                return "This is good. the."
            }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                checkedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let firstTypo = checkedSource.range(of: "Ths")
                let secondTypo = checkedSource.range(of: "teh")
                guard firstTypo.location != NSNotFound,
                      secondTypo.location != NSNotFound
                else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: firstTypo,
                        replacementString: "This"
                    ),
                    NSTextCheckingResult.correctionCheckingResult(
                        range: secondTypo,
                        replacementString: "the"
                    ),
                ], nil)
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { checkedTexts.last == completedSource }
        XCTAssertTrue(checkerFinished)
        let partialRepairAppeared = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }
        let fullRange = NSRange(location: 0, length: (completedSource as NSString).length)
        let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
            in: completedSource,
            selectedRange: NSRange(location: fullRange.length, length: 0)
        ))

        XCTAssertEqual(checkedTexts.last, completedSource)
        XCTAssertEqual(plan.range, fullRange)
        XCTAssertFalse(plan.isBatchSafe)
        XCTAssertFalse(plan.offersSentenceBatch)
        XCTAssertFalse(partialRepairAppeared)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(aiRequestCount.value, 0, "A non-batch check must exit before AI fallback")
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(box.value, completedSource)
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

    func testPendingSentenceRepairBlocksCustomAndNativeAutocompleteUntilCleanResult() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let requestBox = FlowCheckingRequestBox()
        let prose = FlowProseCompletionSpy(result: nil)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                requestBox.capture(completion)
            },
            proseCompletion: prose.service
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let rangesReady = await prepareProseCompletion(
            coordinator,
            textView: textView,
            checksSpelling: true
        )
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        let repairCheckStarted = await waitUntil { requestBox.completion != nil }
        XCTAssertTrue(repairCheckStarted)
        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        try XCTUnwrap(requestBox.completion)([], nil)
        let autocompleteReleased = await waitUntil {
            textView.inlinePredictionType == .default && prose.requestCount == 1
        }
        XCTAssertTrue(autocompleteReleased)
        XCTAssertEqual(prose.requestCount, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertNil(textView.flowProseSuggestion)
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
        let spelling = NSTextCheckingResult.spellCheckingResult(range: spellingRange)
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
            results: [spelling, grammar],
            orthography: nil,
            spellingCorrection: { range, _ in range == spellingRange ? "the" : nil }
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

    func testCorrectionResolverBoundsSynchronousSpellingLookupsAtEight() {
        let words = ["aaa", "bbb", "ccc", "ddd", "eee", "fff", "ggg", "hhh", "iii"]
        let source = words.joined(separator: " ")
        let sourceValue = source as NSString
        let spellingResults = words.map {
            NSTextCheckingResult.spellCheckingResult(range: sourceValue.range(of: $0))
        }
        let boundedLookupCount = EditorIntBox()

        let bounded = EditorFlowCorrectionResolver.concreteCorrections(
            in: source,
            caretUTF16Offset: sourceValue.length,
            results: Array(spellingResults.prefix(8)),
            orthography: nil,
            spellingCorrection: { range, _ in
                boundedLookupCount.value += 1
                return sourceValue.substring(with: range).uppercased()
            }
        )

        XCTAssertEqual(boundedLookupCount.value, 8)
        XCTAssertEqual(bounded.count, 8)

        let overLimitLookupCount = EditorIntBox()
        let overLimit = EditorFlowCorrectionResolver.concreteCorrections(
            in: source,
            caretUTF16Offset: sourceValue.length,
            results: spellingResults,
            orthography: nil,
            spellingCorrection: { range, _ in
                overLimitLookupCount.value += 1
                return sourceValue.substring(with: range).uppercased()
            }
        )

        XCTAssertEqual(overLimitLookupCount.value, 0)
        XCTAssertTrue(overLimit.isEmpty)
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
            results: [result],
            orthography: nil,
            spellingCorrection: { _, _ in nil }
        ).isEmpty)
    }

    func testAISentenceRepairValidatorAcceptsTypoButRejectsContentWordSubstitution() throws {
        let typoSource = "I am writng clearly."
        let typoRange = (typoSource as NSString).range(of: "writng")
        let typoEdits = try XCTUnwrap(EditorFlowSentenceRepairValidator.edits(
            originalSentence: typoSource,
            candidateSentence: "I am writing clearly.",
            issueRanges: [typoRange]
        ))
        XCTAssertEqual(typoEdits.count, 1)
        XCTAssertEqual(typoEdits.first?.originalText, "writng")
        XCTAssertEqual(typoEdits.first?.replacementText, "writing")

        let unsafeSource = "I saw a dag outside."
        let unsafeRange = (unsafeSource as NSString).range(of: "dag")
        XCTAssertNil(EditorFlowSentenceRepairValidator.edits(
            originalSentence: unsafeSource,
            candidateSentence: "I saw a cat outside.",
            issueRanges: [unsafeRange]
        ))
    }

    func testAISentenceRepairValidatorRejectsChangedTerminalIntent() {
        for (original, candidate, issue) in [
            ("teh?", "the!!!", "teh"),
            ("teh.", "the!", "teh"),
            ("This is gud today.", "This is good. today", "gud"),
        ] {
            let issueRange = (original as NSString).range(of: issue)
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.edits(
                    originalSentence: original,
                    candidateSentence: candidate,
                    issueRanges: [issueRange]
                ),
                "AI repair must preserve the user's terminal punctuation intent: \(original)"
            )
        }
    }

    func testAISentenceRepairValidatorRejectsNamesAndCasePatternChanges() {
        for (original, candidate, issue) in [
            ("iPhone works.", "Iphone works.", "iPhone"),
            ("mONknot works.", "Monknot works.", "mONknot"),
            ("Alice works.", "Alyce works.", "Alice"),
        ] {
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.edits(
                    originalSentence: original,
                    candidateSentence: candidate,
                    issueRanges: [(original as NSString).range(of: issue)]
                ),
                "AI repair must preserve names and the user's letter-case pattern: \(original)"
            )
        }
    }

    func testSentenceRepairServicePreservesLeadingIndentation() async throws {
        let original = "    teh."
        let request = try XCTUnwrap(FlowSentenceRepairRequest(
            sentence: original,
            locale: Locale(identifier: "en_US")
        ))
        let service = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in "the." }
        )

        let repaired = await service.repair(for: request)

        XCTAssertEqual(repaired, "    the.")
    }

    func testAISentenceRepairFallbackShowsValidatedFullPreviewAndAppliesAtomically() async throws {
        let source = "I am writng clearly"
        let corrected = "I am writing clearly."
        let box = EditorTextBox(source)
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in corrected }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == corrected {
                    completion([], self.englishOrthography())
                    return
                }
                let issueRange = (checkedText as NSString).range(of: "writng")
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: issueRange,
                        replacementString: ""
                    ),
                ], nil)
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion?.source == .ai }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.headerText, "AI repair")
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "I am writng clearly.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, corrected)
        XCTAssertTrue(textView.flowSuggestion?.accessibilityText.contains(
            "replace “writng” with “writing”"
        ) == true)
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))
        textView.undoManager?.removeAllActions()

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
    }

    func testAISentenceRepairFallbackRejectsUnsafeContentWordChange() async {
        let source = "I saw a dag outside"
        let box = EditorTextBox(source)
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in "I saw a cat outside." }
        )
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let issueRange = (checkedText as NSString).range(of: "dag")
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: issueRange,
                        replacementString: ""
                    ),
                ], nil)
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { requestCount.value == 1 }
        XCTAssertTrue(checkerFinished)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
        XCTAssertEqual(requestCount.value, 1, "Unsafe AI text must not reach post-validation")
    }

    func testDismissedAIRepairDoesNotReappearForSameSentenceOnRecheck() async throws {
        let source = "I am writng clearly"
        let completedSource = source + "."
        let corrected = "I am writing clearly."
        let box = EditorTextBox(source)
        let aiRequestCount = EditorIntBox()
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                aiRequestCount.value += 1
                return corrected
            }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == corrected {
                    completion([], self.englishOrthography())
                    return
                }
                let issueRange = (checkedText as NSString).range(of: "writng")
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: issueRange,
                        replacementString: ""
                    ),
                ], self.englishOrthography())
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let firstRepairReady = await waitUntil { textView.flowSuggestion?.source == .ai }
        XCTAssertTrue(firstRepairReady)
        XCTAssertEqual(aiRequestCount.value, 1)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completedSource)

        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let secondAIRequestFinished = await waitUntil { aiRequestCount.value >= 2 }
        XCTAssertTrue(secondAIRequestFinished)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(box.value, completedSource)
    }

    func testFlowSuggestionRejectsEveryStaleIdentityDimension() {
        let source = "Fix teh "
        let checkedRange = (source as NSString).range(of: "teh")
        let selection = NSRange(location: (source as NSString).length, length: 0)
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 4,
            selectedRange: selection,
            caretUTF16Offset: selection.location,
            sentenceRange: NSRange(location: 0, length: (source as NSString).length),
            originalSentence: source,
            correctedSentence: "Fix the ",
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: checkedRange,
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            )]
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

    func testFlowSuggestionCueTruthfullyDescribesSingleAndBatchReplacements() {
        let singleOriginal = "teh."
        let singleCorrected = "the."
        let single = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: 4, length: 0),
            caretUTF16Offset: 4,
            sentenceRange: NSRange(location: 0, length: 4),
            originalSentence: singleOriginal,
            correctedSentence: singleCorrected,
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: NSRange(location: 0, length: 3),
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            )]
        )

        XCTAssertEqual(single.headerText, "Fix 1 issue")
        XCTAssertEqual(single.originalSentence, singleOriginal)
        XCTAssertEqual(single.correctedSentence, singleCorrected)
        XCTAssertEqual(single.originalChangedRanges, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(single.correctedChangedRanges, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(
            single.accessibilityText,
            "Fix 1 issue. Original: teh.\nCorrected: the.\nChanges: replace “teh” with “the”. "
                + "Tab applies all changes. Escape dismisses. Option-Return reviews."
        )

        let batchOriginal = "teh cats is ready."
        let batchCorrected = "the cats are ready."
        let batch = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 2,
            selectedRange: NSRange(location: 18, length: 0),
            caretUTF16Offset: 18,
            sentenceRange: NSRange(location: 0, length: 18),
            originalSentence: batchOriginal,
            correctedSentence: batchCorrected,
            source: .deterministic,
            edits: [
                EditorFlowCorrectionEdit(
                    range: NSRange(location: 0, length: 3),
                    originalText: "teh",
                    replacementText: "the",
                    kind: .spelling
                ),
                EditorFlowCorrectionEdit(
                    range: NSRange(location: 9, length: 2),
                    originalText: "is",
                    replacementText: "are",
                    kind: .grammar
                ),
            ]
        )

        XCTAssertEqual(batch.headerText, "Fix 2 issues")
        XCTAssertEqual(batch.originalSentence, batchOriginal)
        XCTAssertEqual(batch.correctedSentence, batchCorrected)
        XCTAssertEqual(batch.exactChangeDescription, "replace “teh” with “the”, replace “is” with “are”")
        XCTAssertEqual(
            batch.accessibilityText,
            "Fix 2 issues. Original: teh cats is ready.\nCorrected: the cats are ready.\n"
                + "Changes: replace “teh” with “the”, replace “is” with “are”. "
                + "Tab applies all changes. Escape dismisses. Option-Return reviews."
        )
    }

    func testBroadGrammarReplacementDisplaysAndDescribesOnlyChangedWord() {
        let original = "The dogs is ready."
        let corrected = "The dogs are ready."
        let sentenceRange = NSRange(location: 0, length: (original as NSString).length)
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: sentenceRange.length, length: 0),
            caretUTF16Offset: sentenceRange.length,
            sentenceRange: sentenceRange,
            originalSentence: original,
            correctedSentence: corrected,
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: (original as NSString).range(of: "dogs is"),
                originalText: "dogs is",
                replacementText: "dogs are",
                kind: .grammar
            )]
        )

        XCTAssertEqual(suggestion.originalChangedRanges, [
            (original as NSString).range(of: "is"),
        ])
        XCTAssertEqual(suggestion.correctedChangedRanges, [
            (corrected as NSString).range(of: "are"),
        ])
        XCTAssertEqual(suggestion.displayChanges.map(\.originalText), ["is"])
        XCTAssertEqual(suggestion.displayChanges.map(\.replacementText), ["are"])
        XCTAssertEqual(suggestion.exactChangeDescription, "replace “is” with “are”")
        XCTAssertFalse(suggestion.exactChangeDescription.contains("dogs"))
    }

    func testWordEdgeInflectionDisplaysAndAnnouncesWholeWords() {
        let original = "The cat sleeps."
        let corrected = "The cats sleep."
        let sentenceRange = NSRange(location: 0, length: (original as NSString).length)
        let catRange = (original as NSString).range(of: "cat")
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: sentenceRange.length, length: 0),
            caretUTF16Offset: sentenceRange.length,
            sentenceRange: sentenceRange,
            originalSentence: original,
            correctedSentence: corrected,
            source: .deterministic,
            edits: [
                EditorFlowCorrectionEdit(
                    range: catRange,
                    originalText: "cat",
                    replacementText: "cats",
                    kind: .grammar
                ),
                EditorFlowCorrectionEdit(
                    range: (original as NSString).range(of: "sleeps"),
                    originalText: "sleeps",
                    replacementText: "sleep",
                    kind: .grammar
                ),
            ]
        )

        XCTAssertEqual(suggestion.displayChanges.first?.originalText, "cat")
        XCTAssertEqual(suggestion.displayChanges.first?.replacementText, "cats")
        XCTAssertTrue(suggestion.exactChangeDescription.contains("replace “cat” with “cats”"))
        XCTAssertTrue(suggestion.accessibilityText.contains("replace “cat” with “cats”"))
        XCTAssertFalse(suggestion.exactChangeDescription.contains("replace “” with “s”"))
    }

    func testFlowCueLayoutShowsCompleteSentencesOrRequiresReviewAndScalesGeometry() throws {
        let original = "abcdefghijklmnopqrstuvwx zyxwvutsrqponmlkjihgfe"
        let corrected = "ABCDEFGHIJKLMNOPQRSTUVWX ZYXWVUTSRQPONMLKJIHGFE"
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: 50, length: 0),
            caretUTF16Offset: 50,
            sentenceRange: NSRange(location: 0, length: (original as NSString).length),
            originalSentence: original,
            correctedSentence: corrected,
            source: .deterministic,
            edits: [
                EditorFlowCorrectionEdit(
                    range: NSRange(location: 0, length: 24),
                    originalText: "abcdefghijklmnopqrstuvwx",
                    replacementText: "ABCDEFGHIJKLMNOPQRSTUVWX",
                    kind: .spelling
                ),
                EditorFlowCorrectionEdit(
                    range: NSRange(location: 25, length: 24),
                    originalText: "zyxwvutsrqponmlkjihgfe",
                    replacementText: "ZYXWVUTSRQPONMLKJIHGFE",
                    kind: .grammar
                ),
            ]
        )
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let wide = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 1_000,
            availableHeight: 600,
            editorFont: font,
            zoomScale: 1
        )
        XCTAssertEqual(wide.mode, .direct)
        XCTAssertNil(wide.reviewText)
        XCTAssertGreaterThan(wide.originalRowHeight, 0)
        XCTAssertGreaterThan(wide.correctedRowHeight, 0)
        XCTAssertGreaterThan(wide.headerHeight, 0)
        XCTAssertGreaterThan(wide.footerHeight, 0)

        let review = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 100,
            availableHeight: 100,
            editorFont: font,
            zoomScale: 1
        )
        XCTAssertEqual(review.mode, .review)
        XCTAssertTrue(review.reviewText?.hasPrefix("Fix") == true)
        XCTAssertEqual(review.originalRowHeight, 0)
        XCTAssertEqual(review.correctedRowHeight, 0)

        let zoomed = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 2_000,
            availableHeight: 1_200,
            editorFont: font,
            zoomScale: 2
        )
        XCTAssertEqual(zoomed.headerHeight, 56)
        XCTAssertEqual(zoomed.footerHeight, 56)
        XCTAssertEqual(zoomed.cornerRadius, 24)

        let narrowZoomed = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 120,
            availableHeight: 100,
            editorFont: font,
            zoomScale: 2.5
        )
        XCTAssertEqual(narrowZoomed.mode, .review)
        XCTAssertLessThanOrEqual(narrowZoomed.size.width, 120)
        XCTAssertLessThanOrEqual(narrowZoomed.size.height, 100)
        XCTAssertGreaterThan(narrowZoomed.size.width, 0)
        XCTAssertGreaterThan(narrowZoomed.size.height, 0)
    }

    func testCompactReviewCuesRetainDeterministicAndAIProvenance() {
        let original = "The dogs is ready."
        let corrected = "The dogs are ready."
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
                edits: [EditorFlowCorrectionEdit(
                    range: (original as NSString).range(of: "is"),
                    originalText: "is",
                    replacementText: "are",
                    kind: .grammar
                )]
            )
        }
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let deterministic = EditorFlowCueLayout.make(
            for: suggestion(source: .deterministic),
            availableWidth: 180,
            availableHeight: 80,
            editorFont: font,
            zoomScale: 1
        )
        let ai = EditorFlowCueLayout.make(
            for: suggestion(source: .ai),
            availableWidth: 180,
            availableHeight: 80,
            editorFont: font,
            zoomScale: 1
        )

        XCTAssertEqual(deterministic.mode, .review)
        XCTAssertTrue(deterministic.reviewText?.hasPrefix("Fix") == true)
        XCTAssertEqual(ai.mode, .review)
        XCTAssertTrue(ai.reviewText?.hasPrefix("AI") == true)
    }

    func testFlowAccessibilityActionsNameEveryExactChangeWithoutTruncation() {
        let source = "abcdefghijklmnopqrstuvwx zyxwvutsrqponmlkjihgfe"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: (source as NSString).length),
            originalSentence: source,
            correctedSentence: "ABCDEFGHIJKLMNOPQRSTUVWX ZYXWVUTSRQPONMLKJIHGFE",
            source: .deterministic,
            edits: [
                EditorFlowCorrectionEdit(
                    range: (source as NSString).range(of: "abcdefghijklmnopqrstuvwx"),
                    originalText: "abcdefghijklmnopqrstuvwx",
                    replacementText: "ABCDEFGHIJKLMNOPQRSTUVWX",
                    kind: .spelling
                ),
                EditorFlowCorrectionEdit(
                    range: (source as NSString).range(of: "zyxwvutsrqponmlkjihgfe"),
                    originalText: "zyxwvutsrqponmlkjihgfe",
                    replacementText: "ZYXWVUTSRQPONMLKJIHGFE",
                    kind: .grammar
                ),
            ]
        )
        textView.flowSuggestion = suggestion

        let names = (textView.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains { $0.hasPrefix("Apply Fix 2 issues:") })
        XCTAssertTrue(names.contains { $0.hasPrefix("Dismiss correction:") })
        XCTAssertTrue(names.contains { $0.hasPrefix("Review correction:") })
        for name in names {
            XCTAssertTrue(name.contains("abcdefghijklmnopqrstuvwx"))
            XCTAssertTrue(name.contains("ABCDEFGHIJKLMNOPQRSTUVWX"))
            XCTAssertTrue(name.contains("zyxwvutsrqponmlkjihgfe"))
            XCTAssertTrue(name.contains("ZYXWVUTSRQPONMLKJIHGFE"))
            XCTAssertFalse(name.contains("…"))
        }
        XCTAssertEqual(textView.accessibilityHelp(), suggestion.accessibilityText)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Original: \(source)") == true)
        XCTAssertTrue(textView.accessibilityHelp()?.contains(
            "Corrected: ABCDEFGHIJKLMNOPQRSTUVWX ZYXWVUTSRQPONMLKJIHGFE"
        ) == true)
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

        textView.insertText(".", replacementRange: textView.selectedRange())
        await fulfillment(of: [checkerRequested], timeout: 2)
        let completion = try XCTUnwrap(requestBox.completion)
        XCTAssertNil(textView.flowSuggestion)

        textView.insertText("N", replacementRange: textView.selectedRange())
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
        XCTAssertEqual(textView.string, "teh.N")
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

        textView.insertText(".", replacementRange: textView.selectedRange())
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
        XCTAssertEqual(textView.flowSuggestion?.edits.first?.replacementText, "the")
        XCTAssertEqual(textView.string, "teh.")
    }

    func testFlowRetriesConcreteCorrectionAfterCurrentProtectedRangesFinish() async {
        let source = "teh"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let requestCount = EditorIntBox()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let typoRange = (checkedText as NSString).range(of: "teh")
                guard typoRange.location != NSNotFound else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: typoRange,
                        replacementString: "the"
                    ),
                ], nil)
            },
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let initialRangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialRangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let currentRefreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(currentRefreshBlocked)
        let firstCheckFinished = await waitUntil { requestCount.value == 1 }
        XCTAssertTrue(firstCheckFinished)
        XCTAssertNil(textView.flowSuggestion)

        provider.resumeBlockedCall()
        let retriedSuggestionReady = await waitUntil(timeout: 3) {
            requestCount.value == 2 && textView.flowSuggestion != nil
        }

        XCTAssertTrue(retriedSuggestionReady)
        XCTAssertEqual(textView.string, "teh.")
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["teh"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["the"])
    }

    func testCompletedListFlowSnapshotRetriesAfterCurrentProtectedRangesFinish() async throws {
        let source = "- teh"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let requestCount = EditorIntBox()
        var checkedTexts: [String] = []
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                checkedTexts.append(checkedText)
                let typoRange = (checkedText as NSString).range(of: "teh")
                guard typoRange.location != NSNotFound else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: typoRange,
                        replacementString: "the"
                    ),
                ], nil)
            },
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.markdownShortcutsEnabled = true
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let initialRangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialRangesReady)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "- teh\n- ")
        let currentRefreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(currentRefreshBlocked)
        let firstCheckFinished = await waitUntil { requestCount.value == 1 }
        XCTAssertTrue(firstCheckFinished)
        XCTAssertNil(textView.flowSuggestion)

        provider.resumeBlockedCall()
        let retriedSuggestionReady = await waitUntil(timeout: 3) {
            requestCount.value == 2 && textView.flowSuggestion != nil
        }

        XCTAssertTrue(retriedSuggestionReady)
        XCTAssertEqual(checkedTexts, ["- teh", "- teh"])
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.range),
            [(textView.string as NSString).range(of: "teh")]
        )
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “teh” with “the”"
        )
    }

    func testFlowCheckerSendsBoundedCurrentSentenceAndTranslatesLocalOffsets() async {
        let earlierContext = String(repeating: "Earlier context sentence. ", count: 220) + "\n"
        let currentSentence = "teh cats is ready"
        let source = earlierContext + currentSentence
        let box = EditorTextBox(source)
        var capturedText: String?
        var capturedRange: NSRange?
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, range, _, _, completion in
                capturedText = checkedText
                capturedRange = range
                let localRange = (checkedText as NSString).range(of: "teh")
                guard localRange.location != NSNotFound else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: localRange,
                        replacementString: "the"
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)

        let checkedText = capturedText ?? ""
        XCTAssertEqual(checkedText, currentSentence + ".")
        XCTAssertLessThanOrEqual((checkedText as NSString).length, 900)
        XCTAssertEqual(
            capturedRange,
            NSRange(location: 0, length: (checkedText as NSString).length)
        )
        let absoluteRange = (textView.string as NSString).range(of: "teh", options: .backwards)
        XCTAssertEqual(textView.flowSuggestion?.edits.first?.range, absoluteRange)
        XCTAssertEqual(textView.flowSuggestion?.edits.first?.originalText, "teh")
        XCTAssertEqual(textView.flowSuggestion?.edits.first?.replacementText, "the")
    }

    func testOverlongRunOnNeverOffersBatchOrAIAtPunctuationOrReturn() async {
        let source = String(repeating: "word ", count: 190) + "teh"
        XCTAssertGreaterThan((source as NSString).length, 900)

        for usesReturn in [false, true] {
            let box = EditorTextBox(source)
            let checkerCount = EditorIntBox()
            let aiCount = EditorIntBox()
            var checkedTexts: [String] = []
            let sentenceRepair = FlowSentenceRepairService(
                isAvailable: { _ in true },
                client: { _, _ in
                    aiCount.value += 1
                    return "the."
                }
            )
            let coordinator = makeCoordinator(
                box,
                flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                    checkerCount.value += 1
                    checkedTexts.append(checkedText)
                    let typoRange = (checkedText as NSString).range(of: "teh")
                    guard typoRange.location != NSNotFound else {
                        completion([], self.englishOrthography())
                        return
                    }
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: typoRange,
                            replacementString: "the"
                        ),
                    ], self.englishOrthography())
                },
                sentenceRepair: sentenceRepair
            )
            let (window, scrollView, textView) = makeHostedTextView(
                coordinator: coordinator,
                text: source
            )
            let options = EditorTextCheckingOptions(
                checksSpelling: true,
                checksGrammar: true,
                inlinePredictions: false,
                onDeviceProseCompletions: true
            )
            textView.flowSourceMode = .markdown
            textView.applyTextChecking(options)
            coordinator.configureFlow(mode: .markdown, options: options)
            let rangesReady = await waitUntil { textView.flowWritingToolsReady }
            XCTAssertTrue(rangesReady)

            if usesReturn {
                guard let event = keyEvent(
                    characters: "\r",
                    modifiers: [],
                    keyCode: 36,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Expected a Return key event")
                    dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
                    continue
                }
                textView.keyDown(with: event)
            } else {
                textView.insertText(".", replacementRange: textView.selectedRange())
            }

            let checkerFinished = await waitUntil { checkerCount.value > 0 }
            XCTAssertTrue(checkerFinished)
            XCTAssertTrue(checkedTexts.allSatisfy { ($0 as NSString).length <= 900 })
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(textView.flowSuggestion)
            XCTAssertEqual(aiCount.value, 0)
            XCTAssertEqual(textView.string, source + (usesReturn ? "\n" : "."))
            XCTAssertEqual(box.value, textView.string)
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
    }

    func testCleanTruncatedCurrentSentenceKeepsRepairAndAutocompleteBlocked() async {
        let source = String(repeating: "word ", count: 190) + "tai"
        XCTAssertGreaterThan((source as NSString).length, 900)
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "with an unsafe continuation.")
        let checkerCount = EditorIntBox()
        var checkedText = ""
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { text, _, _, _, completion in
                checkerCount.value += 1
                checkedText = text
                completion([], self.englishOrthography())
            },
            proseCompletion: prose.service
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText("l", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { checkerCount.value == 1 }
        XCTAssertTrue(checkerFinished)
        let plan = EditorFlowCheckPlanner.plan(
            in: textView.string,
            selectedRange: textView.selectedRange()
        )
        XCTAssertFalse(plan?.coversWholeCurrentSentence == true)
        XCTAssertLessThanOrEqual((checkedText as NSString).length, 900)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(checkerCount.value, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertEqual(textView.string, source + "l")
        XCTAssertEqual(box.value, source + "l")
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

        textView.insertText(".", replacementRange: textView.selectedRange())
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
        XCTAssertEqual(textView.string, "teh `code.")
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

    func testVisibleFlowCorrectionKeepsPriorityOverMarkdownListIndentation() async throws {
        let source = "- teh "
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.markdownShortcutsEnabled = true
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(
                checksSpelling: false,
                checksGrammar: false,
                inlinePredictions: false
            )
        )
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        textView.undoManager?.removeAllActions()
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))

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

    func testDirectRepairTabBeforeFirstPaintDoesNotApply() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(textView.flowCueLayout(for: suggestion).mode, .direct)
        XCTAssertFalse(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, source + "\t")
        XCTAssertEqual(box.value, source + "\t")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertFalse(textView.string.contains("the."))
    }

    func testExplicitAccessibilityApplyCanAcceptDirectRepairBeforeFirstPaint() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.flowSuggestion = suggestion
        XCTAssertFalse(textView.canDirectlyAcceptFlowSuggestion(suggestion))
        let apply = try XCTUnwrap((textView.accessibilityCustomActions() ?? []).first {
            $0.name.hasPrefix("Apply Fix 1 issue:")
        })

        NSApp.activate(ignoringOtherApps: true)
        let appActivated = await waitUntil { NSApp.isActive }
        let applyHandler = try XCTUnwrap(apply.handler)
        guard appActivated else {
            XCTAssertFalse(applyHandler())
            XCTAssertEqual(textView.string, source)
            XCTAssertEqual(box.value, source)
            throw XCTSkip("The command-line XCTest host cannot become the active macOS application")
        }
        XCTAssertTrue(applyHandler())
        XCTAssertEqual(textView.string, "the.")
        XCTAssertEqual(box.value, "the.")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testRenderedDirectRepairCannotApplyAfterScrollingAnchorOffscreen() async throws {
        let prefix = (0..<80).map { "Context line \($0)" }.joined(separator: "\n")
        let source = prefix + "\nteh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: 2_200)
        let sentenceRange = (source as NSString).range(of: "teh.", options: .backwards)
        let selection = NSRange(location: NSMaxRange(sentenceRange), length: 0)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let editRange = (source as NSString).range(of: "teh", options: .backwards)
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: selection,
            caretUTF16Offset: selection.location,
            sentenceRange: sentenceRange,
            originalSentence: "teh.",
            correctedSentence: "the.",
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: editRange,
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            )]
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let repairCleared = await waitUntil { textView.flowSuggestion == nil }
        XCTAssertTrue(repairCleared)
        XCTAssertFalse(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, source + "\t")
        XCTAssertEqual(box.value, source + "\t")
        XCTAssertFalse(textView.string.hasSuffix("the.\t"))
    }

    func testNarrowFlowTabAndOptionReturnOpenReviewWithoutMutatingText() async throws {
        let first = "abcdefghijklmnopqrstuvwx"
        let second = "zyxwvutsrqponmlkjihgfe"
        let source = "\(first) \(second)"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 120, height: 260))
        scrollView.frame = window.contentView?.bounds ?? scrollView.frame
        textView.frame = scrollView.bounds
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: (source as NSString).length),
            originalSentence: source,
            correctedSentence: "\(first.uppercased()) \(second.uppercased())",
            source: .deterministic,
            edits: [
                EditorFlowCorrectionEdit(
                    range: (source as NSString).range(of: first),
                    originalText: first,
                    replacementText: first.uppercased(),
                    kind: .spelling
                ),
                EditorFlowCorrectionEdit(
                    range: (source as NSString).range(of: second),
                    originalText: second,
                    replacementText: second.uppercased(),
                    kind: .grammar
                ),
            ]
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(textView.flowCueLayout(for: suggestion).mode, .review)
        await renderFlowSuggestion(in: textView, window: window)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertTrue(textView.isFlowReviewPopoverShown)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)

        textView.flowSuggestion = nil
        window.makeFirstResponder(textView)
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [.option],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))

        XCTAssertTrue(textView.isFlowReviewPopoverShown)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testReviewReplaceAppliesExactlyOnceAfterFocusMovesToCancel() async throws {
        let source = "abcdefghijklmnopqrstuvwx"
        let corrected = source.uppercased()
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 120, height: 260))
        scrollView.frame = window.contentView?.bounds ?? scrollView.frame
        textView.frame = scrollView.bounds
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        let acceptanceCount = EditorIntBox()
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptanceCount.value += 1
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        let suggestion = EditorFlowSuggestion(
            documentID: try XCTUnwrap(coordinator.documentID),
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: (source as NSString).length),
            originalSentence: source,
            correctedSentence: corrected,
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: NSRange(location: 0, length: (source as NSString).length),
                originalText: source,
                replacementText: corrected,
                kind: .spelling
            )]
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(textView.flowCueLayout(for: suggestion).mode, .review)
        await renderFlowSuggestion(in: textView, window: window)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let reviewShown = await waitUntil { textView.isFlowReviewPopoverShown }
        XCTAssertTrue(reviewShown)
        await nextMainRunLoopTurn()

        let candidateWindows = NSApp.windows + (window.childWindows ?? [])
        let reviewWindow = try XCTUnwrap(candidateWindows.first { candidate in
            guard candidate !== window, let contentView = candidate.contentView else { return false }
            let buttons = descendantViews(in: contentView).compactMap { $0 as? NSButton }
            return buttons.contains { $0.title == "Replace" }
                && buttons.contains { $0.title == "Cancel" }
        })
        let buttons = descendantViews(in: try XCTUnwrap(reviewWindow.contentView))
            .compactMap { $0 as? NSButton }
        let replace = try XCTUnwrap(buttons.first { $0.title == "Replace" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        XCTAssertTrue(reviewWindow.makeFirstResponder(cancel))
        XCTAssertTrue(reviewWindow.firstResponder === cancel)

        NSApp.activate(ignoringOtherApps: true)
        let appActivated = await waitUntil { NSApp.isActive }
        guard appActivated else {
            replace.performClick(nil)
            XCTAssertEqual(acceptanceCount.value, 0)
            XCTAssertEqual(textView.string, source)
            XCTAssertEqual(box.value, source)
            XCTAssertTrue(textView.isFlowReviewPopoverShown)
            throw XCTSkip("The command-line XCTest host cannot become the active macOS application")
        }

        replace.performClick(nil)
        let applied = await waitUntil {
            acceptanceCount.value == 1
                && textView.string == corrected
                && !textView.isFlowReviewPopoverShown
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(box.value, corrected)
        XCTAssertNil(textView.flowSuggestion)

        replace.performClick(nil)
        await nextMainRunLoopTurn()
        XCTAssertEqual(acceptanceCount.value, 1)
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
    }

    func testLongReviewAtTwoTimesZoomIsScreenBoundedAndScrollable() async throws {
        let repeated = Array(
            repeating: "teh sentence has enough surrounding context to require careful review.",
            count: 24
        ).joined(separator: " ")
        let source = repeated
        let corrected = source.replacingOccurrences(of: "teh", with: "the")
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: 6_000)
        textView.zoomScale = 2
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        let sourceString = source as NSString
        var edits: [EditorFlowCorrectionEdit] = []
        var searchRange = NSRange(location: 0, length: sourceString.length)
        while searchRange.length > 0 {
            let range = sourceString.range(of: "teh", options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            edits.append(EditorFlowCorrectionEdit(
                range: range,
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            ))
            let next = NSMaxRange(range)
            searchRange = NSRange(location: next, length: sourceString.length - next)
        }
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: sourceString.length),
            originalSentence: source,
            correctedSentence: corrected,
            source: .deterministic,
            edits: edits
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(textView.flowCueLayout(for: suggestion).mode, .review)
        await renderFlowSuggestion(in: textView, window: window)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let reviewShown = await waitUntil { textView.isFlowReviewPopoverShown }
        XCTAssertTrue(reviewShown)
        await nextMainRunLoopTurn()

        let candidateWindows = NSApp.windows + (window.childWindows ?? [])
        let reviewWindow = try XCTUnwrap(candidateWindows.first { candidate in
            guard candidate !== window, let contentView = candidate.contentView else { return false }
            return descendantViews(in: contentView).contains { view in
                (view as? NSButton)?.title == "Replace"
            }
        })
        reviewWindow.contentView?.layoutSubtreeIfNeeded()
        let reviewViews = descendantViews(in: try XCTUnwrap(reviewWindow.contentView))
        let bodyScrollView = try XCTUnwrap(reviewViews.compactMap { $0 as? NSScrollView }.first {
            $0.hasVerticalScroller && $0.documentView != nil
        })
        bodyScrollView.layoutSubtreeIfNeeded()
        let documentHeight = try XCTUnwrap(bodyScrollView.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, bodyScrollView.contentView.bounds.height)

        let visibleFrame = reviewWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
        XCTAssertLessThanOrEqual(reviewWindow.frame.width, visibleFrame.width)
        XCTAssertLessThanOrEqual(reviewWindow.frame.height, visibleFrame.height)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testSentenceBoundaryFlowBatchTabAppliesAtomicallyThenUndoRedoRestoresExactText() async throws {
        let source = "teh cats is ready"
        let box = EditorTextBox(source)
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let checkedSource = checkedText as NSString
                let spellingRange = checkedSource.range(of: "teh")
                let grammarRange = checkedSource.range(of: "is")
                guard spellingRange.location != NSNotFound,
                      grammarRange.location != NSNotFound
                else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: spellingRange,
                        replacementString: "the"
                    ),
                    self.grammarResult(
                        in: checkedText,
                        target: "is",
                        corrections: ["are"]
                    ),
                ], nil)
            }
        )
        let recordingTextView = FlowChangeRecordingTextView()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: recordingTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let batchSuggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 2 }
        XCTAssertTrue(batchSuggestionReady)
        XCTAssertEqual(textView.flowCueLayout(for: try XCTUnwrap(textView.flowSuggestion)).mode, .direct)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(textView.flowSuggestion?.headerText, "Fix 2 issues")
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "teh cats is ready.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "the cats are ready.")
        XCTAssertEqual(textView.string, "teh cats is ready.")
        let preservedGapKey = NSAttributedString.Key("MonknotFlowPreservedGap")
        let preservedGapRange = (textView.string as NSString).range(of: "cats")
        textView.textStorage?.addAttribute(
            preservedGapKey,
            value: "preserved",
            range: preservedGapRange
        )
        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the cats are ready.")
        XCTAssertEqual(box.value, "the cats are ready.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)
        XCTAssertEqual(recordingTextView.approvedChanges.first?.range, NSRange(location: 0, length: 11))
        XCTAssertEqual(recordingTextView.approvedChanges.first?.replacement, "the cats are")
        XCTAssertEqual(
            textView.textStorage?.attribute(
                preservedGapKey,
                at: preservedGapRange.location,
                effectiveRange: nil
            ) as? String,
            "preserved"
        )
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 19, length: 0))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh cats is ready.")
        XCTAssertEqual(box.value, "teh cats is ready.")
        XCTAssertTrue(textView.undoManager?.canRedo == true)

        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "the cats are ready.")
        XCTAssertEqual(box.value, "the cats are ready.")
    }

    func testFlowGrammarRedoRestoresSentenceEndAfterNativeCorrectionUndo() async throws {
        let userTyped = "The dogs is playig."
        let nativeCorrected = "The dogs is playing."
        let flowCorrected = "The dogs are playing."
        let box = EditorTextBox(userTyped)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: userTyped
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.undoManager?.removeAllActions()

        let typoRange = (userTyped as NSString).range(of: "playig")
        textView.insertText("playing", replacementRange: typoRange)
        let nativeSentenceEnd = (nativeCorrected as NSString).length
        textView.setSelectedRange(NSRange(location: nativeSentenceEnd, length: 0))
        XCTAssertEqual(textView.string, nativeCorrected)
        XCTAssertEqual(box.value, nativeCorrected)

        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        let grammarRange = (nativeCorrected as NSString).range(of: "is")
        let suggestion = EditorFlowSuggestion(
            documentID: try XCTUnwrap(coordinator.documentID),
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: nativeSentenceEnd,
            sentenceRange: NSRange(location: 0, length: nativeSentenceEnd),
            originalSentence: nativeCorrected,
            correctedSentence: flowCorrected,
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: grammarRange,
                originalText: "is",
                replacementText: "are",
                kind: .grammar
            )]
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(suggestion))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let flowSentenceEnd = (flowCorrected as NSString).length
        XCTAssertEqual(textView.string, flowCorrected)
        XCTAssertEqual(box.value, flowCorrected)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: flowSentenceEnd, length: 0))

        var undoCount = 0
        while textView.string != userTyped,
              textView.undoManager?.canUndo == true,
              undoCount < 3 {
            textView.undoManager?.undo()
            undoCount += 1
        }
        XCTAssertGreaterThan(undoCount, 0)
        XCTAssertEqual(undoCount, 2, "Native autocorrect and Flow grammar should remain separate undo steps")
        XCTAssertEqual(textView.string, userTyped)
        XCTAssertEqual(box.value, userTyped)
        XCTAssertEqual(textView.selectedRange(), typoRange)

        for cycle in 1...3 {
            for _ in 0..<undoCount {
                XCTAssertTrue(textView.undoManager?.canRedo == true)
                textView.undoManager?.redo()
            }
            XCTAssertEqual(textView.string, flowCorrected, "Redo cycle \(cycle)")
            XCTAssertEqual(box.value, flowCorrected, "Redo cycle \(cycle)")
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(location: flowSentenceEnd, length: 0),
                "Redo cycle \(cycle) must restore the post-Flow sentence-end caret, not leave it after “are”"
            )

            guard cycle < 3 else { continue }
            textView.undoManager?.undo()
            XCTAssertEqual(textView.string, nativeCorrected, "Undo cycle \(cycle)")
            XCTAssertEqual(box.value, nativeCorrected, "Undo cycle \(cycle)")
            XCTAssertEqual(
                textView.selectedRange(),
                grammarRange,
                "Undo cycle \(cycle) must select the restored Flow grammar range"
            )
            textView.undoManager?.undo()
            XCTAssertEqual(textView.string, userTyped, "Undo cycle \(cycle)")
            XCTAssertEqual(box.value, userTyped, "Undo cycle \(cycle)")
            XCTAssertEqual(textView.selectedRange(), typoRange, "Undo cycle \(cycle)")
        }
    }

    func testAmbiguousAppleGrammarAlternativesResolveExactSentenceIntoOneBatch() async throws {
        let source = "The dogs is playig"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        var requestedTypes: [NSTextCheckingTypes] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, types, _, completion in
                requestedTexts.append(checkedText)
                requestedTypes.append(types)
                switch checkedText {
                case "The dogs is playig.":
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["am", "are"]
                        ),
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "playig"),
                            replacementString: "playing"
                        ),
                    ], self.englishOrthography())
                case "The dogs am playing.":
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "am",
                            corrections: ["is", "are"]
                        ),
                    ], self.englishOrthography())
                case "The dogs are playing.":
                    completion([], self.englishOrthography())
                default:
                    completion([], nil)
                }
            }
        )
        let recordingTextView = FlowChangeRecordingTextView()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: recordingTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 2 }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(requestedTexts, [
            "The dogs is playig.",
            "The dogs am playing.",
            "The dogs are playing.",
        ])
        XCTAssertTrue(requestedTypes.dropFirst().allSatisfy {
            $0 & NSTextCheckingResult.CheckingType.spelling.rawValue != 0
                && $0 & NSTextCheckingResult.CheckingType.grammar.rawValue != 0
        })
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["is", "playig"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["are", "playing"])
        XCTAssertEqual(textView.flowSuggestion?.headerText, "Fix 2 issues")
        XCTAssertEqual(textView.flowSuggestion?.source, .deterministic)
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "The dogs is playig.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "The dogs are playing.")
        XCTAssertTrue(textView.flowSuggestion?.accessibilityText.contains(
            "Original: The dogs is playig."
        ) == true)
        XCTAssertTrue(textView.flowSuggestion?.accessibilityText.contains(
            "Corrected: The dogs are playing."
        ) == true)

        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "The dogs are playing.")
        XCTAssertEqual(box.value, "The dogs are playing.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "The dogs is playig.")
        XCTAssertEqual(box.value, "The dogs is playig.")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "The dogs are playing.")
        XCTAssertEqual(box.value, "The dogs are playing.")
    }

    func testAmbiguousGrammarValidationAbstainsWhenNoAlternativeIsClean() async {
        await assertAmbiguousGrammarValidationAbstains(cleanReplacements: [])
    }

    func testGrammarOnlyRequestsUnifiedSpellingBitButHidesSpellingCorrections() async {
        let source = "teh dogs is ready"
        let box = EditorTextBox(source)
        var requestedTypes: NSTextCheckingTypes = 0
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, types, _, completion in
                requestedTypes = types
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: (checkedText as NSString).range(of: "teh"),
                        replacementString: "the"
                    ),
                    self.grammarResult(
                        in: checkedText,
                        target: "is",
                        corrections: ["are"]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        XCTAssertNotEqual(
            requestedTypes & NSTextCheckingResult.CheckingType.spelling.rawValue,
            0
        )
        XCTAssertNotEqual(
            requestedTypes & NSTextCheckingResult.CheckingType.grammar.rawValue,
            0
        )
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["is"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["are"])
    }

    func testGrammarOnlyAlternativeValidationIgnoresUnrelatedSpelling() async {
        let source = "teh dogs is ready"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let spelling = NSTextCheckingResult.correctionCheckingResult(
                    range: checkedSource.range(of: "teh"),
                    replacementString: "the"
                )
                if checkedText == source + "." {
                    completion([
                        spelling,
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], self.englishOrthography())
                } else if checkedText.contains(" are ") {
                    completion([spelling], self.englishOrthography())
                } else {
                    completion([
                        spelling,
                        self.grammarResult(
                            in: checkedText,
                            target: "were",
                            corrections: ["are"]
                        ),
                    ], self.englishOrthography())
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)

        XCTAssertEqual(requestedTexts, [
            "teh dogs is ready.",
            "teh dogs are ready.",
            "teh dogs were ready.",
        ])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["is"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["are"])
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "teh dogs are ready.")
        XCTAssertFalse(textView.flowSuggestion?.exactChangeDescription.contains("teh") == true)
    }

    func testGrammarOnlyAlternativeValidationRejectsSpellingAndCorrectionAtTransformedTarget() async {
        await assertGrammarOnlyAlternativeRejectsValidationResult { _, targetRange in
            NSTextCheckingResult.spellCheckingResult(range: targetRange)
        }
        await assertGrammarOnlyAlternativeRejectsValidationResult { _, targetRange in
            NSTextCheckingResult.correctionCheckingResult(
                range: targetRange,
                replacementString: "still-wrong"
            )
        }
    }

    func testGrammarOnlyAlternativeValidationRejectsMalformedTargetResults() async {
        await assertGrammarOnlyAlternativeRejectsValidationResult { _, targetRange in
            NSTextCheckingResult.spellCheckingResult(range: NSRange(
                location: NSNotFound,
                length: targetRange.length
            ))
        }
        await assertGrammarOnlyAlternativeRejectsValidationResult { _, targetRange in
            NSTextCheckingResult.correctionCheckingResult(
                range: NSRange(location: targetRange.location, length: 0),
                replacementString: "invalid"
            )
        }
        await assertGrammarOnlyAlternativeRejectsValidationResult { checkedText, _ in
            NSTextCheckingResult.spellCheckingResult(range: NSRange(
                location: (checkedText as NSString).length,
                length: 1
            ))
        }
    }

    func testAmbiguousGrammarValidationAbstainsWhenMultipleAlternativesAreClean() async {
        await assertAmbiguousGrammarValidationAbstains(cleanReplacements: ["are", "were"])
    }

    func testAmbiguousGrammarValidationDropsStaleResultAfterCancellation() async {
        let source = "They is ready"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        var heldValidation: EditorFlowCheckingClient.Completion?
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                if checkedText == source + "." {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], nil)
                } else {
                    heldValidation = completion
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let validationStarted = await waitUntil { heldValidation != nil }
        XCTAssertTrue(validationStarted)
        XCTAssertEqual(requestedTexts, ["They is ready.", "They are ready."])

        coordinator.cancelFlowForFocusLoss()
        heldValidation?([], nil)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(requestedTexts.count, 2)
        XCTAssertEqual(textView.string, "They is ready.")
        XCTAssertEqual(box.value, "They is ready.")
    }

    func testAmbiguousGrammarValidationSkipsMoreThanThreeAlternatives() async {
        let source = "They is ready"
        let box = EditorTextBox(source)
        var requestCount = 0
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount += 1
                completion([
                    self.grammarResult(
                        in: checkedText,
                        target: "is",
                        corrections: ["am", "are", "were", "be"]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let firstCheckFinished = await waitUntil { requestCount == 1 }
        XCTAssertTrue(firstCheckFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "They is ready.")
    }

    func testAmbiguousGrammarInsideInlineCodeNeverStartsValidation() async {
        let source = "Prose `They is ready`"
        let box = EditorTextBox(source)
        var requestCount = 0
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount += 1
                completion([
                    self.grammarResult(
                        in: checkedText,
                        target: "is",
                        corrections: ["are", "were"]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let initialCheckFinished = await waitUntil { requestCount == 1 }
        XCTAssertTrue(initialCheckFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, source + ".")
    }

    func testSentenceBatchShowsAndAppliesEveryClearCorrection() async throws {
        let source = "teh adn wierd"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                let checkedSource = checkedText as NSString
                let replacements = [
                    ("teh", "the"),
                    ("adn", "and"),
                    ("wierd", "weird"),
                ]
                let results: [NSTextCheckingResult] = replacements.compactMap { pair in
                    let (original, replacement) = pair
                    let range = checkedSource.range(of: original)
                    guard range.location != NSNotFound else { return nil }
                    return NSTextCheckingResult.correctionCheckingResult(
                        range: range,
                        replacementString: replacement
                    )
                }
                completion(results, nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 3 }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.originalText),
            ["teh", "adn", "wierd"]
        )
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.replacementText),
            ["the", "and", "weird"]
        )
        XCTAssertEqual(textView.flowSuggestion?.headerText, "Fix 3 issues")
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "teh adn wierd.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "the and weird.")
        XCTAssertTrue(textView.flowSuggestion?.accessibilityText.contains(
            "replace “wierd” with “weird”"
        ) == true)
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the and weird.")
        XCTAssertEqual(box.value, "the and weird.")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh adn wierd.")
        XCTAssertEqual(box.value, "teh adn wierd.")
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testImpreciseBroadGrammarDetailDoesNotOfferWholeSentenceRewrite() async {
        let source = "This clause has several words that need a broader rewrite"
        let box = EditorTextBox(source)
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let checkedSource = checkedText as NSString
                let clauseRange = checkedSource.range(of: source)
                completion([
                    NSTextCheckingResult.grammarCheckingResult(
                        range: clauseRange,
                        details: [[
                            NSGrammarCorrections: [
                                "This substantially rewritten clause is intentionally longer"
                            ],
                        ]]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 180, height: 520))
        scrollView.frame = window.contentView?.bounds ?? scrollView.frame
        textView.frame = scrollView.bounds
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { requestCount.value > 0 }
        XCTAssertTrue(checkerFinished)
        let didOfferRewrite = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }

        XCTAssertFalse(didOfferRewrite)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
    }

    func testMixedSpellingAndImpreciseBroadGrammarNeverOffersPartialRepair() async {
        let source = "teh dogs is ready"
        let box = EditorTextBox(source)
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let checkedSource = checkedText as NSString
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: checkedSource.range(of: "teh"),
                        replacementString: "the"
                    ),
                    NSTextCheckingResult.grammarCheckingResult(
                        range: checkedSource.range(of: "dogs is"),
                        details: [[NSGrammarCorrections: ["dogs are"]]]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { requestCount.value == 1 }
        XCTAssertTrue(checkerFinished)
        let partialRepairAppeared = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }

        XCTAssertFalse(partialRepairAppeared)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
    }

    func testPartiallyProtectedBroadGrammarStaysUnresolvedAndNeverCallsAI() async {
        let source = "They `is code` ready"
        let box = EditorTextBox(source)
        let checkerCount = EditorIntBox()
        let aiCount = EditorIntBox()
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                aiCount.value += 1
                return "They are ready."
            }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                checkerCount.value += 1
                let checkedSource = checkedText as NSString
                let broadRange = checkedSource.range(of: "They `is code`")
                completion([
                    NSTextCheckingResult.grammarCheckingResult(
                        range: NSRange(location: 0, length: checkedSource.length),
                        details: [[
                            NSGrammarRange: NSValue(range: broadRange),
                            NSGrammarCorrections: ["They are"],
                        ]]
                    ),
                ], self.englishOrthography())
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerFinished = await waitUntil { checkerCount.value == 1 }
        XCTAssertTrue(checkerFinished)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(aiCount.value, 0)
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
    }

    func testSentenceBatchFiltersProtectedCandidatesAndPreservesSyntaxThroughUndoRedo() async throws {
        let source = "teh prose `tehcode` [guide](teh-link.md) adn"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                let checkedSource = checkedText as NSString
                let candidates = [
                    (NSRange(location: 0, length: 3), "the"),
                    (checkedSource.range(of: "tehcode"), "thecode"),
                    (checkedSource.range(of: "teh-link.md"), "the-link.md"),
                    (checkedSource.range(of: "adn"), "and"),
                ]
                completion(candidates.map {
                    NSTextCheckingResult.correctionCheckingResult(
                        range: $0.0,
                        replacementString: $0.1
                    )
                }, nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 2 }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["teh", "adn"])
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(
            textView.string,
            "the prose `tehcode` [guide](teh-link.md) and."
        )
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source + ".")
        textView.undoManager?.redo()
        XCTAssertEqual(
            textView.string,
            "the prose `tehcode` [guide](teh-link.md) and."
        )
    }

    func testReturnOffersPreviousListSentenceBatchAndRepairTabWinsOverIndentation() async throws {
        let source = "- teh cats is ready"
        let box = EditorTextBox(source)
        var checkedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                checkedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let spellingRange = checkedSource.range(of: "teh")
                let grammarRange = checkedSource.range(of: "is")
                guard spellingRange.location != NSNotFound,
                      grammarRange.location != NSNotFound
                else {
                    completion([], nil)
                    return
                }
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: spellingRange,
                        replacementString: "the"
                    ),
                    self.grammarResult(
                        in: checkedText,
                        target: "is",
                        corrections: ["are"]
                    ),
                ], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.markdownShortcutsEnabled = true
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "- teh cats is ready\n- ")
        XCTAssertEqual(box.value, "- teh cats is ready\n- ")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        let batchReady = await waitUntil { textView.flowSuggestion?.edits.count == 2 }
        XCTAssertTrue(batchReady)
        XCTAssertTrue(checkedTexts.contains { $0.contains("teh cats is ready") })
        XCTAssertEqual(textView.flowSuggestion?.headerText, "Fix 2 issues")
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “teh” with “the”, replace “is” with “are”"
        )
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.range),
            [
                (textView.string as NSString).range(of: "teh"),
                (textView.string as NSString).range(of: "is"),
            ]
        )
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "- the cats are ready\n- ")
        XCTAssertEqual(box.value, "- the cats are ready\n- ")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testVisibleFlowCorrectionKeepsPriorityOverWikilinkCompletion() async throws {
        let source = "teh [[Al"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let root = URL(fileURLWithPath: "/tmp/monknot-flow-wikilink", isDirectory: true)
        textView.wikilinkDocuments = [
            WorkspaceDocument(url: root.appendingPathComponent("Alpha.md"), rootURL: root)
        ]
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(
            mode: .markdown,
            options: EditorTextCheckingOptions(
                checksSpelling: false,
                checksGrammar: false,
                inlinePredictions: false
            )
        )
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the [[Al")
        XCTAssertEqual(box.value, "the [[Al")
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

    func testEscapeDismissesAndOneTrailingSpacePreservesRepairUntilNextWord() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
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
        XCTAssertNotNil(textView.flowSuggestion)
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "teh.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "the.")
        XCTAssertEqual(textView.string, "teh. ")
        XCTAssertEqual(box.value, "teh. ")

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "N",
            modifiers: [.shift],
            keyCode: 45,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh. N")
        XCTAssertEqual(box.value, "teh. N")
    }

    func testVisibleRepairThenTrailingSpaceAndImmediateTabAppliesAndUndoPreservesSpace() async throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: " ",
            modifiers: [],
            keyCode: 49,
            windowNumber: window.windowNumber
        )))
        XCTAssertNotNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh. ")
        XCTAssertEqual(box.value, "teh. ")
        await nextMainRunLoopTurn()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "the. ")
        XCTAssertEqual(box.value, "the. ")

        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh. ")
        XCTAssertEqual(box.value, "teh. ")
    }

    func testPunctuationFollowedImmediatelyByOneSpaceCanStillOfferCompletedSentenceRepair() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.string, "teh. ")
        XCTAssertEqual(textView.flowSuggestion?.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, "teh.")
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "the.")

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "N",
            modifiers: [.shift],
            keyCode: 45,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh. N")
    }

    func testEscapeThenContinuedTypingDoesNotReofferTheSameCorrection() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)

        textView.insertText(" Other.", replacementRange: textView.selectedRange())
        let requestsBeforeReturn = checker.requestCount
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let followUpCheckFinished = await waitUntil { checker.requestCount > requestsBeforeReturn }
        XCTAssertTrue(followUpCheckFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(textView.string, "teh. Other.")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testDismissedCorrectionCanReappearForANewlyTypedTarget() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let firstSuggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(firstSuggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)

        textView.insertText("the", replacementRange: NSRange(location: 0, length: 3))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("\n", replacementRange: textView.selectedRange())
        let newTargetLocation = (textView.string as NSString).length
        textView.insertText("teh.", replacementRange: textView.selectedRange())
        let newSuggestionReady = await waitUntil {
            textView.flowSuggestion?.edits.first?.range.location == newTargetLocation
        }

        XCTAssertTrue(newSuggestionReady)
        XCTAssertEqual(textView.string, "the.\nteh.")
        XCTAssertEqual(
            textView.flowSuggestion?.edits.first?.range,
            NSRange(location: newTargetLocation, length: 3)
        )
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “teh” with “the”"
        )
    }

    func testOlderWordCorrectionDoesNotChaseWriterBeforeSentenceBoundary() async {
        let source = "teh cat"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let checkFinished = await waitUntil { checker.requestCount == 1 }
        XCTAssertTrue(checkFinished)
        let didChaseWriter = await waitUntil(timeout: 0.25) {
            textView.flowSuggestion != nil
        }

        XCTAssertFalse(didChaseWriter)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh cat ")
        XCTAssertEqual(box.value, "teh cat ")
    }

    func testAcceptedFlowUndoThenIdleDoesNotImmediatelyReofferTheCorrection() async throws {
        let source = "teh"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowSuggestion(try XCTUnwrap(
            textView.flowSuggestion
        )))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "the.")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh.")
        XCTAssertEqual(box.value, "teh.")
        let sentenceEnd = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.setSelectedRange(sentenceEnd)
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let undoCheckFinished = await waitUntil { checker.requestCount >= 2 }
        XCTAssertTrue(undoCheckFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "teh.")
    }

    func testVisibleAndDismissedUnresolvedCorrectionKeepNativeInlinePredictionSuppressed() async {
        let source = "teh "
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)

        coordinator.dismissFlowSuggestion()

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)
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

    func testFocusResignCancelsWithoutSuppressingCorrectionOnFocusReturn() async {
        let source = "teh"
        let box = EditorTextBox(source)
        let focus = EditorBoolBox(true)
        let checker = ImmediateSpellingFlowChecker(original: "teh", replacement: "the")
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: checker.client,
            flowFocusValidator: { _ in focus.value }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let firstSuggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(firstSuggestionReady)
        let checksBeforeFocusLoss = checker.requestCount

        focus.value = false
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(textView.flowSuggestion)

        focus.value = true
        XCTAssertTrue(window.makeFirstResponder(textView))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let suggestionReturned = await waitUntil {
            checker.requestCount > checksBeforeFocusLoss && textView.flowSuggestion != nil
        }

        XCTAssertTrue(suggestionReturned)
        XCTAssertEqual(textView.string, "teh.")
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “teh” with “the”"
        )
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

    func testWritingToolsRequestPreservesCaretAndExplicitSelection() async {
        let source = "First sentence. Second sentence here. Third sentence."
        let box = EditorTextBox(source)
        var presentedSelections: [NSRange] = []
        var presentedInlinePredictionTypes: [NSTextInputTraitType] = []
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowFocusValidator: { _ in true },
            writingToolsAvailability: { true },
            writingToolsPresenter: { textView in
                presentedSelections.append(textView.selectedRange())
                presentedInlinePredictionTypes.append(textView.inlinePredictionType)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        let caret = (source as NSString).range(of: "sentence here").location + 4
        let caretRange = NSRange(location: caret, length: 0)
        textView.setSelectedRange(caretRange)

        XCTAssertTrue(coordinator.requestWritingTools())
        XCTAssertEqual(textView.selectedRange(), caretRange)
        XCTAssertEqual(presentedSelections, [caretRange])

        let explicitSelection = (source as NSString).range(of: "First sentence")
        textView.setSelectedRange(explicitSelection)

        XCTAssertTrue(coordinator.requestWritingTools())
        XCTAssertEqual(textView.selectedRange(), explicitSelection)
        XCTAssertEqual(presentedSelections, [caretRange, explicitSelection])
        XCTAssertEqual(presentedInlinePredictionTypes, [.no, .no])
    }

    func testWritingToolsRequestRejectsAWhollyProtectedCodeSelection() async {
        let source = "Prose `code value` tail"
        let box = EditorTextBox(source)
        let presentationCount = EditorIntBox()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowFocusValidator: { _ in true },
            writingToolsAvailability: { true },
            writingToolsPresenter: { _ in presentationCount.value += 1 }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        let protectedSelection = (source as NSString).range(of: "code value")
        textView.setSelectedRange(protectedSelection)

        XCTAssertFalse(coordinator.requestWritingTools())
        XCTAssertEqual(textView.selectedRange(), protectedSelection)
        XCTAssertEqual(presentationCount.value, 0)
    }

    func testImmediateWritingToolsRequestWaitsForFreshProtectedRangesThenPresentsOnce() async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let presentationCount = EditorIntBox()
        var presentedSelection: NSRange?
        var presentedInlinePredictionType: NSTextInputTraitType?
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true },
            writingToolsAvailability: { true },
            writingToolsPresenter: { textView in
                presentationCount.value += 1
                presentedSelection = textView.selectedRange()
                presentedInlinePredictionType = textView.inlinePredictionType
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialRangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialRangesReady)

        textView.insertText("!", replacementRange: textView.selectedRange())
        let requestedSelection = textView.selectedRange()
        XCTAssertTrue(coordinator.requestWritingTools())

        let freshScanBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(freshScanBlocked)
        XCTAssertEqual(presentationCount.value, 0)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let didPresent = await waitUntil { presentationCount.value == 1 }
        XCTAssertTrue(didPresent)
        XCTAssertEqual(presentationCount.value, 1)
        XCTAssertEqual(presentedSelection, requestedSelection)
        XCTAssertEqual(presentedInlinePredictionType, .no)
        XCTAssertEqual(textView.selectedRange(), requestedSelection)
    }

    func testDeferredWritingToolsRequestCancelsWhenSelectionChanges() async {
        await assertDeferredWritingToolsRequestDoesNotPresent(after: .selection)
    }

    func testDeferredWritingToolsRequestCancelsWhenTextChanges() async {
        await assertDeferredWritingToolsRequestDoesNotPresent(after: .text)
    }

    func testDeferredWritingToolsRequestCancelsWhenFocusChanges() async {
        await assertDeferredWritingToolsRequestDoesNotPresent(after: .focus)
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

    private func assertGrammarOnlyAlternativeRejectsValidationResult(
        _ validationResult: @escaping (String, NSRange) -> NSTextCheckingResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let source = "teh dogs is ready"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let unrelatedSpelling = NSTextCheckingResult.correctionCheckingResult(
                    range: checkedSource.range(of: "teh"),
                    replacementString: "the"
                )
                if checkedText == completedSource {
                    completion([
                        unrelatedSpelling,
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], self.englishOrthography())
                } else if checkedText.contains(" are ") {
                    let targetRange = checkedSource.range(of: "are")
                    completion([
                        unrelatedSpelling,
                        validationResult(checkedText, targetRange),
                    ], self.englishOrthography())
                } else {
                    completion([unrelatedSpelling], self.englishOrthography())
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady, file: file, line: line)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "teh dogs were ready."
        }

        XCTAssertTrue(suggestionReady, file: file, line: line)
        XCTAssertEqual(requestedTexts, [
            "teh dogs is ready.",
            "teh dogs are ready.",
            "teh dogs were ready.",
        ], file: file, line: line)
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["is"], file: file, line: line)
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["were"], file: file, line: line)
        XCTAssertFalse(
            textView.flowSuggestion?.exactChangeDescription.contains("teh") == true,
            file: file,
            line: line
        )
    }

    private func assertAmbiguousGrammarValidationAbstains(
        cleanReplacements: Set<String>
    ) async {
        let source = "They is ready"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                if checkedText == source + "." {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were"]
                        ),
                    ], self.englishOrthography())
                    return
                }

                let replacement = checkedText.contains(" are ") ? "are" : "were"
                if cleanReplacements.contains(replacement) {
                    completion([], self.englishOrthography())
                } else {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: replacement,
                            corrections: ["is"]
                        ),
                    ], self.englishOrthography())
                }
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: true,
            inlinePredictions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let validationFinished = await waitUntil { requestedTexts.count == 3 }
        XCTAssertTrue(validationFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(requestedTexts, [
            "They is ready.",
            "They are ready.",
            "They were ready.",
        ])
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "They is ready.")
        XCTAssertEqual(box.value, "They is ready.")
    }

    private func grammarResult(
        in text: String,
        target: String,
        corrections: [String]
    ) -> NSTextCheckingResult {
        let source = text as NSString
        let targetRange = source.range(of: target)
        precondition(targetRange.location != NSNotFound)
        return NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: source.length),
            details: [[
                NSGrammarRange: NSValue(range: targetRange),
                NSGrammarCorrections: corrections,
            ]]
        )
    }

    private func englishOrthography() -> NSOrthography {
        NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["en"]]
        )
    }

    private func prepareWritingTools(
        _ coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView
    ) async -> Bool {
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        return await waitUntil { textView.flowWritingToolsReady }
    }

    private func prepareProseCompletion(
        _ coordinator: MarkdownTextEditor.Coordinator,
        textView: MarkdownNSTextView,
        checksSpelling: Bool = false,
        inlinePredictions: Bool = true
    ) async -> Bool {
        let options = EditorTextCheckingOptions(
            checksSpelling: checksSpelling,
            checksGrammar: false,
            inlinePredictions: inlinePredictions,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
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

    private func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowFocusValidator: { _ in true }
        )
    }

    private func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient,
        sentenceRepair: FlowSentenceRepairService
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowSentenceRepairService: sentenceRepair,
            flowFocusValidator: { _ in true }
        )
    }

    private func makeCoordinator(
        _ box: EditorTextBox,
        flowCheckingClient: EditorFlowCheckingClient = EditorFlowCheckingClient {
            _, _, _, _, completion in completion([], nil)
        },
        proseCompletion: FlowProseCompletionService,
        proseCompletionDelayNanoseconds: UInt64 = 0
    ) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            flowCheckingClient: flowCheckingClient,
            flowProseCompletionService: proseCompletion,
            flowProseCompletionDelayNanoseconds: proseCompletionDelayNanoseconds,
            flowFocusValidator: { _ in true }
        )
    }

    private func assertDeferredWritingToolsRequestDoesNotPresent(
        after mutation: DeferredWritingToolsMutation
    ) async {
        let source = "Plain prose"
        let box = EditorTextBox(source)
        let focus = EditorBoolBox(true)
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let presentationCount = EditorIntBox()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in focus.value },
            writingToolsAvailability: { true },
            writingToolsPresenter: { _ in presentationCount.value += 1 }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        textView.flowSourceMode = .markdown
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let initialRangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(initialRangesReady)

        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertTrue(coordinator.requestWritingTools())
        let freshScanBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(freshScanBlocked)
        XCTAssertEqual(presentationCount.value, 0)

        switch mutation {
        case .selection:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.textViewDidChangeSelection(Notification(
                name: NSTextView.didChangeSelectionNotification,
                object: textView
            ))
        case .text:
            textView.insertText("x", replacementRange: textView.selectedRange())
        case .focus:
            focus.value = false
            textView.flowSuggestionCancellationHandler?()
            // Returning before the blocked range scan completes must not revive
            // the request that belonged to the previous responder session.
            focus.value = true
        }

        provider.resumeBlockedCall()
        let rangesSettled = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
        }
        XCTAssertTrue(rangesSettled)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(presentationCount.value, 0)
    }

    private func descendantViews(in root: NSView) -> [NSView] {
        root.subviews.flatMap { child in
            [child] + descendantViews(in: child)
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func renderFlowSuggestion(
        in textView: MarkdownNSTextView,
        window: NSWindow
    ) async {
        await nextMainRunLoopTurn()
        textView.layoutSubtreeIfNeeded()
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        textView.needsDisplay = true
        window.contentView?.needsDisplay = true
        window.contentView?.displayIfNeeded()
        textView.displayIfNeeded()
        await nextMainRunLoopTurn()
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
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
        textView.flowProseSuggestionAcceptanceHandler = {
            coordinator.acceptFlowProseSuggestion($0, nextWordOnly: $1)
        }
        textView.flowSuggestionDismissalHandler = { coordinator.dismissFlowSuggestion() }
        textView.flowSuggestionCancellationHandler = { coordinator.cancelFlowForFocusLoss() }
        textView.flowProseSuggestionCancellationHandler = {
            coordinator.cancelProseCompletionForGeometryChange()
        }
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
        let originalSentence = textView.string
        let editRange = (originalSentence as NSString).range(of: checkedText)
        let correctedSentence = (originalSentence as NSString).replacingCharacters(
            in: editRange,
            with: replacement
        )
        return EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location + textView.selectedRange().length,
            sentenceRange: NSRange(location: 0, length: (originalSentence as NSString).length),
            originalSentence: originalSentence,
            correctedSentence: correctedSentence,
            source: .deterministic,
            edits: [EditorFlowCorrectionEdit(
                range: editRange,
                originalText: checkedText,
                replacementText: replacement,
                kind: .spelling
            )]
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

private enum DeferredWritingToolsMutation {
    case selection
    case text
    case focus
}

private final class EditorBoolBox {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private final class EditorIntBox {
    var value = 0
}

private final class FlowProseCompletionSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let available: Bool
    private let result: String?
    private let delayNanoseconds: UInt64
    private let ignoresCancellation: Bool
    private var storedRequests: [FlowProseCompletionRequest] = []

    init(
        isAvailable: Bool = true,
        result: String?,
        delayNanoseconds: UInt64 = 0,
        ignoresCancellation: Bool = false
    ) {
        available = isAvailable
        self.result = result
        self.delayNanoseconds = delayNanoseconds
        self.ignoresCancellation = ignoresCancellation
    }

    var requestCount: Int {
        lock.withLock { storedRequests.count }
    }

    var requests: [FlowProseCompletionRequest] {
        lock.withLock { storedRequests }
    }

    var service: FlowProseCompletionService {
        FlowProseCompletionService(
            isAvailable: { [available] _ in available },
            client: { [weak self] request, _ in
                guard let self else { return nil }
                self.lock.withLock { self.storedRequests.append(request) }
                if self.delayNanoseconds > 0 {
                    if self.ignoresCancellation {
                        try? await Task.sleep(nanoseconds: self.delayNanoseconds)
                    } else {
                        try await Task.sleep(nanoseconds: self.delayNanoseconds)
                    }
                }
                return self.result
            }
        )
    }
}

private final class ImmediateSpellingFlowChecker {
    private let original: String
    private let replacement: String
    private(set) var requestCount = 0

    init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }

    var client: EditorFlowCheckingClient {
        EditorFlowCheckingClient { [weak self] checkedText, _, _, _, completion in
            guard let self else {
                completion([], nil)
                return
            }
            requestCount += 1
            let range = (checkedText as NSString).range(of: original)
            guard range.location != NSNotFound else {
                completion([], nil)
                return
            }
            completion([
                NSTextCheckingResult.correctionCheckingResult(
                    range: range,
                    replacementString: replacement
                ),
            ], nil)
        }
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
    private var blockingCall: Int
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

    func blockNextCall() {
        condition.withLock {
            blockingCall = storedCallCount + 1
            callBlocked = false
            blockedCallReleased = false
        }
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

private final class FlowChangeRecordingTextView: MarkdownNSTextView {
    struct ApprovedChange {
        let range: NSRange
        let replacement: String?
    }

    var approvedChanges: [ApprovedChange] = []

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        approvedChanges.append(ApprovedChange(
            range: affectedCharRange,
            replacement: replacementString
        ))
        return super.shouldChangeText(
            in: affectedCharRange,
            replacementString: replacementString
        )
    }
}

private final class NativeCheckingRecordingTextView: MarkdownNSTextView {
    enum Event: Equatable {
        case clear(NSRange)
        case check(NSRange, NSTextCheckingTypes)
    }

    var nativeCheckingEvents: [Event] = []

    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        if value == 0 {
            nativeCheckingEvents.append(.clear(charRange))
        }
        super.setSpellingState(value, range: charRange)
    }

    override func checkText(
        in range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:]
    ) {
        nativeCheckingEvents.append(.check(range, checkingTypes))
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
