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

    func testOnDeviceCompletionHoldTabAcceptsAllVisibleTextAndUndoIsOneStep() async throws {
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
        try? await Task.sleep(nanoseconds: 380_000_000)
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
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

    func testHeldTabSwallowsRepeatsAndNormalizesAcceptedSpacingUntilRelease() async throws {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "   clearer prose.   ")
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
        XCTAssertEqual(suggestion.continuation, "clearer prose.")
        let acceptanceCount = EditorIntBox()
        textView.flowProseSuggestionAcceptanceHandler = { suggestion, nextWordOnly in
            acceptanceCount.value += 1
            return coordinator.acceptFlowProseSuggestion(
                suggestion,
                nextWordOnly: nextWordOnly
            )
        }
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        try? await Task.sleep(nanoseconds: 380_000_000)
        XCTAssertEqual(textView.string, "We can write clearer prose.")
        XCTAssertEqual(acceptanceCount.value, 1)

        for _ in 0..<4 {
            textView.keyDown(with: try XCTUnwrap(keyEvent(
                characters: "\t",
                modifiers: [],
                keyCode: 48,
                windowNumber: window.windowNumber,
                isRepeat: true
            )))
        }
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "We can write clearer prose.")
        XCTAssertEqual(box.value, "We can write clearer prose.")
        XCTAssertEqual(acceptanceCount.value, 1)
        XCTAssertFalse(textView.string.hasSuffix(" "))
        XCTAssertFalse(textView.string.contains("\t"))
    }

    func testOnDeviceCompletionTapTabAcceptsOneWordThenHoldTabAcceptsRemainder() async throws {
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
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
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
        try? await Task.sleep(nanoseconds: 380_000_000)
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, with confidence.")
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testDefaultChecksDelayThenRestoreTappedTabCompletionRemainder() async throws {
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
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
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
        try? await Task.sleep(nanoseconds: 380_000_000)
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "We can write clearly, with confidence.")
        XCTAssertEqual(box.value, "We can write clearly, with confidence.")
        XCTAssertNil(textView.flowProseSuggestion)
    }

    func testPendingTappedTabRemainderWrapsWhenReleasedIntoANarrowViewport() async throws {
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
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
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

        let remainderReturned = await waitUntil {
            textView.flowProseSuggestion?.continuation == "with confidence."
        }
        XCTAssertTrue(remainderReturned)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertEqual(textView.string, "We can write clearly, ")
        XCTAssertEqual(box.value, "We can write clearly, ")

        window.setContentSize(NSSize(width: 700, height: 260))
        scrollView.frame = window.contentView!.bounds
        textView.frame = scrollView.bounds
        textView.refreshContentWidthLayout()
        await nextMainRunLoopTurn()
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "with confidence.")
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

    func testAutocompleteDiagnosticsTerminateFailureAndTimeoutWithNativeFallback() async {
        let cases: [(EditorFlowTerminalReason, FlowProseCompletionService)] = [
            (
                .modelFailed,
                FlowProseCompletionService(
                    isAvailable: { _ in true },
                    client: { _, _ in nil }
                )
            ),
            (
                .modelTimedOut,
                FlowProseCompletionService(
                    isAvailable: { _ in true },
                    timeoutNanoseconds: 5_000_000,
                    client: { _, _ in
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        return "too late"
                    }
                )
            ),
        ]

        for (expectedReason, service) in cases {
            let source = "We can write"
            let box = EditorTextBox(source)
            let diagnostics = FlowDiagnosticEventBox()
            let coordinator = makeCoordinator(box, proseCompletion: service)
            coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
            let (window, scrollView, textView) = makeHostedTextView(
                coordinator: coordinator,
                text: source
            )
            let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
            XCTAssertTrue(rangesReady)

            textView.insertText(" ", replacementRange: textView.selectedRange())
            let terminated = await waitUntil {
                diagnostics.events.contains { event in
                    event.owner == .autocomplete && event.reason == expectedReason
                }
            }
            XCTAssertTrue(terminated, "Missing autocomplete terminal reason \(expectedReason)")
            let event = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .autocomplete,
                reason: expectedReason
            )
            XCTAssertTrue(event?.nativeFallbackRestored == true)
            XCTAssertGreaterThanOrEqual(event?.elapsedMilliseconds ?? -1, 0)
            XCTAssertNil(textView.flowProseSuggestion)
            XCTAssertEqual(textView.inlinePredictionType, .default)
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
    }

    func testSentenceRepairDiagnosticsTerminateModelFailureTimeoutAndCheckerTimeout() async {
        let modelCases: [(EditorFlowTerminalReason, FlowSentenceRepairService)] = [
            (
                .modelFailed,
                FlowSentenceRepairService(
                    isAvailable: { _ in true },
                    client: { _, _ in nil }
                )
            ),
            (
                .modelTimedOut,
                FlowSentenceRepairService(
                    isAvailable: { _ in true },
                    timeoutNanoseconds: 5_000_000,
                    client: { _, _ in
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        return "I am writing clearly."
                    }
                )
            ),
        ]

        for (expectedReason, service) in modelCases {
            let source = "I am writng clearly"
            let box = EditorTextBox(source)
            let diagnostics = FlowDiagnosticEventBox()
            let coordinator = makeCoordinator(
                box,
                flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                    let issue = (checkedText as NSString).range(of: "writng")
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: issue,
                            replacementString: ""
                        ),
                    ], self.englishOrthography())
                },
                sentenceRepair: service
            )
            coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
            let (window, scrollView, textView) = makeHostedTextView(
                coordinator: coordinator,
                text: source
            )
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

            textView.insertText(".", replacementRange: textView.selectedRange())
            let terminated = await waitUntil {
                diagnostics.events.contains { event in
                    event.owner == .sentenceRepair && event.reason == expectedReason
                }
            }
            XCTAssertTrue(terminated, "Missing repair terminal reason \(expectedReason)")
            let event = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .sentenceRepair,
                reason: expectedReason
            )
            XCTAssertTrue(event?.nativeFallbackRestored == true)
            XCTAssertNil(textView.flowSuggestion)
            XCTAssertEqual(textView.inlinePredictionType, .default)
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }

        let source = "I am writng clearly"
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, _ in },
            flowCheckingTimeoutNanoseconds: 5_000_000,
            flowFocusValidator: { _ in true }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: true
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        textView.insertText(".", replacementRange: textView.selectedRange())
        let checkerTimedOut = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .checkerTimedOut
            }
        }
        XCTAssertTrue(checkerTimedOut)
        let timeout = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .checkerTimedOut
        )
        XCTAssertTrue(timeout?.nativeFallbackRestored == true)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)
        dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
    }

    func testNonEnglishOrthographyNeverInvokesEnglishSentenceModelFallback() async {
        let source = "Je suis ecritng clairement"
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let modelCalls = EditorIntBox()
        let service = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                modelCalls.value += 1
                return "Je suis écrit clairement."
            }
        )
        let french = NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["fr"]]
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: (checkedText as NSString).range(of: "ecritng"),
                        replacementString: ""
                    ),
                ], french)
            },
            sentenceRepair: service
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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

        textView.insertText(".", replacementRange: textView.selectedRange())
        let rejected = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .validationRejected
            }
        }
        XCTAssertTrue(rejected)
        let event = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .validationRejected
        )
        XCTAssertEqual(modelCalls.value, 0)
        XCTAssertTrue(event?.nativeFallbackRestored == true)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)
    }

    func testSentenceRepairFailureCooldownBlocksSameSentenceButMeaningfulEditRetries() async {
        let cases: [(EditorFlowTerminalReason, (EditorIntBox) -> FlowSentenceRepairService)] = [
            (.modelFailed, { calls in
                FlowSentenceRepairService(isAvailable: { _ in true }) { _, _ in
                    calls.value += 1
                    return nil
                }
            }),
            (.modelTimedOut, { calls in
                FlowSentenceRepairService(
                    isAvailable: { _ in true },
                    timeoutNanoseconds: 5_000_000
                ) { _, _ in
                    calls.value += 1
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return "I am writing clearly."
                }
            }),
            (.validationRejected, { calls in
                FlowSentenceRepairService(isAvailable: { _ in true }) { _, _ in
                    calls.value += 1
                    return "First sentence. Second sentence."
                }
            }),
            (.validationRejected, { calls in
                FlowSentenceRepairService(isAvailable: { _ in true }) { _, _ in
                    calls.value += 1
                    return "I am drafting differently."
                }
            }),
        ]

        for (firstReason, makeService) in cases {
            let source = "I am writng clearly"
            let box = EditorTextBox(source)
            let diagnostics = FlowDiagnosticEventBox()
            let modelCalls = EditorIntBox()
            let coordinator = makeCoordinator(
                box,
                flowCheckingClient: EditorFlowCheckingClient {
                    checkedText, _, _, _, completion in
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "writng"),
                            replacementString: ""
                        ),
                    ], self.englishOrthography())
                },
                sentenceRepair: makeService(modelCalls)
            )
            coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
            let (window, scrollView, textView) = makeHostedTextView(
                coordinator: coordinator,
                text: source
            )
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

            textView.insertText(".", replacementRange: textView.selectedRange())
            let firstFinished = await waitUntil(timeout: 3) {
                diagnostics.events.contains {
                    $0.owner == .sentenceRepair && $0.reason == firstReason
                }
            }
            XCTAssertTrue(firstFinished)
            _ = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .sentenceRepair,
                reason: firstReason
            )
            XCTAssertEqual(modelCalls.value, 1)

            diagnostics.removeAll()
            coordinator.scheduleCompletedSentenceFlowCheck(
                endingAt: (textView.string as NSString).length
            )
            let cooledDown = await waitUntil {
                diagnostics.events.contains {
                    $0.owner == .sentenceRepair && $0.reason == .retryCoolingDown
                }
            }
            XCTAssertTrue(cooledDown)
            let cooldown = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .sentenceRepair,
                reason: .retryCoolingDown
            )
            XCTAssertTrue(cooldown?.nativeFallbackRestored == true)
            XCTAssertEqual(modelCalls.value, 1)

            diagnostics.removeAll()
            textView.setSelectedRange((textView.string as NSString).range(of: "clearly"))
            textView.insertText("carefully", replacementRange: textView.selectedRange())
            textView.setSelectedRange(NSRange(
                location: (textView.string as NSString).length,
                length: 0
            ))
            coordinator.scheduleCompletedSentenceFlowCheck(
                endingAt: (textView.string as NSString).length
            )
            let retried = await waitUntil(timeout: 3) { modelCalls.value == 2 }
            XCTAssertTrue(retried, "Meaningful change did not bypass \(firstReason) cooldown")

            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
    }

    func testLongCompletionWrapsInNarrowViewportWithoutStartingFailureCooldown() async throws {
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
            prose.requestCount == 1 && textView.flowProseSuggestion != nil
        }
        XCTAssertTrue(firstAttemptFinished)
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "extraordinarilylongword")
        XCTAssertEqual(textView.inlinePredictionType, .no)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
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
        let diagnostics = FlowDiagnosticEventBox()
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowProseCompletionService: prose.service,
            flowProseCompletionDelayNanoseconds: 0,
            flowProseOfferDelayNanoseconds: 0,
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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
        XCTAssertEqual(textView.inlinePredictionType, .no)

        provider.resumeBlockedCall()
        let suggestionReady = await waitUntil(timeout: 3) {
            prose.requestCount == 1 && textView.flowProseSuggestion != nil
        }
        XCTAssertTrue(suggestionReady)
        _ = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .autocomplete,
            reason: .visibleAutocomplete
        )
        XCTAssertEqual(prose.requestCount, 1)
    }

    func testPendingProtectedRangeRetryExpiryTerminatesOnceAndReleasesNativeState() async {
        let source = "We can write"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(result: "clearer prose.")
        let diagnostics = FlowDiagnosticEventBox()
        let provider = BlockingProtectedRangeProvider(blockingCall: 2)
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowProseCompletionService: prose.service,
            flowProseCompletionDelayNanoseconds: 0,
            flowProseOfferDelayNanoseconds: 0,
            protectedRangeProvider: { text, mode in
                provider.protectedRanges(in: text, mode: mode)
            },
            flowFocusValidator: { _ in true }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer {
            provider.resumeBlockedCall()
            dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        }
        let rangesReady = await prepareProseCompletion(coordinator, textView: textView)
        XCTAssertTrue(rangesReady)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        let expired = await waitUntil(timeout: 2) {
            diagnostics.events.contains {
                $0.owner == .autocomplete && $0.reason == .protected
            }
        }
        XCTAssertTrue(expired)
        let terminal = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .autocomplete,
            reason: .protected
        )
        XCTAssertTrue(terminal?.nativeFallbackRestored == true)
        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)

        provider.resumeBlockedCall()
        let released = await waitUntil(timeout: 3) {
            provider.activeCallCount == 0 && textView.flowWritingToolsReady
        }
        XCTAssertTrue(released)
        XCTAssertEqual(textView.inlinePredictionType, .default)
        XCTAssertEqual(prose.requestCount, 0)
        XCTAssertNil(textView.flowProseSuggestion)
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
            flowProseOfferDelayNanoseconds: 0,
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

    func testOnDeviceCompletionMatchingTypingConsumesPrefixAndKeepsRemainder() async throws {
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
            characters: "c",
            modifiers: [],
            keyCode: 8,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "We can write c")
        XCTAssertEqual(box.value, "We can write c")
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "learer prose.")
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
        let source = "writting draft"
        let box = EditorTextBox(source)
        let prose = FlowProseCompletionSpy(
            result: "with a polished ending.",
            delayNanoseconds: 700_000_000
        )
        let checker = ImmediateSpellingFlowChecker(original: "writting", replacement: "writing")
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

    func testNarrowViewportWrapsEntireBoundedCompletionAndHoldTabAcceptsAll() async throws {
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
        let suggestion = try XCTUnwrap(textView.flowProseSuggestion)
        let boundedContinuation = suggestion.continuation
        XCTAssertTrue(fullCompletion.hasPrefix(boundedContinuation))
        XCTAssertEqual(
            textView.visibleFlowProseContinuation(
                boundedContinuation,
                atUTF16Offset: suggestion.caretUTF16Offset
            ),
            boundedContinuation
        )

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        try? await Task.sleep(nanoseconds: 380_000_000)
        XCTAssertEqual(textView.string, "We can write " + boundedContinuation)
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

    func testResizeAfterVisibleCustomCompletionReflowsGhost() async throws {
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

        XCTAssertEqual(textView.flowProseSuggestion, suggestion)
        XCTAssertFalse(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertEqual(textView.string, source + " ")
        XCTAssertEqual(box.value, source + " ")
        XCTAssertFalse((textView.accessibilityCustomActions() ?? []).isEmpty)
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
            replacement: "the",
            acceptance: .reviewOnly
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))

        textView.contentWidthPercent = 64
        XCTAssertFalse(textView.canApplyRenderedFlowSuggestion(suggestion))
        XCTAssertFalse(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowSuggestion, suggestion)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)

        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))
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
            replacement: "the",
            acceptance: .reviewOnly
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))

        textView.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        textView.invalidateFlowPresentationForGeometryChange()
        XCTAssertFalse(textView.canApplyRenderedFlowSuggestion(suggestion))
        XCTAssertFalse(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowSuggestion, suggestion)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)

        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))
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

    func testFontChangeReflowsWrappedProseGhostWithoutDiscardingIt() async throws {
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

        XCTAssertEqual(textView.flowProseSuggestion, suggestion)
        XCTAssertFalse(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertEqual(
            textView.visibleFlowProseContinuation(
                suggestion.continuation,
                atUTF16Offset: suggestion.caretUTF16Offset
            ),
            suggestion.continuation
        )
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(suggestion))
        XCTAssertEqual(textView.string, source + " ")
        XCTAssertEqual(box.value, source + " ")
        XCTAssertEqual(textView.accessibilityCustomActions()?.map(\.name), [
            "Accept completion: with confidence and precision.",
            "Accept next completion word",
            "Dismiss completion",
        ])
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

    func testAISentenceRepairValidatorAcceptsTypoButRejectsContentWordSubstitution() throws {
        let typoSource = "I am writng clearly."
        let typoRange = (typoSource as NSString).range(of: "writng")
        let typoRepair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: typoSource,
            candidateSentence: "I am writing clearly.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: typoRange,
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
        let typoEdits = typoRepair.edits
        XCTAssertEqual(typoEdits.count, 1)
        XCTAssertEqual(typoEdits.first?.originalText, "writng")
        XCTAssertEqual(typoEdits.first?.replacementText, "writing")

        let unsafeSource = "I saw a dag outside."
        let unsafeRange = (unsafeSource as NSString).range(of: "dag")
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: unsafeSource,
            candidateSentence: "I saw a cat outside.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: unsafeRange,
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
    }

    func testSentenceRepairValidatorRequiresReviewForLetterDeletingSpellingRepair() throws {
        let ambiguousSource = "Please verfy backups."
        let ambiguousRepair = try XCTUnwrap(
            EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: ambiguousSource,
                candidateSentence: "Please very backups.",
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (ambiguousSource as NSString).range(of: "verfy"),
                    kind: .spelling,
                    hasPreciseRange: true
                )]
            )
        )
        XCTAssertEqual(ambiguousRepair.acceptance, .reviewOnly)

        for (original, candidate, issue) in [
            ("The dog is playig.", "The dog is playing.", "playig"),
            ("Teh plan is ready.", "The plan is ready.", "Teh"),
        ] {
            let repair = try XCTUnwrap(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: original,
                    candidateSentence: candidate,
                    detectedIssues: [EditorFlowDetectedIssue(
                        range: (original as NSString).range(of: issue),
                        kind: .spelling,
                        hasPreciseRange: true
                    )]
                )
            )
            XCTAssertEqual(repair.acceptance, .direct, original)
        }
    }

    func testAISentenceRepairValidatorRejectsChangedTerminalIntent() {
        for (original, candidate, issue) in [
            ("teh?", "the!!!", "teh"),
            ("teh.", "the!", "teh"),
            ("This is gud today.", "This is good. today", "gud"),
        ] {
            let issueRange = (original as NSString).range(of: issue)
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: original,
                    candidateSentence: candidate,
                    detectedIssues: [EditorFlowDetectedIssue(
                        range: issueRange,
                        kind: .spelling,
                        hasPreciseRange: true
                    )]
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
            ("Rojhat works.", "Rojhad works.", "Rojhat"),
            ("Zorhat works.", "Zorhad works.", "Zorhat"),
        ] {
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: original,
                    candidateSentence: candidate,
                    detectedIssues: [EditorFlowDetectedIssue(
                        range: (original as NSString).range(of: issue),
                        kind: .spelling,
                        hasPreciseRange: true
                    )]
                ),
                "AI repair must preserve names and the user's letter-case pattern: \(original)"
            )
        }
    }

    func testAISentenceRepairValidatorRejectsMutatedDuplicateAndCausalPivots() {
        let duplicate = "The report was very very clear."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: duplicate,
            candidateSentence: "The report was vary clear.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (duplicate as NSString).range(of: "very very"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ))

        let runOn = "I missed the train I arrived late."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: runOn,
            candidateSentence: "I missed the train because I arrived late.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: NSRange(location: 0, length: (runOn as NSString).length),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ))

        let existingPivot = "I was tired, so I left."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: existingPivot,
            candidateSentence: "I was tired; I left.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (existingPivot as NSString).range(of: "so"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ))

        let inventedModal = "Maya shipps the report."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: inventedModal,
            candidateSentence: "Maya will ship the report.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (inventedModal as NSString).range(of: "shipps"),
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))

        let validComplexSentence = "We know the report is ready because I checked every section and you confirmed all figures before the meeting today."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: validComplexSentence,
            candidateSentence: "We know the report was ready because I checked every section. You confirmed all figures before the meeting today.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (validComplexSentence as NSString).range(of: "meeting"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ))

        let inheritedActors = "I know the plan because you checked the figures and confirmed the total while I reviewed the notes and called Maya."
        for (candidate, connector) in [
            (
                "I know the plan because you checked the figures and I confirmed the total while I reviewed the notes and called Maya.",
                "and confirmed"
            ),
            (
                "I know the plan because you checked the figures and confirmed the total while I reviewed the notes and you called Maya.",
                "and called"
            ),
        ] {
            XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: inheritedActors,
                candidateSentence: candidate,
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (inheritedActors as NSString).range(of: connector),
                    kind: .grammar,
                    hasPreciseRange: true
                )]
            ), "A run-on repair must not assign an inherited clause to a different actor")
        }

        let inheritedSameActor = "I slept badly last night because I was sick and cannot drive safely to the clinic this morning."
        let inheritedRepair = EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: inheritedSameActor,
            candidateSentence: "I slept badly last night because I was sick and I cannot drive safely to the clinic this morning.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (inheritedSameActor as NSString).range(of: "and cannot"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        )
        XCTAssertNotNil(inheritedRepair)
        XCTAssertEqual(inheritedRepair?.acceptance, .reviewOnly)
    }

    func testProposedConservativeAIFixturesPreserveSemanticPivots() throws {
        let candidates = [
            "repair-ai-008": "We reviewed the launch plan; it still needs a rollback owner.",
            "repair-ai-011": "The notes say that design will send the prototype, and support reviews it tomorrow.",
            "repair-ai-015": "On Friday, Maya will compare the two vendor proposals, the security notes from March, and every open question; then she sends a recommendation to the Project Cedar owners before the budget meeting starts.",
            "repair-ai-016": "Lea said, “I cannot join tonight; the babysitter cancelled, and I need to stay home.”",
            "repair-ai-020": "Before the autumn launch, the research team interviews twelve customers from Vienna, Berlin, and Prague, then compares those notes with support tickets collected since March; the team also needs to test imports on two older Macs, verify every Markdown link, and ask Maya to record unresolved risks for Project Cedar before August 28, 2026.",
        ]
        for (id, candidate) in candidates {
            let testCase = try XCTUnwrap(
                FlowWritingCorpus.repairCases.first { $0.id == id }
            )
            let ranges = corpusDifferenceRanges(in: testCase.input, candidate: candidate)
            let issues = corpusDetectedIssues(
                in: testCase.input,
                candidate: candidate,
                issueRanges: ranges,
                testCase: testCase
            )
            let repair = try XCTUnwrap(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: testCase.input,
                    candidateSentence: candidate,
                    detectedIssues: issues
                ),
                "Punctuation-only conservative fixture rejected: \(id); issues=\(issues.map(\.range))"
            )
            XCTAssertEqual(repair.acceptance, .reviewOnly, id)
        }
    }

    func testAISentenceRepairValidatorClassifiesNarrowFunctionWordAndCommaAsDirect() throws {
        for (original, candidate, issue) in [
            ("I wanted let you know.", "I wanted to let you know.", "wanted let"),
            ("After review we can send it.", "After review, we can send it.", "review"),
        ] {
            let repair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: original,
                candidateSentence: candidate,
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (original as NSString).range(of: issue),
                    kind: .grammar,
                    hasPreciseRange: true
                )]
            ), "Expected validated grammar repair for: \(original)")

            XCTAssertEqual(repair.acceptance, .direct, "Expected narrow direct repair: \(original)")
            let applied = NSMutableString(string: original)
            for edit in repair.edits.reversed() {
                applied.replaceCharacters(in: edit.range, with: edit.replacementText)
            }
            XCTAssertEqual(applied as String, candidate)
        }
    }

    func testAISentenceRepairValidatorKeepsFaithfulReportedRepairReviewOnly() throws {
        let original = "I am nt be able to come today because yesterday I got sick so badly and now cannot get out of the bed wirhgth now."
        let candidate = "I am not able to come today because yesterday I got sick so badly, and now I cannot get out of the bed right now."
        let source = original as NSString
        let repair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: original,
            candidateSentence: candidate,
            detectedIssues: [
                EditorFlowDetectedIssue(
                    range: source.range(of: "nt"),
                    kind: .spelling,
                    hasPreciseRange: true
                ),
                EditorFlowDetectedIssue(
                    range: source.range(of: "I am nt be"),
                    kind: .grammar,
                    hasPreciseRange: true
                ),
                EditorFlowDetectedIssue(
                    range: source.range(of: "sick so badly and now cannot"),
                    kind: .grammar,
                    hasPreciseRange: true
                ),
                EditorFlowDetectedIssue(
                    range: source.range(of: "wirhgth"),
                    kind: .spelling,
                    hasPreciseRange: true
                ),
            ]
        ))

        XCTAssertEqual(repair.acceptance, .reviewOnly)
        for preserved in ["yesterday", "sick", "badly", "bed", "now"] {
            XCTAssertTrue(candidate.contains(preserved), "Lost preserved concept: \(preserved)")
        }
    }

    func testAISentenceRepairValidatorRejectsClaimIdentityMarkdownAndToneChanges() {
        let cases: [(String, String, String)] = [
            ("I saw a dag outside.", "I saw a cat outside.", "dag"),
            ("Maya sent the report.", "Nora sent the report.", "Maya"),
            ("Build 17 is ready.", "Build 18 is ready.", "17"),
            ("Maya said, “Ship today.”", "Maya said, “Ship tomorrow.”", "today"),
            ("Keep **Launch Ready** unchanged.", "Keep *Launch Ready* unchanged.", "Launch Ready"),
            ("Please send the report.", "Send the report!", "Please"),
        ]

        for (original, candidate, issue) in cases {
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: original,
                    candidateSentence: candidate,
                    detectedIssues: [EditorFlowDetectedIssue(
                        range: (original as NSString).range(of: issue),
                        kind: .spelling,
                        hasPreciseRange: true
                    )]
                ),
                "Unsafe repair passed validation: \(original) -> \(candidate)"
            )
        }
    }

    func testAISentenceRepairValidatorRejectsSemanticPivotsButAllowsMechanicalGrammar() throws {
        let rejected: [(String, String, String)] = [
            ("Maya reviewed and approved the plan.", "Maya reviewed or approved the plan.", "and"),
            ("We can ship today.", "We must ship today.", "can"),
            ("We can ship today.", "We cannot ship today.", "can"),
            ("They sent the report.", "We sent the report.", "They"),
            ("Use this if needed.", "Use this is needed.", "if"),
        ]
        for (original, candidate, issue) in rejected {
            XCTAssertNil(
                EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: original,
                    candidateSentence: candidate,
                    detectedIssues: [EditorFlowDetectedIssue(
                        range: (original as NSString).range(of: issue),
                        kind: .spelling,
                        hasPreciseRange: true
                    )]
                ),
                "Semantic pivot passed validation: \(original) -> \(candidate)"
            )
        }

        for (original, candidate, issue) in [
            ("The dogs is ready.", "The dogs are ready.", "is"),
            ("I attached a update.", "I attached an update.", "a update"),
        ] {
            let repair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: original,
                candidateSentence: candidate,
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (original as NSString).range(of: issue),
                    kind: .spelling,
                    hasPreciseRange: true
                )]
            ), "Mechanical grammar repair was rejected: \(original)")
            XCTAssertEqual(repair.acceptance, .direct)
        }
    }

    func testAISentenceRepairValidatorDoesNotDirectlyApplyUnrelatedFunctionWordFamilies() {
        for (original, candidate, issue) in [
            ("They had the report.", "They have the report.", "had"),
            ("They had the report.", "They has the report.", "had"),
            ("She did the review.", "She does the review.", "did"),
            ("The service was ready.", "The service is ready.", "was"),
            ("I attached the update.", "I attached an update.", "the update"),
            ("Meet at noon.", "Meet as noon.", "at"),
            ("Written by Ana.", "Written be Ana.", "by"),
            ("Keep it in view.", "Keep it is view.", "in"),
        ] {
            let repair = EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: original,
                candidateSentence: candidate,
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (original as NSString).range(of: issue),
                    kind: .grammar,
                    hasPreciseRange: true
                )]
            )
            XCTAssertNotEqual(
                repair?.acceptance,
                .direct,
                "A different function-word family must require review or rejection: \(original)"
            )
        }
    }

    func testAISentenceRepairValidatorAllowsOnlyIssueBackedQuotedTypoRepair() throws {
        let original = "Maya said, “Ship todya.”"
        let candidate = "Maya said, “Ship today.”"
        let direct = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: original,
            candidateSentence: candidate,
            detectedIssues: [EditorFlowDetectedIssue(
                range: (original as NSString).range(of: "todya"),
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
        XCTAssertEqual(direct.acceptance, .direct)

        let semanticOriginal = "Maya wrote “cat” in the note."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: semanticOriginal,
            candidateSentence: "Maya wrote “can” in the note.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (semanticOriginal as NSString).range(of: "cat"),
                kind: .grammar,
                hasPreciseRange: false
            )]
        ))

        let quotedClaim = "Maya said, “Ship today.”"
        let broadClaimIssue = [EditorFlowDetectedIssue(
            range: NSRange(location: 0, length: (quotedClaim as NSString).length),
            kind: .grammar,
            hasPreciseRange: false
        )]
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: quotedClaim,
            candidateSentence: "Maya said, Ship “today.”",
            detectedIssues: broadClaimIssue
        ), "Moving a quote boundary changes which words belong to the claim")
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: quotedClaim,
            candidateSentence: "Maya said, Ship today.",
            detectedIssues: broadClaimIssue
        ), "Removing quote boundaries must not silently flatten a claim")
    }

    func testAISentenceRepairValidatorPreservesIdentifierTokensExactly() {
        for (original, candidate, issue) in [
            ("Run build_targt now.", "Run build_target now.", "build_targt"),
            ("Call flowTarget now.", "Call flowtarget now.", "flowTarget"),
            ("Keep MK-204 active.", "Keep MK-205 active.", "MK-204"),
        ] {
            XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: original,
                candidateSentence: candidate,
                detectedIssues: [EditorFlowDetectedIssue(
                    range: (original as NSString).range(of: issue),
                    kind: .spelling,
                    hasPreciseRange: true
                )]
            ), "Identifier changed: \(original) -> \(candidate)")
        }
    }

    func testAISentenceRepairValidatorReviewsSentenceInitialSpellingButRejectsNameChange() throws {
        let typo = "Recieve the report."
        let spellingRepair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: typo,
            candidateSentence: "Receive the report.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (typo as NSString).range(of: "Recieve"),
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
        XCTAssertEqual(spellingRepair.acceptance, .reviewOnly)
        XCTAssertEqual(spellingRepair.edits.map(\.originalText), ["Recieve"])
        XCTAssertEqual(spellingRepair.edits.map(\.replacementText), ["Receive"])

        let named = "Maya sent the report."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: named,
            candidateSentence: "Naya sent the report.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (named as NSString).range(of: "Maya"),
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
    }

    func testAISentenceRepairValidatorKeepsMixedDuplicateAndPreciseInflectionReviewOnly() throws {
        let original = "The teams needs needs a plan."
        let candidate = "The teams need a plan."
        let source = original as NSString
        let preciseRepair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: original,
            candidateSentence: candidate,
            detectedIssues: [EditorFlowDetectedIssue(
                range: source.range(of: "needs needs"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ))
        XCTAssertEqual(preciseRepair.acceptance, .reviewOnly)

        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: original,
            candidateSentence: candidate,
            detectedIssues: [EditorFlowDetectedIssue(
                range: NSRange(location: 0, length: source.length),
                kind: .grammar,
                hasPreciseRange: false
            )]
        ))
    }

    func testAISentenceRepairValidatorUsesDetectedIssueKindToProtectClaims() throws {
        let grammarOriginal = "The plan are ready."
        XCTAssertNil(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: grammarOriginal,
            candidateSentence: "The play is ready.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (grammarOriginal as NSString).range(of: "plan are"),
                kind: .grammar,
                hasPreciseRange: true
            )]
        ), "A broad grammar issue must not license a content-word claim change")

        let spellingOriginal = "Teh plan is ready."
        let repair = try XCTUnwrap(EditorFlowSentenceRepairValidator.validatedRepair(
            originalSentence: spellingOriginal,
            candidateSentence: "The plan is ready.",
            detectedIssues: [EditorFlowDetectedIssue(
                range: (spellingOriginal as NSString).range(of: "Teh"),
                kind: .spelling,
                hasPreciseRange: true
            )]
        ))
        XCTAssertEqual(repair.acceptance, .direct)
        XCTAssertEqual(repair.edits.map(\.originalText), ["Teh"])
        XCTAssertEqual(repair.edits.map(\.replacementText), ["The"])
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

        XCTAssertEqual(repaired, .success("    the."))
    }

    func testFrozenCoordinatorNonAICorpusRunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .nonAI)
    }

    func testFrozenCoordinatorAI001Through005RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(1...5))
    }

    func testFrozenCoordinatorAI006Through008RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(6...8))
    }

    func testFrozenCoordinatorAI009RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(9...9))
    }

    func testFrozenCoordinatorAI010RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(10...10))
    }

    func testFrozenCoordinatorAI011Through013RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(11...13))
    }

    func testFrozenCoordinatorAI014Through015RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(14...15))
    }

    func testFrozenCoordinatorAI016Through018RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(16...18))
    }

    func testFrozenCoordinatorAI019Through020RunsThroughHostedCharacterTypingPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .characterTyping, shard: .ai(19...20))
    }

    func testFrozenCoordinatorNonAICorpusRunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .nonAI)
    }

    func testFrozenCoordinatorAI001Through005RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(1...5))
    }

    func testFrozenCoordinatorAI006Through008RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(6...8))
    }

    func testFrozenCoordinatorAI009RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(9...9))
    }

    func testFrozenCoordinatorAI010RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(10...10))
    }

    func testFrozenCoordinatorAI011Through013RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(11...13))
    }

    func testFrozenCoordinatorAI014Through015RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(14...15))
    }

    func testFrozenCoordinatorAI016Through018RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(16...18))
    }

    func testFrozenCoordinatorAI019Through020RunsThroughHostedPasteboardPath() async throws {
        try await runFrozenCoordinatorCorpus(inputPath: .pasteboard, shard: .ai(19...20))
    }

    func testFrozenConservativeAIReviewRunsThroughHostedCharacterTypingPath() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-ai-001" }
        )
        let outcome = try await runFrozenAICorpusCase(
            testCase,
            inputPath: .characterTyping
        )
        XCTAssertEqual(outcome, .review)
    }

    func testFrozenLongDeterministicRepairUsesPolicyAndExactUndoRedo() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-exact-024" }
        )
        try await runFrozenDeterministicCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenQuotedHardWrapUsesRealPunctuationAndCloserKeyEvents() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-exact-022" }
        )
        try await runFrozenDeterministicCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenProtectedReturnProducesExactlyOneTerminalAttempt() async throws {
        let testCase = try XCTUnwrap(
            FlowWritingCorpus.repairCases.first { $0.id == "repair-protected-002" }
        )
        try await runFrozenProtectedCorpusCase(testCase, inputPath: .pasteboard)
    }

    func testFrozenAICorpusFixturesMatchDeclaredValidatorClassifications() throws {
        let aiCases = FlowWritingCorpus.repairCases
            .filter { $0.expectation == .aiInvariant }
            .sorted { $0.id < $1.id }
        XCTAssertEqual(aiCases.count, 20)

        for testCase in aiCases {
            let candidate = testCase.conservativeCandidateFixture ?? testCase.referenceText
            let ranges = corpusDifferenceRanges(in: testCase.input, candidate: candidate)
            let issues = corpusDetectedIssues(
                in: testCase.input,
                candidate: candidate,
                issueRanges: ranges,
                testCase: testCase
            )
            let repair = EditorFlowSentenceRepairValidator.validatedRepair(
                originalSentence: testCase.input,
                candidateSentence: candidate,
                detectedIssues: issues
            )
            XCTAssertNotNil(repair, "Labeled fixture rejected: \(testCase.id)")
            let expected: EditorFlowSuggestionAcceptance = testCase.aiClassification == .direct
                ? .direct
                : .reviewOnly
            XCTAssertEqual(
                repair?.acceptance,
                expected,
                "Classification drift for \(testCase.id); ranges=\(ranges); issues=\(issues.map(\.range))"
            )
        }
    }

    func testAISentenceRepairFallbackSettlesValidatedDirectRepairAtomically() async throws {
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
        let settled = await waitUntil { textView.string == corrected }
        XCTAssertTrue(settled)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{7f}",
            modifiers: [],
            keyCode: 51,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
    }

    func testReportedAIReviewOnlyRepairPostCheckPresentsInlineReviewAndTabApplies() async throws {
        let incomplete = "I am nt be able to come today because yesterday I got sick so badly and now cannot get out of the bed wirhgth now"
        let original = incomplete + "."
        let candidate = "I am not able to come today because yesterday I got sick so badly, and now I cannot get out of the bed right now."
        let box = EditorTextBox(incomplete)
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in candidate }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == candidate {
                    completion([], self.englishOrthography())
                    return
                }
                let source = checkedText as NSString
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: source.range(of: "nt"),
                        replacementString: ""
                    ),
                    NSTextCheckingResult.grammarCheckingResult(
                        range: NSRange(location: 0, length: source.length),
                        details: [
                            [
                                NSGrammarRange: NSValue(range: source.range(of: "I am nt be")),
                                NSGrammarCorrections: [],
                            ],
                            [
                                NSGrammarRange: NSValue(range: source.range(
                                    of: "sick so badly and now cannot"
                                )),
                                NSGrammarCorrections: [],
                            ],
                        ]
                    ),
                    NSTextCheckingResult.correctionCheckingResult(
                        range: source.range(of: "wirhgth"),
                        replacementString: ""
                    ),
                ], self.englishOrthography())
            },
            sentenceRepair: sentenceRepair
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: incomplete
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowSuggestion)
        XCTAssertEqual(suggestion.source, .ai)
        XCTAssertEqual(suggestion.originalSentence, original)
        XCTAssertEqual(suggestion.correctedSentence, candidate)
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertFalse(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, candidate)
        XCTAssertEqual(box.value, candidate)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, original)
        XCTAssertEqual(box.value, original)
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
        let source = "I am writting clearly"
        let completedSource = source + "."
        let corrected = "I am writing clearly."
        let box = EditorTextBox(source)
        let aiRequestCount = EditorIntBox()
        let diagnostics = FlowDiagnosticEventBox()
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
                let issueRange = (checkedText as NSString).range(of: "writting")
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: issueRange,
                        replacementString: ""
                    ),
                ], self.englishOrthography())
            },
            sentenceRepair: sentenceRepair
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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

        diagnostics.removeAll()
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let suppressionFinished = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
            }
        }
        XCTAssertTrue(suppressionFinished)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(box.value, completedSource)
        XCTAssertEqual(aiRequestCount.value, 1, "Exact dismissed AI source must not call the model again")
        let terminal = try XCTUnwrap(diagnostics.events.first(where: {
            $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
        }))
        let sameAttempt = diagnostics.events.filter {
            $0.owner == terminal.owner && $0.token == terminal.token
        }
        XCTAssertEqual(sameAttempt.map(\.reason), [.suppressedDuplicate])
        XCTAssertEqual(
            diagnostics.events.filter { $0.owner == .sentenceRepair }.count,
            1,
            "The exact-source recheck must emit one sentence-repair terminal"
        )
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

        XCTAssertEqual(single.originalSentence, singleOriginal)
        XCTAssertEqual(single.correctedSentence, singleCorrected)
        XCTAssertEqual(single.originalChangedRanges, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(single.correctedChangedRanges, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(
            single.accessibilityText,
            "Suggested correction: the.\n"
                + "Changes: replace “teh” with “the”. Tab applies; Right Arrow shows the next "
                + "alternative; Escape dismisses. Source: Apple spelling and grammar."
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

        XCTAssertEqual(batch.originalSentence, batchOriginal)
        XCTAssertEqual(batch.correctedSentence, batchCorrected)
        XCTAssertEqual(batch.exactChangeDescription, "replace “teh” with “the”, replace “is” with “are”")
        XCTAssertEqual(
            batch.accessibilityText,
            "Suggested correction: the cats are ready.\n"
                + "Changes: replace “teh” with “the”, replace “is” with “are”. "
                + "Tab applies; Right Arrow shows the next alternative; Escape dismisses. "
                + "Source: Apple spelling and grammar."
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

    func testFlowPresentationPolicyIsIndependentOfViewportGeometryAndPreservesProvenance() {
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
            acceptance: .reviewOnly,
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
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains { $0.hasPrefix("Apply correction:") })
        XCTAssertTrue(names.contains { $0.hasPrefix("Dismiss correction:") })
        for name in names {
            XCTAssertTrue(name.contains("abcdefghijklmnopqrstuvwx"))
            XCTAssertTrue(name.contains("ABCDEFGHIJKLMNOPQRSTUVWX"))
            XCTAssertTrue(name.contains("zyxwvutsrqponmlkjihgfe"))
            XCTAssertTrue(name.contains("ZYXWVUTSRQPONMLKJIHGFE"))
            XCTAssertFalse(name.contains("…"))
        }
        XCTAssertEqual(textView.accessibilityHelp(), suggestion.accessibilityText)
        XCTAssertFalse(textView.accessibilityHelp()?.contains("Original: \(source)") == true)
        XCTAssertTrue(textView.accessibilityHelp()?.contains(
            "Suggested correction: ABCDEFGHIJKLMNOPQRSTUVWX ZYXWVUTSRQPONMLKJIHGFE"
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

    func testDelayedCheckerResultSettlesConcreteSuggestionWhenSnapshotIsCurrent() async throws {
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
        let settled = await waitUntil { textView.string == "the." }
        XCTAssertTrue(settled)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(box.value, "the.")
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let currentRefreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(currentRefreshBlocked)
        let firstCheckFinished = await waitUntil { requestCount.value == 1 }
        XCTAssertTrue(firstCheckFinished)
        XCTAssertNil(textView.flowSuggestion)

        provider.resumeBlockedCall()
        let retriedSuggestionReady = await waitUntil(timeout: 3) {
            requestCount.value == 2 && textView.string == "the."
        }

        XCTAssertTrue(retriedSuggestionReady)
        XCTAssertEqual(textView.string, "the.")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["teh"])
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["the"])
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
        let retriedCorrectionSettled = await waitUntil(timeout: 3) {
            requestCount.value >= 2 && textView.string == "- the\n- "
        }

        XCTAssertTrue(retriedCorrectionSettled)
        XCTAssertEqual(Array(checkedTexts.prefix(2)), ["- teh", "- teh"])
        XCTAssertNil(textView.flowSuggestion)
    }

    func testFlowCheckerSendsBoundedCurrentSentenceAndTranslatesLocalOffsets() async {
        // A blank line gives the current sentence an authoritative logical-block
        // boundary. Lowercase prose after only a hard wrap is intentionally kept
        // in Foundation's larger fail-safe range (covered separately).
        let earlierContext = String(repeating: "Earlier context sentence. ", count: 220) + "\n\n"
        let currentSentence = "teh cats is ready"
        let source = earlierContext + currentSentence
        let box = EditorTextBox(source)
        var capturedText: String?
        var capturedRange: NSRange?
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, range, _, _, completion in
                if capturedText == nil {
                    capturedText = checkedText
                    capturedRange = range
                }
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
        let recordingTextView = FlowChangeRecordingTextView()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: recordingTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(checksSpelling: true, checksGrammar: false)
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let writingToolsReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(writingToolsReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string.hasSuffix("the cats is ready.") }
        XCTAssertTrue(settled)

        let checkedText = capturedText ?? ""
        XCTAssertEqual(checkedText, currentSentence + ".")
        XCTAssertLessThanOrEqual((checkedText as NSString).length, 900)
        XCTAssertEqual(
            capturedRange,
            NSRange(location: 0, length: (checkedText as NSString).length)
        )
        let absoluteRange = (source as NSString).range(of: "teh", options: .backwards)
        XCTAssertEqual(recordingTextView.approvedChanges.last?.range, absoluteRange)
        XCTAssertEqual(recordingTextView.approvedChanges.last?.replacement, "the")
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
            replacement: "the",
            acceptance: .reviewOnly
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))

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
        XCTAssertEqual(suggestion.acceptance, .direct)
        XCTAssertFalse(textView.canApplyRenderedFlowSuggestion(suggestion))

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
        XCTAssertFalse(textView.canApplyRenderedFlowSuggestion(suggestion))
        let apply = try XCTUnwrap((textView.accessibilityCustomActions() ?? []).first {
            $0.name.hasPrefix("Apply correction:")
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
            acceptance: .reviewOnly,
            edits: [EditorFlowCorrectionEdit(
                range: editRange,
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            )]
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let repairCleared = await waitUntil { textView.flowSuggestion == nil }
        XCTAssertTrue(repairCleared)
        XCTAssertFalse(textView.canApplyRenderedFlowSuggestion(suggestion))

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

    func testNarrowInlineReviewDismissesWithEscapeWithoutMutatingText() async throws {
        let first = "abcdefghijklmnopqrstuvwx"
        let second = "zyxwvutsrqponmlkjihgfe"
        let source = "\(first) \(second)"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], nil)
            }
        )
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        window.setContentSize(NSSize(width: 120, height: 260))
        scrollView.frame = window.contentView?.bounds ?? scrollView.frame
        textView.frame = scrollView.bounds
        let corrected = "\(first.uppercased()) \(second.uppercased())"
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: (source as NSString).length),
            originalSentence: source,
            correctedSentence: corrected,
            source: .deterministic,
            acceptance: .reviewOnly,
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
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)

        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertEqual(textView.accessibilityHelp(), suggestion.accessibilityReviewText)
        XCTAssertEqual((textView.accessibilityCustomActions() ?? []).count, 2)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertFalse(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testInlineReviewAppliesExactlyOnce() async throws {
        let source = "abcdefghijklmnopqrstuvwx"
        let corrected = source.uppercased()
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
            acceptance: .reviewOnly,
            edits: [EditorFlowCorrectionEdit(
                range: NSRange(location: 0, length: (source as NSString).length),
                originalText: source,
                replacementText: corrected,
                kind: .spelling
            )]
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)

        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(textView.string, source)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let applied = await waitUntil {
            acceptanceCount.value == 1
                && textView.string == corrected
                && !textView.isFlowReviewPreviewShown
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(box.value, corrected)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)

        for _ in 0..<3 {
            textView.keyDown(with: try XCTUnwrap(keyEvent(
                characters: "\t",
                modifiers: [],
                keyCode: 48,
                windowNumber: window.windowNumber,
                isRepeat: true
            )))
        }
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        XCTAssertEqual(textView.selectedRange(), NSRange(
            location: (corrected as NSString).length,
            length: 0
        ))
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)
        XCTAssertFalse(textView.string.contains("\t"))

        textView.keyUp(with: try XCTUnwrap(keyEvent(
            type: .keyUp,
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertFalse(textView.confirmFlowReviewSuggestionForTesting())
        XCTAssertEqual(acceptanceCount.value, 1)
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
    }

    func testLongInlineReviewAtTwoTimesZoomUsesEditorViewportWithoutExtraWindow() async throws {
        let repeated = Array(
            repeating: "teh sentence has enough surrounding context to require careful review.",
            count: 24
        ).joined(separator: " ")
        let source = repeated
        let corrected = source.replacingOccurrences(of: "teh", with: "the")
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
            acceptance: .reviewOnly,
            edits: edits
        )
        textView.flowSuggestion = suggestion
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)

        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
    }

    func testSentenceBoundaryFlowBatchSettlesAtomicallyDeleteRevertsAndRedoRestoresExactText() async throws {
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

        let preservedGapKey = NSAttributedString.Key("MonknotFlowPreservedGap")
        let preservedGapRange = (textView.string as NSString).range(of: "cats")
        textView.textStorage?.addAttribute(
            preservedGapKey,
            value: "preserved",
            range: preservedGapRange
        )
        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "the cats are ready." }
        XCTAssertTrue(settled)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)
        XCTAssertEqual(textView.string, "the cats are ready.")
        XCTAssertEqual(box.value, "the cats are ready.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 2)
        XCTAssertEqual(recordingTextView.approvedChanges.last?.range, NSRange(location: 0, length: 11))
        XCTAssertEqual(recordingTextView.approvedChanges.last?.replacement, "the cats are")
        XCTAssertEqual(
            textView.textStorage?.attribute(
                preservedGapKey,
                at: preservedGapRange.location,
                effectiveRange: nil
            ) as? String,
            "preserved"
        )
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 19, length: 0))
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 2)

        try? await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 2)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{7f}",
            modifiers: [],
            keyCode: 51,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "teh cats is ready.")
        XCTAssertEqual(box.value, "teh cats is ready.")
        XCTAssertTrue(textView.undoManager?.canRedo == true)

        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "the cats are ready.")
        XCTAssertEqual(box.value, "the cats are ready.")
    }

    func testSettlementHighlightUsesThemeContrastAndMotionStrengths() {
        let samples: [(TimeInterval, Bool, Bool, Bool, CGFloat)] = [
            (0, true, false, false, 0.24),
            (0.22, true, false, false, 0.44),
            (1, true, false, false, 0.24),
            (0, false, false, false, 0.18),
            (0.22, false, false, false, 0.34),
            (2, false, false, false, 0.18),
            (0, true, true, false, 0.34),
            (0, false, true, false, 0.28),
            (0.22, true, false, true, 0.24),
        ]
        for (elapsed, isDark, increaseContrast, reduceMotion, expected) in samples {
            XCTAssertEqual(
                EditorFlowSettlementHighlight.strength(
                    elapsed: elapsed,
                    isDark: isDark,
                    increaseContrast: increaseContrast,
                    reduceMotion: reduceMotion
                ),
                expected,
                accuracy: 0.001
            )
        }
    }

    func testActiveSettlementAndGhostTextUseAccentWhenThemeChanges() throws {
        let source = "teh."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.undoManager?.removeAllActions()
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            textView.flowSuggestion = nil
            textView.string = suggestion.correctedSentence
            textView.setSelectedRange(NSRange(
                location: (suggestion.correctedSentence as NSString).length,
                length: 0
            ))
            return true
        }

        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "teh",
            replacement: "the"
        )
        XCTAssertTrue(textView.presentFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)

        let darkTheme = AppTheme.defaultDark
        textView.applyFlowThemeForTesting(darkTheme)
        let darkColor = try XCTUnwrap(textView.flowSettlementHighlightColorForTesting(elapsed: 1.25))
        let expectedDark = try XCTUnwrap(
            NSColor(hex: darkTheme.background).blended(
                withFraction: 0.24,
                of: NSColor(hex: darkTheme.accent)
            )
        )
        let oldDarkSkillColor = try XCTUnwrap(
            NSColor(hex: darkTheme.background).blended(
                withFraction: 0.24,
                of: NSColor(hex: darkTheme.semanticColors.skill)
            )
        )
        let expectedDarkGhost = NSColor(hex: AppTheme.blendHex(
            darkTheme.foreground,
            toward: darkTheme.accent,
            amount: 0.42
        ))
        XCTAssertTrue(darkColor.isEqual(expectedDark))
        XCTAssertFalse(darkColor.isEqual(oldDarkSkillColor))
        XCTAssertTrue(textView.flowGhostTextColorForTesting.isEqual(expectedDarkGhost))

        let lightTheme = AppTheme.defaultLight
        textView.applyFlowThemeForTesting(lightTheme)
        let lightColor = try XCTUnwrap(textView.flowSettlementHighlightColorForTesting(elapsed: 1.25))
        let expectedLight = try XCTUnwrap(
            NSColor(hex: lightTheme.background).blended(
                withFraction: 0.18,
                of: NSColor(hex: lightTheme.accent)
            )
        )
        let oldLightSkillColor = try XCTUnwrap(
            NSColor(hex: lightTheme.background).blended(
                withFraction: 0.18,
                of: NSColor(hex: lightTheme.semanticColors.skill)
            )
        )
        let expectedLightGhost = NSColor(hex: AppTheme.blendHex(
            lightTheme.foreground,
            toward: lightTheme.accent,
            amount: 0.54
        ))
        XCTAssertTrue(lightColor.isEqual(expectedLight))
        XCTAssertFalse(lightColor.isEqual(oldLightSkillColor))
        XCTAssertTrue(textView.flowGhostTextColorForTesting.isEqual(expectedLightGhost))
        XCTAssertFalse(lightColor.isEqual(darkColor))
        XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)
    }

    func testInlineReviewUsesNormalTextAndHighlightsOnlyChangedWordWithThemeAccent() async throws {
        let source = "I will definitly send the report."
        let corrected = "I will definitely send the report."
        let sourceText = source as NSString
        let correctedText = corrected as NSString
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let typoRange = sourceText.range(of: "definitly")
        let suggestion = EditorFlowSuggestion(
            documentID: try XCTUnwrap(coordinator.documentID),
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
            sentenceRange: NSRange(location: 0, length: sourceText.length),
            originalSentence: source,
            correctedSentence: corrected,
            source: .deterministic,
            acceptance: .reviewOnly,
            edits: [EditorFlowCorrectionEdit(
                range: typoRange,
                originalText: sourceText.substring(with: typoRange),
                replacementText: "definitely",
                kind: .spelling
            )]
        )
        let theme = AppTheme.defaultDark.replacing(accent: "#20B486")
        textView.applyFlowThemeForTesting(theme)
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)

        let changedWord = correctedText.range(of: "definitely")
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertEqual(textView.flowReviewHighlightRangesForTesting, [changedWord])
        XCTAssertTrue(textView.flowReviewTextColorForTesting.isEqual(NSColor(theme.foregroundColor)))
        XCTAssertFalse(textView.flowReviewTextColorForTesting.isEqual(textView.flowGhostTextColorForTesting))
        let highlight = try XCTUnwrap(textView.flowReviewHighlightColorForTesting())
        let expected = try XCTUnwrap(
            NSColor(hex: theme.background).blended(
                withFraction: 0.24,
                of: NSColor(hex: theme.accent)
            )
        )
        let oldSkill = try XCTUnwrap(
            NSColor(hex: theme.background).blended(
                withFraction: 0.24,
                of: NSColor(hex: theme.semanticColors.skill)
            )
        )
        XCTAssertTrue(highlight.isEqual(expected))
        XCTAssertFalse(highlight.isEqual(oldSkill))
        XCTAssertEqual(textView.string, source)
    }

    func testDeletionOnlySettlementHighlightsSurvivorAndDeleteRestoresCollapsedCaret() async throws {
        let source = "The migration migration are complete but two checks still needs owners."
        let corrected = "The migration are complete but two checks still needs owners."
        let sourceText = source as NSString
        let correctedText = corrected as NSString
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

        let originalCaret = NSRange(location: sourceText.length, length: 0)
        textView.setSelectedRange(originalCaret)
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()
        let firstMigration = sourceText.range(of: "migration")
        let removedDuplicate = sourceText.range(of: " migration", options: [], range: NSRange(
            location: NSMaxRange(firstMigration),
            length: sourceText.length - NSMaxRange(firstMigration)
        ))
        let suggestion = EditorFlowSuggestion(
            documentID: try XCTUnwrap(coordinator.documentID),
            revision: coordinator.revision,
            selectedRange: originalCaret,
            caretUTF16Offset: originalCaret.location,
            sentenceRange: NSRange(location: 0, length: sourceText.length),
            originalSentence: source,
            correctedSentence: corrected,
            source: .ai,
            acceptance: .direct,
            edits: [EditorFlowCorrectionEdit(
                range: removedDuplicate,
                originalText: sourceText.substring(with: removedDuplicate),
                replacementText: "",
                kind: .grammar
            )]
        )

        XCTAssertTrue(textView.presentFlowSuggestion(suggestion))
        let survivingMigration = correctedText.range(of: "migration")
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: correctedText.length, length: 0))
        XCTAssertEqual(textView.flowSettlementRangesForTesting, [survivingMigration])
        XCTAssertEqual(
            textView.flowSettlementDeletionCollapseRangesForTesting,
            [survivingMigration]
        )
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Removed migration") == true)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)

        try? await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertEqual(textView.flowSettlementRangesForTesting, [survivingMigration])
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{7f}",
            modifiers: [],
            keyCode: 51,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertEqual(textView.selectedRange(), originalCaret)
        XCTAssertEqual(textView.selectedRange().length, 0)
        XCTAssertNil(textView.flowSettlementRangesForTesting)
        XCTAssertNil(textView.flowSettlementDeletionCollapseRangesForTesting)
        XCTAssertFalse(textView.accessibilityHelp()?.contains("Delete to undo") == true)
    }

    func testSettledCorrectionClearsOnlyForIntentionalEditorInteractions() async throws {
        let source = "teh."
        let corrected = "the."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        var didDismantle = false
        defer {
            if !didDismantle {
                dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
            }
        }

        func settleCorrection() {
            textView.string = source
            textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            textView.flowSuggestionAcceptanceHandler = { suggestion in
                textView.flowSuggestion = nil
                textView.string = suggestion.correctedSentence
                textView.setSelectedRange(NSRange(
                    location: (suggestion.correctedSentence as NSString).length,
                    length: 0
                ))
                return true
            }
            let suggestion = EditorFlowSuggestion(
                documentID: "note.md",
                revision: 0,
                selectedRange: textView.selectedRange(),
                caretUTF16Offset: textView.selectedRange().location,
                sentenceRange: NSRange(location: 0, length: (source as NSString).length),
                originalSentence: source,
                correctedSentence: corrected,
                source: .deterministic,
                edits: [EditorFlowCorrectionEdit(
                    range: NSRange(location: 0, length: 3),
                    originalText: "teh",
                    replacementText: "the",
                    kind: .spelling
                )]
            )
            XCTAssertTrue(textView.presentFlowSuggestion(suggestion))
            XCTAssertEqual(textView.string, corrected)
            XCTAssertEqual(textView.flowSettlementRangesForTesting?.count, 1)
        }

        settleCorrection()
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSettlementRangesForTesting)

        settleCorrection()
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "x",
            modifiers: [],
            keyCode: 7,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSettlementRangesForTesting)

        settleCorrection()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        XCTAssertNil(textView.flowSettlementRangesForTesting)

        settleCorrection()
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        XCTAssertNil(textView.flowSettlementRangesForTesting)

        XCTAssertTrue(window.makeFirstResponder(textView))
        settleCorrection()
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(textView.flowSettlementRangesForTesting)

        XCTAssertTrue(window.makeFirstResponder(textView))
        settleCorrection()
        dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator)
        didDismantle = true
        XCTAssertNil(textView.flowSettlementRangesForTesting)
    }

    func testDuplicateAppleGrammarAndCorrectionResultsPresentOneDeterministicSuggestion() async throws {
        let source = "This is a important note"
        let completed = source + "."
        let box = EditorTextBox(source)
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let issueRange = (checkedText as NSString).range(of: "a")
                completion([
                    self.grammarResult(
                        in: checkedText,
                        target: "a",
                        corrections: ["an"]
                    ),
                    NSTextCheckingResult.correctionCheckingResult(
                        range: issueRange,
                        replacementString: "an"
                    ),
                ], self.englishOrthography())
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
            inlinePredictions: false,
            onDeviceProseCompletions: false
        )
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .markdown, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "This is an important note." }
        XCTAssertTrue(settled)
        let suggestion = try XCTUnwrap(acceptedSuggestion)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(suggestion.source, .deterministic)
        XCTAssertEqual(suggestion.originalSentence, completed)
        XCTAssertEqual(suggestion.correctedSentence, "This is an important note.")
        XCTAssertEqual(suggestion.edits, [
            EditorFlowCorrectionEdit(
                range: (completed as NSString).range(of: "a"),
                originalText: "a",
                replacementText: "an",
                kind: .spelling
            ),
        ])
    }

    func testAppleBatchWithAmbiguousShorteningSpellingRepairSelectsVerifiedAlternative() async throws {
        let source = "The release checklist [verfy backups and notifiy owners] is ready for the rehearsal,\nand Project Cedar have no other blocking issue"
        let completed = source + "."
        let expected = "The release checklist [verify backups and notify owners] is ready for the rehearsal,\nand Project Cedar has no other blocking issue."
        let box = EditorTextBox(source)
        var candidateRequestRanges: [NSRange] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    let checkedSource = checkedText as NSString
                    if checkedText == completed {
                        completion([
                            NSTextCheckingResult.correctionCheckingResult(
                                range: checkedSource.range(of: "verfy"),
                                replacementString: "very"
                            ),
                            NSTextCheckingResult.correctionCheckingResult(
                                range: checkedSource.range(of: "notifiy"),
                                replacementString: "notify"
                            ),
                            self.grammarResult(
                                in: checkedText,
                                target: "have",
                                corrections: ["has"]
                            ),
                        ], self.englishOrthography())
                    } else if checkedText.contains("[Verny backups") {
                        completion([
                            NSTextCheckingResult.spellCheckingResult(
                                range: checkedSource.range(of: "Verny")
                            ),
                        ], self.englishOrthography())
                    } else {
                        completion([], self.englishOrthography())
                    }
                },
                requestCandidates: { checkedText, range, _, _, completion in
                    candidateRequestRanges.append(range)
                    let original = (checkedText as NSString).substring(with: range)
                    let replacements = original == "verfy"
                        ? ["verfy ", "verify ", "very ", "Verny "]
                        : ["notifiy ", "notify "]
                    completion(replacements.map {
                        NSTextCheckingResult.replacementCheckingResult(
                            range: range,
                            replacementString: $0
                        )
                    })
                }
            )
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.reviewAlternatives?.replacementTexts == ["very", "verify"]
        }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowSuggestion)
        XCTAssertEqual(suggestion.source, .deterministic)
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        XCTAssertEqual(suggestion.reviewAlternatives?.kind, .spelling)
        XCTAssertEqual(suggestion.correctedSentence.contains("very backups"), true)
        XCTAssertTrue(suggestion.correctedSentence.contains("notify owners"))
        XCTAssertEqual(candidateRequestRanges, [
            (completed as NSString).range(of: "verfy"),
            (completed as NSString).range(of: "notifiy"),
        ])
        XCTAssertEqual(textView.string, completed)

        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))
        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(box.value, completed)
        XCTAssertEqual(
            textView.selectedFlowReviewSuggestionForTesting?.correctedSentence,
            expected
        )
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, expected)
        XCTAssertEqual(box.value, expected)
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)
        XCTAssertFalse(textView.confirmFlowReviewSuggestionForTesting())
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(box.value, completed)
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, expected)
        XCTAssertEqual(box.value, expected)
    }

    func testShorteningSpellingWaitsForAsyncCandidatesAndKeepsAuthoritativePrimary() async throws {
        let source = "The package is comming"
        let completed = source + "."
        let box = EditorTextBox(source)
        var heldCandidates: EditorFlowCheckingClient.CandidateCompletion?
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    if checkedText == completed {
                        completion([
                            NSTextCheckingResult.correctionCheckingResult(
                                range: (checkedText as NSString).range(of: "comming"),
                                replacementString: "coming"
                            ),
                        ], self.englishOrthography())
                    } else {
                        completion([], self.englishOrthography())
                    }
                },
                requestCandidates: { _, _, _, _, completion in
                    heldCandidates = completion
                }
            )
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let candidateRequestStarted = await waitUntil { heldCandidates != nil }
        XCTAssertTrue(candidateRequestStarted)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .no)

        let range = (completed as NSString).range(of: "comming")
        try XCTUnwrap(heldCandidates)([
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "comming "
            ),
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "coming "
            ),
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "combing "
            ),
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "comping "
            ),
        ])
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.reviewAlternatives?.replacementTexts
                == ["coming", "combing", "comping"]
        }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowSuggestion)
        XCTAssertEqual(suggestion.correctedSentence, "The package is coming.")
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        XCTAssertEqual(suggestion.reviewAlternatives?.kind, .spelling)
        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, completed)
    }

    func testAsyncSpellingCandidateCallbackIsIgnoredAfterFocusCancellation() async throws {
        let source = "The package is comming"
        let completed = source + "."
        let box = EditorTextBox(source)
        var heldCandidates: EditorFlowCheckingClient.CandidateCompletion?
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "comming"),
                            replacementString: "coming"
                        ),
                    ], self.englishOrthography())
                },
                requestCandidates: { _, _, _, _, completion in
                    heldCandidates = completion
                }
            )
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let candidateRequestStarted = await waitUntil { heldCandidates != nil }
        XCTAssertTrue(candidateRequestStarted)
        coordinator.cancelFlowForFocusLoss()
        let range = (completed as NSString).range(of: "comming")
        try XCTUnwrap(heldCandidates)([
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "coming "
            ),
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "combing "
            ),
        ])
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(box.value, completed)
    }

    func testAsyncSpellingCandidateTimeoutTerminatesOnceAndIgnoresLateCallback() async throws {
        let source = "The package is comming"
        let completed = source + "."
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        var heldCandidates: EditorFlowCheckingClient.CandidateCompletion?
        let coordinator = MarkdownTextEditor.Coordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "comming"),
                            replacementString: "coming"
                        ),
                    ], self.englishOrthography())
                },
                requestCandidates: { _, _, _, _, completion in
                    heldCandidates = completion
                }
            ),
            flowCheckingTimeoutNanoseconds: 5_000_000,
            flowFocusValidator: { _ in true }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let candidateRequestStarted = await waitUntil { heldCandidates != nil }
        XCTAssertTrue(candidateRequestStarted)
        let timedOut = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .checkerTimedOut
            }
        }
        XCTAssertTrue(timedOut)
        let timeoutEvent = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .checkerTimedOut
        )
        let terminal = try XCTUnwrap(timeoutEvent)
        XCTAssertTrue(terminal.nativeFallbackRestored)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.inlinePredictionType, .default)

        let range = (completed as NSString).range(of: "comming")
        try XCTUnwrap(heldCandidates)([
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "coming "
            ),
            NSTextCheckingResult.replacementCheckingResult(
                range: range,
                replacementString: "combing "
            ),
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(box.value, completed)
        XCTAssertEqual(
            diagnostics.events.filter {
                $0.owner == terminal.owner && $0.token == terminal.token
            }.count,
            1
        )
    }

    func testTwoAmbiguousSpellingRangesFailClosedWithoutValidationOrModelCall() async throws {
        let source = "Please verfy backups and notifiy owners"
        let completed = source + "."
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let checkingRequestCount = EditorIntBox()
        let modelCallCount = EditorIntBox()
        var candidateRequestRanges: [NSRange] = []
        let checkingClient = EditorFlowCheckingClient(
            { checkedText, _, _, _, completion in
                checkingRequestCount.value += 1
                guard checkedText == completed else {
                    completion([], self.englishOrthography())
                    return
                }
                let checkedSource = checkedText as NSString
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: checkedSource.range(of: "verfy"),
                        replacementString: "very"
                    ),
                    NSTextCheckingResult.correctionCheckingResult(
                        range: checkedSource.range(of: "notifiy"),
                        replacementString: "notify"
                    ),
                ], self.englishOrthography())
            },
            requestCandidates: { checkedText, range, _, _, completion in
                candidateRequestRanges.append(range)
                let original = (checkedText as NSString).substring(with: range)
                let replacements = original == "verfy"
                    ? ["verfy ", "very ", "verify "]
                    : ["notifiy ", "notify ", "notified "]
                completion(replacements.map {
                    NSTextCheckingResult.replacementCheckingResult(
                        range: range,
                        replacementString: $0
                    )
                })
            }
        )
        let unavailableModel = FlowSentenceRepairService(isAvailable: { _ in false }) { _, _ in
            modelCallCount.value += 1
            return nil
        }
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: checkingClient,
            sentenceRepair: unavailableModel
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: true,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let failedClosed = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .modelUnavailable
            }
        }
        XCTAssertTrue(failedClosed)
        let event = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .modelUnavailable
        )

        XCTAssertEqual(checkingRequestCount.value, 1)
        XCTAssertEqual(modelCallCount.value, 0)
        XCTAssertEqual(candidateRequestRanges, [
            (completed as NSString).range(of: "verfy"),
            (completed as NSString).range(of: "notifiy"),
        ])
        XCTAssertTrue(event?.nativeFallbackRestored == true)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(box.value, completed)
        XCTAssertEqual(textView.inlinePredictionType, .default)
    }

    func testNonshrinkingSpellingCorrectionDoesNotRequestCandidates() async throws {
        let source = "The dogs are playig"
        let box = EditorTextBox(source)
        let candidateRequestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "playig"),
                            replacementString: "playing"
                        ),
                    ], self.englishOrthography())
                },
                requestCandidates: { _, _, _, _, completion in
                    candidateRequestCount.value += 1
                    completion([])
                }
            )
        )
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: false,
            inlinePredictions: false
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "The dogs are playing." }
        XCTAssertTrue(settled)
        XCTAssertEqual(candidateRequestCount.value, 0)
        XCTAssertEqual(acceptedSuggestion?.correctedSentence, "The dogs are playing.")
        XCTAssertEqual(acceptedSuggestion?.acceptance, .direct)
        XCTAssertNil(textView.flowSuggestion)
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
            acceptance: .reviewOnly,
            edits: [EditorFlowCorrectionEdit(
                range: grammarRange,
                originalText: "is",
                replacementText: "are",
                kind: .grammar
            )]
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))

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
        let settled = await waitUntil { textView.string == "The dogs are playing." }
        XCTAssertTrue(settled)
        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "The dogs is playig.",
            "The dogs am playing.",
            "The dogs are playing.",
        ])
        XCTAssertTrue(requestedTypes.dropFirst().allSatisfy {
            $0 & NSTextCheckingResult.CheckingType.spelling.rawValue != 0
                && $0 & NSTextCheckingResult.CheckingType.grammar.rawValue != 0
        })
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "The dogs are playing.")
        XCTAssertEqual(box.value, "The dogs are playing.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 2)
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
                guard checkedText == source + "." else {
                    completion([], nil)
                    return
                }
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "teh dogs are ready." }
        XCTAssertTrue(settled)
        XCTAssertNotEqual(
            requestedTypes & NSTextCheckingResult.CheckingType.spelling.rawValue,
            0
        )
        XCTAssertNotEqual(
            requestedTypes & NSTextCheckingResult.CheckingType.grammar.rawValue,
            0
        )
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["is"])
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["are"])
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "teh dogs are ready." }
        XCTAssertTrue(settled)

        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "teh dogs is ready.",
            "teh dogs are ready.",
            "teh dogs were ready.",
        ])
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["is"])
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["are"])
        XCTAssertEqual(acceptedSuggestion?.correctedSentence, "teh dogs are ready.")
        XCTAssertFalse(acceptedSuggestion?.exactChangeDescription.contains("teh") == true)
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

    func testAmbiguousGrammarValidationOffersMultipleCleanAlternativesForReview() async throws {
        let source = "They is ready"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                if checkedText == completedSource {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["are", "were", "be"]
                        ),
                    ], self.englishOrthography())
                    return
                }
                if checkedText.contains(" are ") || checkedText.contains(" were ") {
                    completion([], self.englishOrthography())
                    return
                }
                completion([
                    self.grammarResult(
                        in: checkedText,
                        target: "be",
                        corrections: ["is"]
                    ),
                ], self.englishOrthography())
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.reviewAlternatives?.replacementTexts.count == 2
        }
        XCTAssertTrue(suggestionReady)
        let suggestion = try XCTUnwrap(textView.flowSuggestion)
        XCTAssertEqual(requestedTexts, [
            "They is ready.",
            "They are ready.",
            "They were ready.",
            "They be ready.",
        ])
        XCTAssertEqual(suggestion.acceptance, .reviewOnly)
        XCTAssertEqual(suggestion.correctedSentence, "They are ready.")
        XCTAssertEqual(
            suggestion.reviewAlternatives,
            EditorFlowReviewAlternatives(
                absoluteRange: (completedSource as NSString).range(of: "is"),
                replacementTexts: ["are", "were"],
                kind: .grammar
            )
        )

        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{F703}",
            modifiers: [.numericPad, .function],
            keyCode: 124,
            windowNumber: window.windowNumber
        )))
        XCTAssertTrue(textView.isFlowReviewPreviewShown)
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(
            textView.selectedFlowReviewSuggestionForTesting?.correctedSentence,
            "They were ready."
        )
        XCTAssertEqual(
            textView.selectedFlowReviewSuggestionForTesting?.edits.map(\.replacementText),
            ["were"]
        )

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "They were ready.")
        XCTAssertEqual(box.value, "They were ready.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)
        XCTAssertFalse(textView.confirmFlowReviewSuggestionForTesting())
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(box.value, completedSource)
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

    func testAmbiguousGrammarValidationBoundsMoreThanThreeAlternatives() async {
        let source = "They is ready"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                if checkedText == completedSource {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["is", "are", "are", "were", "be", "am"]
                        ),
                    ], self.englishOrthography())
                } else if checkedText.contains(" are ") || checkedText.contains(" were ") {
                    completion([], self.englishOrthography())
                } else {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "be",
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
        let reviewReady = await waitUntil {
            textView.flowSuggestion?.reviewAlternatives?.replacementTexts == ["are", "were"]
        }
        XCTAssertTrue(reviewReady)

        XCTAssertEqual(requestedTexts, [
            "They is ready.",
            "They are ready.",
            "They were ready.",
            "They be ready.",
        ])
        XCTAssertFalse(requestedTexts.contains("They am ready."))
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, "They are ready.")
        XCTAssertEqual(textView.string, completedSource)
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "the and weird." }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            acceptedSuggestion?.edits.map(\.originalText),
            ["teh", "adn", "wierd"]
        )
        XCTAssertEqual(
            acceptedSuggestion?.edits.map(\.replacementText),
            ["the", "and", "weird"]
        )
        XCTAssertEqual(acceptedSuggestion?.originalSentence, "teh adn wierd.")
        XCTAssertEqual(acceptedSuggestion?.correctedSentence, "the and weird.")
        XCTAssertTrue(acceptedSuggestion?.accessibilityText.contains(
            "replace “wierd” with “weird”"
        ) == true)
        XCTAssertEqual(textView.string, "the and weird.")
        XCTAssertEqual(box.value, "the and weird.")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh adn wierd.")
        XCTAssertEqual(box.value, "teh adn wierd.")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil {
            textView.string == "the prose `tehcode` [guide](teh-link.md) and."
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["teh", "adn"])
        XCTAssertNil(textView.flowSuggestion)
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "- teh cats is ready\n- ")
        XCTAssertEqual(box.value, "- teh cats is ready\n- ")
        let triggeredSource = textView.string as NSString
        let newlineLocation = triggeredSource.range(of: "\n").location
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        let settled = await waitUntil { textView.string == "- the cats are ready\n- " }
        XCTAssertTrue(settled)
        let suggestion = try XCTUnwrap(acceptedSuggestion)
        XCTAssertEqual(NSMaxRange(suggestion.sentenceRange), newlineLocation)
        XCTAssertLessThan(NSMaxRange(suggestion.sentenceRange), (textView.string as NSString).length)
        XCTAssertTrue(checkedTexts.contains { $0.contains("teh cats is ready") })
        XCTAssertEqual(
            acceptedSuggestion?.exactChangeDescription,
            "replace “teh” with “the”, replace “is” with “are”"
        )
        XCTAssertEqual(
            acceptedSuggestion?.edits.map(\.range),
            [
                NSRange(location: 2, length: 3),
                NSRange(location: 11, length: 2),
            ]
        )
        XCTAssertEqual(textView.string, "- the cats are ready\n- ")
        XCTAssertEqual(box.value, "- the cats are ready\n- ")
        XCTAssertNil(textView.flowSuggestion)
    }

    func testNoneditableReturnThatInsertsNoNewlineNeverStartsSentenceBatch() async throws {
        let source = "teh sentence is ready"
        let box = EditorTextBox(source)
        let checkerCalls = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                checkerCalls.value += 1
                completion([], self.englishOrthography())
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
        textView.isEditable = false

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertEqual(checkerCalls.value, 0)
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
            replacement: "the",
            acceptance: .reviewOnly
        )
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(try XCTUnwrap(
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
            replacement: "the",
            acceptance: .reviewOnly
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
            replacement: "the",
            acceptance: .reviewOnly
        )
        textView.undoManager?.removeAllActions()
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(try XCTUnwrap(
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
        XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(try XCTUnwrap(
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

    func testPunctuationFollowedImmediatelyByOneSpaceStillSettlesCompletedSentenceRepair() async throws {
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
        let settled = await waitUntil { textView.string == "the. " }
        XCTAssertTrue(settled)
        XCTAssertNil(textView.flowSuggestion)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "N",
            modifiers: [.shift],
            keyCode: 45,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "the. N")
    }

    func testEscapeThenContinuedTypingDoesNotReofferTheSameCorrection() async throws {
        let source = "writting"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "writting", replacement: "writing")
        let coordinator = makeCoordinator(box, flowCheckingClient: checker.client)
        let diagnostics = FlowDiagnosticEventBox()
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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
        diagnostics.removeAll()
        textView.setSelectedRange(NSRange(location: (completedSource as NSString).length, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let followUpCheckFinished = await waitUntil { checker.requestCount > requestsBeforeReturn }
        XCTAssertTrue(followUpCheckFinished)
        let suppressionFinished = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
            }
        }
        XCTAssertTrue(suppressionFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(textView.string, "writting. Other.")
        XCTAssertNil(textView.flowSuggestion)
        let terminal = try XCTUnwrap(diagnostics.events.first(where: {
            $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
        }))
        XCTAssertEqual(
            diagnostics.events.filter {
                $0.owner == terminal.owner && $0.token == terminal.token
            }.map(\.reason),
            [.suppressedDuplicate]
        )
    }

    func testDismissedDeterministicRepairDoesNotSuppressExpandedSameSentenceRepair() async throws {
        let source = "writting report"
        let completedSource = source + "."
        let expandedSource = "writting report is redy."
        let corrected = "writing report is ready."
        let box = EditorTextBox(source)
        let checkerCount = EditorIntBox()
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                checkerCount.value += 1
                let checked = checkedText as NSString
                var results: [NSTextCheckingResult] = []
                let first = checked.range(of: "writting")
                if first.location != NSNotFound {
                    results.append(NSTextCheckingResult.correctionCheckingResult(
                        range: first,
                        replacementString: "writing"
                    ))
                }
                let second = checked.range(of: "redy")
                if second.location != NSNotFound {
                    results.append(NSTextCheckingResult.correctionCheckingResult(
                        range: second,
                        replacementString: "ready"
                    ))
                }
                completion(results, self.englishOrthography())
            }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let recordingTextView = FlowChangeRecordingTextView()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source,
            textView: recordingTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        textView.flowSourceMode = .markdown
        textView.applyTextChecking(.defaultValue)
        coordinator.configureFlow(mode: .markdown, options: .defaultValue)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let initialSuggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 1 }
        XCTAssertTrue(initialSuggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        )))
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, completedSource)

        let periodLocation = (completedSource as NSString).length - 1
        textView.insertText(
            " is redy",
            replacementRange: NSRange(location: periodLocation, length: 0)
        )
        XCTAssertEqual(textView.string, expandedSource)
        diagnostics.removeAll()
        textView.setSelectedRange(NSRange(location: (expandedSource as NSString).length, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let expandedRepairReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == corrected
        }
        XCTAssertTrue(expandedRepairReady)
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["writting", "redy"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["writing", "ready"])
        XCTAssertFalse(diagnostics.events.contains { $0.reason == .suppressedDuplicate })

        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        XCTAssertEqual(recordingTextView.approvedChanges.count, 1)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, expandedSource)
        XCTAssertEqual(box.value, expandedSource)
        XCTAssertGreaterThanOrEqual(checkerCount.value, 2)
    }

    func testDismissedCorrectionCanReappearForANewlyTypedTarget() async throws {
        let source = "writting"
        let box = EditorTextBox(source)
        let checker = ImmediateSpellingFlowChecker(original: "writting", replacement: "writing")
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

        textView.insertText("writing", replacementRange: NSRange(location: 0, length: 8))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        // Use a paragraph boundary so this is unambiguously a newly authored
        // target rather than a lowercase hard-wrapped continuation.
        textView.insertText("\n\n", replacementRange: textView.selectedRange())
        let newTargetLocation = (textView.string as NSString).length
        textView.insertText("writting.", replacementRange: textView.selectedRange())
        let newSuggestionReady = await waitUntil {
            textView.flowSuggestion?.edits.first?.range.location == newTargetLocation
        }

        XCTAssertTrue(newSuggestionReady)
        XCTAssertEqual(textView.string, "writing.\n\nwritting.")
        XCTAssertEqual(
            textView.flowSuggestion?.edits.first?.range,
            NSRange(location: newTargetLocation, length: 8)
        )
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “writting” with “writing”"
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
        let settled = await waitUntil { textView.string == "the." }
        XCTAssertTrue(settled)
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

    func testAcceptedAIRepairUndoStaysSuppressedUntilSentenceMeaningfullyChanges() async throws {
        let source = "I am writng clearly"
        let completedSource = source + "."
        let firstCorrected = "I am writing clearly."
        let mutatedSource = "I am writng briefly."
        let mutatedCorrected = "I am writing briefly."
        let box = EditorTextBox(source)
        let aiRequestCount = EditorIntBox()
        let diagnostics = FlowDiagnosticEventBox()
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { request, _ in
                aiRequestCount.value += 1
                return request.sentence.replacingOccurrences(of: "writng", with: "writing")
            }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                let typoRange = (checkedText as NSString).range(of: "writng")
                if typoRange.location == NSNotFound {
                    completion([], self.englishOrthography())
                } else {
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: typoRange,
                            replacementString: ""
                        ),
                    ], self.englishOrthography())
                }
            },
            sentenceRepair: sentenceRepair
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
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
        let firstRepairReady = await waitUntil { textView.string == firstCorrected }
        XCTAssertTrue(firstRepairReady)
        XCTAssertEqual(aiRequestCount.value, 1)
        XCTAssertEqual(textView.string, firstCorrected)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(box.value, completedSource)
        diagnostics.removeAll()
        textView.setSelectedRange(NSRange(location: (completedSource as NSString).length, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let suppressionFinished = await waitUntil {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
            }
        }
        XCTAssertTrue(suppressionFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(aiRequestCount.value, 1, "Undo to the exact source must not call the model again")
        XCTAssertNil(textView.flowSuggestion)
        let terminal = try XCTUnwrap(diagnostics.events.first(where: {
            $0.owner == .sentenceRepair && $0.reason == .suppressedDuplicate
        }))
        XCTAssertEqual(
            diagnostics.events.filter {
                $0.owner == terminal.owner && $0.token == terminal.token
            }.map(\.reason),
            [.suppressedDuplicate]
        )

        let meaningRange = (textView.string as NSString).range(of: "clearly")
        textView.insertText("briefly", replacementRange: meaningRange)
        XCTAssertEqual(textView.string, mutatedSource)
        diagnostics.removeAll()
        textView.setSelectedRange(NSRange(location: (mutatedSource as NSString).length, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let changedRepairReady = await waitUntil {
            aiRequestCount.value == 2
                && textView.string == mutatedCorrected
                && textView.flowSuggestion == nil
        }
        XCTAssertTrue(changedRepairReady)
        XCTAssertEqual(aiRequestCount.value, 2)
        XCTAssertFalse(diagnostics.events.contains { $0.reason == .suppressedDuplicate })
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
        let source = "writting"
        let box = EditorTextBox(source)
        let focus = EditorBoolBox(true)
        let checker = ImmediateSpellingFlowChecker(original: "writting", replacement: "writing")
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
        XCTAssertEqual(textView.string, "writting.")
        XCTAssertEqual(
            textView.flowSuggestion?.exactChangeDescription,
            "replace “writting” with “writing”"
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
        textView.applyTextChecking(.defaultValue)
        let writingToolsReady = await prepareWritingTools(coordinator, textView: textView)
        XCTAssertTrue(writingToolsReady)
        coordinator.onWritingToolsStateChange = { _, _ in false }
        textView.flowSuggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "Text",
            replacement: "Draft"
        )
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .no)

        coordinator.textViewWritingToolsWillBegin(textView)

        XCTAssertFalse(coordinator.isWritingToolsActive)
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertNil(textView.flowProseSuggestion)
        XCTAssertFalse(textView.isFlowReviewPreviewShown)
        let nativeReleased = await waitUntil {
            textView.flowWritingToolsReady && textView.inlinePredictionType == .default
        }
        XCTAssertTrue(nativeReleased)
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

    func testFindHighlightApplyAndClearPreserveAuthoritativeFlowSourceTint() async throws {
        let source = "The dogs is ready."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let changedRange = (source as NSString).range(of: "is")
        let suggestion = flowSuggestion(
            coordinator: coordinator,
            textView: textView,
            checkedText: "is",
            replacement: "are",
            acceptance: .reviewOnly
        )
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let initialFlowColor = try XCTUnwrap(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: changedRange.location,
            effectiveRange: nil
        ) as? NSColor)
        XCTAssertEqual(
            layoutManager.temporaryAttribute(
                .spellingState,
                atCharacterIndex: changedRange.location,
                effectiveRange: nil
            ) as? Int,
            0
        )

        var search = DocumentSearchState()
        search.present()
        search.setQuery("is")
        // Find owns selection while its highlights change. Suppress only the
        // delegate cancellation so this test can isolate the overlapping
        // temporary-attribute handoff between Find and an otherwise exact cue.
        textView.delegate = nil
        defer { textView.delegate = coordinator }
        let result = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        search.updateResult(result)
        let colorAfterFindUpdate = try XCTUnwrap(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: changedRange.location,
            effectiveRange: nil
        ) as? NSColor)

        XCTAssertEqual(result.totalCount, 1)
        XCTAssertTrue(colorAfterFindUpdate.isEqual(initialFlowColor))
        XCTAssertEqual(textView.flowSuggestion, suggestion)

        textView.setSelectedRange(suggestion.selectedRange)
        search.dismiss()
        XCTAssertEqual(coordinator.applySearch(search, theme: .defaultDark, in: textView), .init())
        let colorAfterFindClear = try XCTUnwrap(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: changedRange.location,
            effectiveRange: nil
        ) as? NSColor)

        XCTAssertTrue(colorAfterFindClear.isEqual(initialFlowColor))
        XCTAssertEqual(textView.flowSuggestion, suggestion)
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
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            return coordinator.acceptFlowSuggestion(suggestion)
        }

        textView.insertText(".", replacementRange: textView.selectedRange())
        let settled = await waitUntil { textView.string == "teh dogs were ready." }

        XCTAssertTrue(settled, file: file, line: line)
        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "teh dogs is ready.",
            "teh dogs are ready.",
            "teh dogs were ready.",
        ], file: file, line: line)
        XCTAssertNil(textView.flowSuggestion, file: file, line: line)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["is"], file: file, line: line)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["were"], file: file, line: line)
        XCTAssertFalse(
            acceptedSuggestion?.exactChangeDescription.contains("teh") == true,
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

    private func frozenSourceMode(for testCase: FlowWritingRepairCase) -> FlowSourceMode {
        if testCase.expectation == .protectedUnsafe { return .markdown }
        let suffix = testCase.id.split(separator: "-").last.flatMap { Int($0) } ?? 1
        return suffix.isMultiple(of: 2) ? .plainText : .markdown
    }

    private func runFrozenCoordinatorCorpus(
        inputPath: FrozenCorpusInputPath,
        shard: FrozenCorpusShard
    ) async throws {
        assertFrozenHostedCorpusContract()
        var exactCount = 0
        var protectedCount = 0
        var cleanCount = 0
        var aiDirectCount = 0
        var aiReviewCount = 0
        var aiRejectedCount = 0
        var markdownCount = 0
        var plainTextCount = 0
        var elapsedCases: [(id: String, milliseconds: Double)] = []
        let allCoordinatorCases = FlowWritingCorpus.repairCases.filter {
            $0.expectation != .aiInvariant
        }.sorted { left, right in
            if left.id == "repair-exact-022" { return true }
            if right.id == "repair-exact-022" { return false }
            return left.id < right.id
        }
        XCTAssertEqual(allCoordinatorCases.count, 40)
        let coordinatorCases = shard.includesNonAI ? allCoordinatorCases : []
        for testCase in coordinatorCases {
            if frozenSourceMode(for: testCase) == .plainText {
                plainTextCount += 1
            } else {
                markdownCount += 1
            }
            let startedAt = Date()
            switch testCase.expectation {
            case .exactDeterministic:
                exactCount += 1
                try await runFrozenDeterministicCorpusCase(testCase, inputPath: inputPath)
            case .protectedUnsafe:
                protectedCount += 1
                try await runFrozenProtectedCorpusCase(testCase, inputPath: inputPath)
            case .clean:
                cleanCount += 1
                try await runFrozenCleanCorpusCase(testCase, inputPath: inputPath)
            case .aiInvariant:
                XCTFail("Unexpected AI case in deterministic coordinator selection: \(testCase.id)")
            }
            elapsedCases.append((
                id: testCase.id,
                milliseconds: Date().timeIntervalSince(startedAt) * 1_000
            ))
        }

        let allAICases = FlowWritingCorpus.repairCases.filter {
            $0.expectation == .aiInvariant
        }.sorted { $0.id < $1.id }
        XCTAssertEqual(allAICases.count, 20)
        let aiCases = allAICases.filter { shard.includesAI(id: $0.id) }
        for testCase in aiCases {
            if frozenSourceMode(for: testCase) == .plainText {
                plainTextCount += 1
            } else {
                markdownCount += 1
            }
            let startedAt = Date()
            switch try await runFrozenAICorpusCase(testCase, inputPath: inputPath) {
            case .direct:
                aiDirectCount += 1
            case .review:
                aiReviewCount += 1
            case .rejected:
                aiRejectedCount += 1
            }
            elapsedCases.append((
                id: testCase.id,
                milliseconds: Date().timeIntervalSince(startedAt) * 1_000
            ))
        }

        let expectedDirectCount = aiCases.filter { $0.aiClassification == .direct }.count
        let expectedReviewCount = aiCases.filter { $0.aiClassification == .reviewOnly }.count
        XCTAssertEqual(exactCount, shard.includesNonAI ? 24 : 0)
        XCTAssertEqual(protectedCount, shard.includesNonAI ? 10 : 0)
        XCTAssertEqual(cleanCount, shard.includesNonAI ? 6 : 0)
        XCTAssertEqual(aiDirectCount, expectedDirectCount)
        XCTAssertEqual(aiReviewCount, expectedReviewCount)
        XCTAssertEqual(aiRejectedCount, 0)
        XCTAssertEqual(
            markdownCount + plainTextCount,
            coordinatorCases.count + aiCases.count
        )
        XCTAssertEqual(
            plainTextCount,
            (coordinatorCases + aiCases).filter { frozenSourceMode(for: $0) == .plainText }.count
        )
        let sortedElapsed = elapsedCases.map(\.milliseconds).sorted()
        let median = sortedElapsed[sortedElapsed.count / 2]
        let slowest = sortedElapsed.last ?? 0
        let medianText = String(format: "%.1f", median)
        let slowestText = String(format: "%.1f", slowest)
        print(
            "FLOW_CORPUS_RUNTIME path=\(inputPath) shard=\(shard) "
                + "executions=\(elapsedCases.count) "
                + "exact=\(exactCount) aiDirect=\(aiDirectCount) aiReview=\(aiReviewCount) "
                + "aiRejected=\(aiRejectedCount) protected=\(protectedCount) clean=\(cleanCount) "
                + "markdown=\(markdownCount) plainText=\(plainTextCount) "
                + "medianMs=\(medianText) slowestMs=\(slowestText)"
        )
        print(
            "FLOW_CORPUS_CASE_RUNTIME path=\(inputPath) shard=\(shard) "
                + elapsedCases.map {
                    "\($0.id):\(String(format: "%.1f", $0.milliseconds))"
                }.joined(separator: ",")
        )
    }

    private func assertFrozenHostedCorpusContract() {
        let cases = FlowWritingCorpus.repairCases
        XCTAssertEqual(cases.count, 60)
        XCTAssertEqual(cases.filter { $0.expectation == .exactDeterministic }.count, 24)
        XCTAssertEqual(cases.filter { $0.expectation == .protectedUnsafe }.count, 10)
        XCTAssertEqual(cases.filter { $0.expectation == .clean }.count, 6)
        XCTAssertEqual(cases.filter { $0.aiClassification == .direct }.count, 4)
        XCTAssertEqual(cases.filter { $0.aiClassification == .reviewOnly }.count, 16)
        XCTAssertEqual(cases.filter { frozenSourceMode(for: $0) == .plainText }.count, 25)
        XCTAssertEqual(cases.filter { frozenSourceMode(for: $0) == .markdown }.count, 35)
    }

    private func runFrozenDeterministicCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        var checkerTrace: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                guard let reference = self.corpusReferenceSlice(
                    for: checkedText,
                    in: testCase
                ) else {
                    checkerTrace.append("checked=\(checkedText.debugDescription) reference=nil")
                    completion([], self.englishOrthography())
                    return
                }
                let results = self.corpusCorrectionResults(
                    in: checkedText,
                    reference: reference
                )
                checkerTrace.append(
                    "checked=\(checkedText.debugDescription) "
                        + "reference=\(reference.debugDescription) results=\(results.count)"
                )
                completion(
                    results,
                    self.englishOrthography()
                )
            }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )
        let acceptanceCount = EditorIntBox()
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            acceptanceCount.value += 1
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )

        let suggestionReady = await waitUntil(timeout: 3) {
            acceptedSuggestion?.source == .deterministic
                || textView.flowSuggestion?.source == .deterministic
        }
        XCTAssertTrue(
            suggestionReady,
            "No exact deterministic proposal for \(testCase.id) via \(inputPath); "
                + checkerTrace.joined(separator: " | ")
        )
        let suggestion = try XCTUnwrap(
            acceptedSuggestion ?? textView.flowSuggestion,
            "Missing deterministic result for \(testCase.id)"
        )
        XCTAssertEqual(suggestion.source, .deterministic)
        let hasLetterDeletingSpellingRepair = suggestion.edits.contains { edit in
            edit.kind == .spelling
                && edit.replacementText.filter { $0.isLetter || $0.isNumber }.count
                    < edit.originalText.filter { $0.isLetter || $0.isNumber }.count
        }
        XCTAssertEqual(
            suggestion.acceptance,
            hasLetterDeletingSpellingRepair ? .reviewOnly : .direct
        )
        if ["repair-exact-021", "repair-exact-022", "repair-exact-023"].contains(testCase.id) {
            XCTAssertEqual(suggestion.sentenceRange, NSRange(
                location: 0,
                length: (testCase.input as NSString).length
            ))
            XCTAssertEqual(suggestion.originalSentence, testCase.input)
            XCTAssertEqual(suggestion.correctedSentence, testCase.referenceText)
        }
        let reference = try XCTUnwrap(corpusReferenceSlice(
            for: suggestion.originalSentence,
            in: testCase
        ))
        XCTAssertEqual(suggestion.correctedSentence, reference)
        XCTAssertFalse(suggestion.displayChanges.isEmpty)
        let terminalEvent = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .visibleDeterministicRepair
        )
        XCTAssertLessThanOrEqual(
            terminalEvent?.elapsedMilliseconds ?? .max,
            2_000,
            "Repair exceeded the deterministic corpus latency budget for \(testCase.id)"
        )
        let expectedDocument = NSMutableString(string: triggeredDocument)
        expectedDocument.replaceCharacters(
            in: suggestion.sentenceRange,
            with: suggestion.correctedSentence
        )
        let acceptedDocument = expectedDocument as String
        let layoutMode = suggestion.acceptance
        if layoutMode == .reviewOnly {
            textView.undoManager?.removeAllActions()
            await renderFlowSuggestion(in: textView, window: window)
            XCTAssertTrue(textView.canApplyRenderedFlowSuggestion(suggestion))
            XCTAssertTrue(textView.isFlowReviewPreviewShown)
            XCTAssertEqual(textView.string, triggeredDocument)
            XCTAssertEqual(box.value, triggeredDocument)
            await replaceFrozenReviewSuggestion(
                suggestion,
                expectedDocument: acceptedDocument,
                originalDocument: triggeredDocument,
                acceptanceCount: acceptanceCount,
                box: box,
                textView: textView,
                window: window,
                testCaseID: testCase.id
            )
            return
        }
        let settled = await waitUntil { textView.string == acceptedDocument }
        XCTAssertTrue(settled, "Automatic settlement timed out for \(testCase.id)")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, acceptedDocument, "Acceptance mismatch for \(testCase.id)")
        XCTAssertEqual(box.value, acceptedDocument, "Binding mismatch for \(testCase.id)")
        XCTAssertEqual(acceptanceCount.value, 1, "Acceptance count mismatch for \(testCase.id)")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, triggeredDocument, "Undo mismatch for \(testCase.id)")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, acceptedDocument, "Redo mismatch for \(testCase.id)")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (acceptedDocument as NSString).length, length: 0),
            "Redo caret mismatch for \(testCase.id)"
        )
    }

    private func runFrozenAICorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws -> FrozenAICorpusOutcome {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let validation = FlowValidatedRepairBox()
        let candidate = testCase.conservativeCandidateFixture ?? testCase.referenceText
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in candidate }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == candidate {
                    completion([], self.englishOrthography())
                    return
                }
                let issueRanges = self.corpusDifferenceRanges(
                    in: checkedText,
                    candidate: candidate
                )
                let detectedIssues = self.corpusDetectedIssues(
                    in: checkedText,
                    candidate: candidate,
                    issueRanges: issueRanges,
                    testCase: testCase
                )
                validation.capture(EditorFlowSentenceRepairValidator.validatedRepair(
                    originalSentence: checkedText,
                    candidateSentence: candidate,
                    detectedIssues: detectedIssues
                ))
                completion(
                    self.corpusCheckingResults(
                        in: checkedText,
                        detectedIssues: detectedIssues
                    ),
                    self.englishOrthography()
                )
            },
            sentenceRepair: sentenceRepair
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let frozenTextView = FrozenCorpusTextView()
        frozenTextView.rejectsSyntheticCantCorrection = testCase.input.contains("cant") && {
            if case .characterTyping = inputPath { return true }
            return false
        }()
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: "",
            textView: frozenTextView
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )
        let acceptanceCount = EditorIntBox()
        var acceptedSuggestion: EditorFlowSuggestion?
        textView.flowSuggestionAcceptanceHandler = { suggestion in
            acceptedSuggestion = suggestion
            acceptanceCount.value += 1
            return coordinator.acceptFlowSuggestion(suggestion)
        }
        textView.undoManager?.removeAllActions()

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let classified = await waitUntil(timeout: 3) { validation.wasCaptured }
        XCTAssertTrue(classified, "AI fixture was not classified: \(testCase.id)")
        if frozenTextView.rejectsSyntheticCantCorrection {
            // AppKit may or may not attempt this correction depending on the
            // checker process's learned state. If it does, the test view
            // records and rejects only that exact replacement; strict input
            // equality below remains the invariant in either state.
            XCTAssertLessThanOrEqual(
                frozenTextView.rejectedSyntheticCantCorrectionCount,
                1,
                "The CLI-only native correction repeated for \(testCase.id)"
            )
        }

        guard let expectedRepair = validation.value else {
            let classification = testCase.aiClassification?.rawValue ?? "AI"
            XCTFail(
                "Labeled \(classification) fixture "
                    + "failed validation: \(testCase.id)"
            )
            let rejected = await waitUntil(timeout: 3) {
                diagnostics.events.contains {
                    $0.owner == .sentenceRepair && $0.reason == .validationRejected
                }
            }
            XCTAssertTrue(
                rejected,
                "Unsafe AI fixture was not rejected for \(testCase.id) via \(inputPath)"
            )
            let terminal = await assertSingleDiagnosticAttempt(
                diagnostics,
                owner: .sentenceRepair,
                reason: .validationRejected
            )
            XCTAssertTrue(terminal?.nativeFallbackRestored == true)
            XCTAssertNil(textView.flowSuggestion)
            XCTAssertEqual(textView.string, triggeredDocument)
            XCTAssertEqual(box.value, triggeredDocument)
            return .rejected
        }

        let declaredAcceptance: EditorFlowSuggestionAcceptance = testCase.aiClassification == .direct
            ? .direct
            : .reviewOnly
        XCTAssertEqual(
            expectedRepair.acceptance,
            declaredAcceptance,
            "Validator classification drift for \(testCase.id)"
        )

        let suggestionReady = await waitUntil(timeout: 3) {
            acceptedSuggestion?.source == .ai || textView.flowSuggestion?.source == .ai
        }
        XCTAssertTrue(
            suggestionReady,
            "No validated AI proposal for \(testCase.id) via \(inputPath); diagnostics="
                + diagnostics.events.map {
                    "\($0.owner.rawValue)#\($0.token):\($0.reason.rawValue)"
                }.joined(separator: ",")
        )
        let suggestion = try XCTUnwrap(acceptedSuggestion ?? textView.flowSuggestion)
        XCTAssertEqual(suggestion.source, .ai)
        XCTAssertEqual(suggestion.acceptance, expectedRepair.acceptance)
        XCTAssertEqual(suggestion.correctedSentence, candidate)
        let expectedReason: EditorFlowTerminalReason = expectedRepair.acceptance == .direct
            ? .visibleAIDirectRepair
            : .visibleAIReviewOnlyRepair
        let terminalEvent = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: expectedReason
        )
        XCTAssertLessThanOrEqual(
            terminalEvent?.elapsedMilliseconds ?? .max,
            4_000,
            "AI repair exceeded the corpus latency budget for \(testCase.id)"
        )

        let requiresReview = expectedRepair.acceptance == .reviewOnly
            || suggestion.acceptance == .reviewOnly
        let expectedDocument = NSMutableString(string: triggeredDocument)
        guard suggestion.sentenceRange.location >= 0,
              NSMaxRange(suggestion.sentenceRange) <= expectedDocument.length
        else {
            XCTFail(
                "Suggestion range \(suggestion.sentenceRange) escaped the frozen document "
                    + "for \(testCase.id)"
            )
            return .rejected
        }
        XCTAssertEqual(
            (triggeredDocument as NSString).substring(with: suggestion.sentenceRange),
            suggestion.originalSentence,
            "The proposal no longer owns the exact frozen sentence for \(testCase.id)"
        )
        expectedDocument.replaceCharacters(
            in: suggestion.sentenceRange,
            with: candidate
        )
        let acceptedDocument = expectedDocument as String
        if requiresReview {
            textView.undoManager?.removeAllActions()
            await renderFlowSuggestion(in: textView, window: window)
            XCTAssertTrue(textView.isFlowReviewPreviewShown)
            XCTAssertEqual(textView.string, triggeredDocument)
            XCTAssertEqual(box.value, triggeredDocument)
            await replaceFrozenReviewSuggestion(
                suggestion,
                expectedDocument: acceptedDocument,
                originalDocument: triggeredDocument,
                acceptanceCount: acceptanceCount,
                box: box,
                textView: textView,
                window: window,
                testCaseID: testCase.id
            )
        } else {
            let settled = await waitUntil { textView.string == acceptedDocument }
            XCTAssertTrue(settled, "Automatic AI settlement timed out for \(testCase.id)")
            XCTAssertNil(textView.flowSuggestion)
            XCTAssertEqual(textView.string, acceptedDocument)
            XCTAssertEqual(box.value, acceptedDocument)
            XCTAssertEqual(acceptanceCount.value, 1)
            textView.undoManager?.undo()
            XCTAssertEqual(textView.string, triggeredDocument)
            textView.undoManager?.redo()
            XCTAssertEqual(textView.string, acceptedDocument)
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(location: (acceptedDocument as NSString).length, length: 0)
            )
        }
        return expectedRepair.acceptance == .direct ? .direct : .review
    }

    private func replaceFrozenReviewSuggestion(
        _ suggestion: EditorFlowSuggestion,
        expectedDocument: String,
        originalDocument: String,
        acceptanceCount: EditorIntBox,
        box: EditorTextBox,
        textView: MarkdownNSTextView,
        window: NSWindow,
        testCaseID: String
    ) async {
        let reviewShown = await waitUntil { textView.isFlowReviewPreviewShown }
        XCTAssertTrue(reviewShown, "Inline review did not appear for \(testCaseID)")
        XCTAssertTrue(textView.hasRenderedFlowSuggestion(suggestion))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(acceptanceCount.value, 0)
        XCTAssertEqual(textView.string, originalDocument)
        XCTAssertEqual(box.value, originalDocument)
        textView.keyDown(with: try! XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let applied = await waitUntil {
            acceptanceCount.value == 1 && textView.string == expectedDocument
        }
        XCTAssertTrue(applied, "Inline review did not apply \(testCaseID)")
        XCTAssertEqual(box.value, expectedDocument)

        XCTAssertFalse(
            textView.confirmFlowReviewSuggestionForTesting(),
            "Dismissed inline review accepted twice for \(testCaseID)"
        )
        await nextMainRunLoopTurn()
        XCTAssertEqual(acceptanceCount.value, 1, "Review applied twice for \(testCaseID)")
        XCTAssertEqual(textView.string, expectedDocument)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, originalDocument, "Review undo failed for \(testCaseID)")
        XCTAssertEqual(box.value, originalDocument)
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, expectedDocument, "Review redo failed for \(testCaseID)")
        XCTAssertEqual(box.value, expectedDocument)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (expectedDocument as NSString).length, length: 0),
            "Review redo caret mismatch for \(testCaseID)"
        )
    }

    private func runFrozenCleanCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], self.englishOrthography())
            }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let plan = try XCTUnwrap(EditorFlowCheckPlanner.plan(
            in: triggeredDocument,
            selectedRange: textView.selectedRange()
        ))
        let expectedReason: EditorFlowTerminalReason = plan.coversWholeCurrentSentence
            ? .clean
            : .unresolvedAppleResult
        let terminated = await waitUntil(timeout: 3) {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair && $0.reason == expectedReason
            }
        }
        XCTAssertTrue(
            terminated,
            "Clean corpus attempt did not terminate for \(testCase.id) via \(inputPath)"
        )
        _ = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: expectedReason
        )
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, triggeredDocument)
        XCTAssertEqual(box.value, triggeredDocument)
    }

    private func runFrozenProtectedCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath
    ) async throws {
        let box = EditorTextBox("")
        let diagnostics = FlowDiagnosticEventBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                let results = self.corpusProtectedResults(in: checkedText)
                completion(results, self.englishOrthography())
            }
        )
        coordinator.flowDiagnosticsHandler = { diagnostics.append($0) }
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: ""
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let options = EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true,
            inlinePredictions: false
        )
        let sourceMode = frozenSourceMode(for: testCase)
        textView.flowSourceMode = sourceMode
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: sourceMode, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(
            rangesReady,
            "Protected ranges did not settle for \(testCase.id)"
        )

        let triggeredDocument = try await enterFrozenCorpusCase(
            testCase,
            inputPath: inputPath,
            textView: textView,
            window: window,
            diagnostics: diagnostics
        )
        let terminated = await waitUntil(timeout: 3) {
            diagnostics.events.contains {
                $0.owner == .sentenceRepair
                    && ($0.reason == .protected || $0.reason == .clean)
            }
        }
        XCTAssertTrue(
            terminated,
            "Protected corpus attempt did not terminate for \(testCase.id) via \(inputPath)"
        )
        let reason = diagnostics.events.first(where: {
            $0.owner == .sentenceRepair && ($0.reason == .protected || $0.reason == .clean)
        })?.reason ?? .clean
        _ = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: reason
        )
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, triggeredDocument)
        XCTAssertEqual(box.value, triggeredDocument)
        for fragment in testCase.protectedFragments {
            XCTAssertTrue(
                textView.string.contains(fragment),
                "Protected fragment changed in \(testCase.id): \(fragment)"
            )
        }
    }

    private func enterFrozenCorpusCase(
        _ testCase: FlowWritingRepairCase,
        inputPath: FrozenCorpusInputPath,
        textView: MarkdownNSTextView,
        window: NSWindow,
        diagnostics: FlowDiagnosticEventBox
    ) async throws -> String {
        switch testCase.trigger {
        case let .punctuation(punctuation, trailingDelimiterCount):
            let characters = Array(testCase.input)
            let punctuationIndex = characters.count - trailingDelimiterCount - 1
            guard punctuationIndex >= 0,
                  characters[punctuationIndex] == punctuation
            else {
                XCTFail("Invalid punctuation trigger in frozen case \(testCase.id)")
                return textView.string
            }
            let prefix = String(characters[..<punctuationIndex])
            let trailingDelimiters = String(characters[(punctuationIndex + 1)...])
            await insertFrozenCorpusText(
                prefix,
                inputPath: inputPath,
                testCaseID: testCase.id,
                textView: textView,
                window: window
            )
            XCTAssertEqual(textView.string, prefix, "Prefix mismatch for \(testCase.id)")
            await nextMainRunLoopTurn()
            diagnostics.removeAll()
            textView.keyDown(with: try XCTUnwrap(corpusKeyEvent(
                for: punctuation,
                windowNumber: window.windowNumber
            )))
            for delimiter in trailingDelimiters {
                textView.keyDown(with: try XCTUnwrap(corpusKeyEvent(
                    for: delimiter,
                    windowNumber: window.windowNumber
                )))
            }
            let triggeredDocument = textView.string
            if triggeredDocument != testCase.input {
                print(
                    "FLOW_CORPUS_INPUT_MISMATCH case=\(testCase.id) "
                        + "expected=\(testCase.input.debugDescription) "
                        + "actual=\(triggeredDocument.debugDescription)"
                )
            }
            XCTAssertEqual(
                triggeredDocument,
                testCase.input,
                "Triggered document must exactly match the frozen input for \(testCase.id) via \(inputPath)"
            )
            return triggeredDocument

        case .returnKey:
            await insertFrozenCorpusText(
                testCase.input,
                inputPath: inputPath,
                testCaseID: testCase.id,
                textView: textView,
                window: window
            )
            XCTAssertEqual(textView.string, testCase.input, "Input mismatch for \(testCase.id)")
            await nextMainRunLoopTurn()
            diagnostics.removeAll()
            textView.keyDown(with: try XCTUnwrap(keyEvent(
                characters: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: window.windowNumber
            )))
            let triggeredDocument = textView.string
            XCTAssertEqual(
                triggeredDocument,
                testCase.input + "\n",
                "Return-triggered document must exactly match the frozen input for \(testCase.id) via \(inputPath)"
            )
            return triggeredDocument
        }
    }

    private func insertFrozenCorpusText(
        _ text: String,
        inputPath: FrozenCorpusInputPath,
        testCaseID: String,
        textView: MarkdownNSTextView,
        window: NSWindow
    ) async {
        switch inputPath {
        case .characterTyping:
            for character in text {
                let event = corpusKeyEvent(
                    for: character,
                    windowNumber: window.windowNumber
                )
                if let event {
                    textView.keyDown(with: event)
                } else {
                    print(
                        "FLOW_CORPUS_KEY_FALLBACK case=\(testCaseID) "
                            + "scalar=\(String(character).unicodeScalars.map(\.value))"
                    )
                    textView.insertText(
                        String(character),
                        replacementRange: textView.selectedRange()
                    )
                }
                // Hardware events arrive on distinct turns. Let AppKit finish
                // each real key event so queued text-system work cannot mutate
                // an earlier word after the frozen trigger snapshot is taken.
                await nextMainRunLoopTurn()
            }
        case .pasteboard:
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("monknot-flow-corpus-\(UUID().uuidString)")
            )
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString(text, forType: .string))
            XCTAssertTrue(window.makeFirstResponder(textView))
            XCTAssertTrue(window.firstResponder === textView)
            XCTAssertTrue(
                textView.readSelection(from: pasteboard, type: .string),
                "Pasteboard insertion failed for \(testCaseID)"
            )
            pasteboard.releaseGlobally()
        }
    }

    private func corpusKeyEvent(
        for character: Character,
        windowNumber: Int
    ) -> NSEvent? {
        let text = String(character)
        let lowercased = text.lowercased()
        let keyCodes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            " ": 49, "`": 50,
        ]
        let shiftedKeyCodes: [String: UInt16] = [
            "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23,
            "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
            "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43,
            "?": 44, ">": 47,
        ]
        let shiftedBaseCharacters: [String: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "^": "6", "%": "5",
            "+": "=", "(": "9", "&": "7", "_": "-", "*": "8", ")": "0",
            "}": "]", "{": "[", "\"": "'", ":": ";", "|": "\\", "<": ",",
            "?": "/", ">": ".",
        ]
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let charactersIgnoringModifiers: String
        if text == "”" {
            modifiers = [.option, .shift]
            keyCode = 33
            charactersIgnoringModifiers = "["
        } else if text == "’" {
            modifiers = [.option, .shift]
            keyCode = 30
            charactersIgnoringModifiers = "]"
        } else if let shifted = shiftedKeyCodes[text] {
            modifiers = .shift
            keyCode = shifted
            charactersIgnoringModifiers = shiftedBaseCharacters[text] ?? lowercased
        } else if text != lowercased, let letter = keyCodes[lowercased] {
            modifiers = .shift
            keyCode = letter
            charactersIgnoringModifiers = lowercased
        } else {
            modifiers = []
            keyCode = keyCodes[text] ?? 0
            charactersIgnoringModifiers = text
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func corpusReferenceSlice(
        for checkedText: String,
        in testCase: FlowWritingRepairCase
    ) -> String? {
        if checkedText == testCase.input { return testCase.referenceText }
        let checked = checkedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputSentences = sentenceSlices(in: testCase.input)
        let referenceSentences = sentenceSlices(in: testCase.referenceText)
        guard inputSentences.count == referenceSentences.count,
              let sentenceIndex = inputSentences.firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == checked
              })
        else { return nil }
        return referenceSentences[sentenceIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sentenceSlices(in text: String) -> [String] {
        var slices: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences]
        ) { substring, _, _, _ in
            if let substring { slices.append(substring) }
        }
        return slices
    }

    private func corpusDifferenceRanges(
        in text: String,
        candidate: String
    ) -> [NSRange] {
        let originalCharacters = Array(text)
        let candidateCharacters = Array(candidate)
        let difference = candidateCharacters.difference(from: originalCharacters)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }
        guard !removedOffsets.isEmpty || !insertedOffsets.isEmpty else { return [] }

        let originalMatches = originalCharacters.indices.filter { !removedOffsets.contains($0) }
        let candidateMatches = candidateCharacters.indices.filter { !insertedOffsets.contains($0) }
        guard originalMatches.count == candidateMatches.count else { return [] }

        func utf16Offsets(_ characters: [Character]) -> [Int] {
            var offsets = [0]
            for character in characters {
                offsets.append(offsets.last! + String(character).utf16.count)
            }
            return offsets
        }
        let originalOffsets = utf16Offsets(originalCharacters)
        let matches = Array(zip(originalMatches, candidateMatches))
            + [(originalCharacters.count, candidateCharacters.count)]
        var previousOriginal = -1
        var previousCandidate = -1
        var rawRanges: [NSRange] = []
        for (currentOriginal, currentCandidate) in matches {
            let originalStart = previousOriginal + 1
            let candidateStart = previousCandidate + 1
            if originalStart < currentOriginal || candidateStart < currentCandidate {
                rawRanges.append(NSRange(
                    location: originalOffsets[originalStart],
                    length: originalOffsets[currentOriginal] - originalOffsets[originalStart]
                ))
            }
            previousOriginal = currentOriginal
            previousCandidate = currentCandidate
        }

        let sourceLength = (text as NSString).length
        let words = wordRanges(in: text)
        let expanded = rawRanges.compactMap { raw -> NSRange? in
            let touchedWords = words.filter { word in
                if raw.length == 0 {
                    return raw.location >= word.location && raw.location <= NSMaxRange(word)
                }
                return NSIntersectionRange(raw, word).length > 0
            }
            if let first = touchedWords.first, let last = touchedWords.last {
                return NSRange(
                    location: first.location,
                    length: NSMaxRange(last) - first.location
                )
            }
            guard sourceLength > 0 else { return nil }
            return NSRange(location: min(raw.location, sourceLength - 1), length: 1)
        }.sorted { $0.location < $1.location }

        return expanded.reduce(into: []) { ranges, range in
            if let last = ranges.last,
               NSIntersectionRange(last, range).length > 0 || last == range {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
    }

    private func corpusDetectedIssues(
        in text: String,
        candidate: String,
        issueRanges: [NSRange],
        testCase: FlowWritingRepairCase
    ) -> [EditorFlowDetectedIssue] {
        let permitsSpelling = testCase.mutations.contains(.spelling)
            || testCase.mutations.contains(.adjacentTransposition)
        let source = text as NSString
        let sourceWords = wordRanges(in: text)
        let candidateSource = candidate as NSString
        let candidateWords = wordRanges(in: candidate).map {
            candidateSource.substring(with: $0)
        }
        let duplicateRun = testCase.mutations.contains(.duplicatedWord)
            ? adjacentDuplicateWordRange(in: text)
            : nil
        var normalizedIssueRanges = issueRanges
        if let duplicateRun {
            normalizedIssueRanges = issueRanges.flatMap { range -> [NSRange] in
                guard NSIntersectionRange(range, duplicateRun).length > 0 else {
                    return [range]
                }
                return sourceWords.filter { word in
                    NSIntersectionRange(word, range).length > 0
                        && NSIntersectionRange(word, duplicateRun).length == 0
                }
            }
            // A real duplicate-word grammar detail spans both adjacent tokens.
            // Keep any separate issue-backed inflection in the same diff gap.
            normalizedIssueRanges.append(duplicateRun)
        }
        if testCase.mutations.contains(.runOnClause),
           let runOnRange = preciseRunOnGrammarRange(
               in: text,
               candidate: candidate,
               issueRanges: normalizedIssueRanges
           ) {
            normalizedIssueRanges.append(runOnRange)
        }
        return normalizedIssueRanges.map { range in
            let touchedWords = sourceWords.filter {
                NSIntersectionRange($0, range).length > 0
            }
            let isSpelling = permitsSpelling
                && touchedWords.count == 1
                && candidateWords.contains { candidateWord in
                    corpusLooksLikeSpellingRepair(
                        source.substring(with: touchedWords[0]),
                        candidateWord
                    )
                }
            return EditorFlowDetectedIssue(
                range: range,
                kind: isSpelling ? .spelling : .grammar,
                hasPreciseRange: true
            )
        }
    }

    private func preciseRunOnGrammarRange(
        in text: String,
        candidate: String,
        issueRanges: [NSRange]
    ) -> NSRange? {
        let subjects: Set<String> = ["he", "i", "it", "she", "they", "we", "you"]
        let source = text as NSString
        let sourceWords = wordRanges(in: text)
        let candidateSource = candidate as NSString
        let sourceSubjects = sourceWords.map { source.substring(with: $0).lowercased() }
            .filter(subjects.contains)
        let candidateSubjects = wordRanges(in: candidate)
            .map { candidateSource.substring(with: $0).lowercased() }
            .filter(subjects.contains)
        guard candidateSubjects.count == sourceSubjects.count + 1 else { return nil }

        let connectors: Set<String> = ["and", "because", "but", "so", "while", "yet"]
        let connectorIndices = sourceWords.indices.filter {
            connectors.contains(source.substring(with: sourceWords[$0]).lowercased())
        }
        guard let connectorIndex = connectorIndices.last(where: { index in
            guard index + 2 < sourceWords.count else { return false }
            let localTail = NSRange(
                location: sourceWords[index].location,
                length: NSMaxRange(sourceWords[index + 2]) - sourceWords[index].location
            )
            return issueRanges.contains { NSIntersectionRange($0, localTail).length > 0 }
        }) else { return nil }

        // Model the precise grammar detail a checker reports for a run-on
        // boundary: a short local clause window, never the full sentence.
        let firstIndex = max(sourceWords.startIndex, connectorIndex - 3)
        let lastIndex = min(sourceWords.index(before: sourceWords.endIndex), connectorIndex + 2)
        return NSRange(
            location: sourceWords[firstIndex].location,
            length: NSMaxRange(sourceWords[lastIndex]) - sourceWords[firstIndex].location
        )
    }

    private func adjacentDuplicateWordRange(in text: String) -> NSRange? {
        let source = text as NSString
        let words = wordRanges(in: text)
        guard words.count > 1 else { return nil }
        for index in 0..<(words.count - 1) {
            let first = words[index]
            let second = words[index + 1]
            guard source.substring(with: first).caseInsensitiveCompare(
                source.substring(with: second)
            ) == .orderedSame else { continue }
            let gap = NSRange(
                location: NSMaxRange(first),
                length: second.location - NSMaxRange(first)
            )
            guard source.substring(with: gap)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else { continue }
            return NSRange(
                location: first.location,
                length: NSMaxRange(second) - first.location
            )
        }
        return nil
    }

    private func corpusCheckingResults(
        in text: String,
        detectedIssues: [EditorFlowDetectedIssue]
    ) -> [NSTextCheckingResult] {
        guard !detectedIssues.isEmpty else { return [] }
        var results = detectedIssues.compactMap { issue -> NSTextCheckingResult? in
            guard issue.kind == .spelling else { return nil }
            return NSTextCheckingResult.correctionCheckingResult(
                range: issue.range,
                replacementString: ""
            )
        }
        let grammarRanges = detectedIssues.filter { $0.kind == .grammar }.map(\.range)
        guard !grammarRanges.isEmpty else { return results }
        let sourceLength = (text as NSString).length
        results.append(NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: sourceLength),
            details: grammarRanges.map { range in
                [
                    NSGrammarRange: NSValue(range: range),
                    NSGrammarCorrections: [String](),
                ]
            }
        ))
        return results
    }

    private func corpusLooksLikeSpellingRepair(
        _ original: String,
        _ replacement: String
    ) -> Bool {
        let left = Array(original.lowercased().filter { $0.isLetter || $0.isNumber })
        let right = Array(replacement.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !left.isEmpty, !right.isEmpty else { return false }
        let maximumLength = max(left.count, right.count)
        let allowedDistance = maximumLength >= 7
            ? 4
            : min(3, max(1, Int(ceil(Double(maximumLength) * 0.45))))
        var remaining = right
        var sharedCount = 0
        for character in left {
            if let index = remaining.firstIndex(of: character) {
                sharedCount += 1
                remaining.remove(at: index)
            }
        }
        return abs(left.count - right.count) <= allowedDistance
            && sharedCount * 5 >= maximumLength * 3
            && corpusEditDistance(left, right) <= allowedDistance
    }

    private func corpusEditDistance(
        _ left: [Character],
        _ right: [Character]
    ) -> Int {
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private func corpusProtectedResults(in text: String) -> [NSTextCheckingResult] {
        let source = text as NSString
        for (typo, correction) in [("teh", "the"), ("retrun", "return")] {
            let range = source.range(of: typo)
            if range.location != NSNotFound {
                return [NSTextCheckingResult.correctionCheckingResult(
                    range: range,
                    replacementString: correction
                )]
            }
        }
        return []
    }

    private func corpusCorrectionResults(
        in text: String,
        reference: String
    ) -> [NSTextCheckingResult] {
        guard text != reference else { return [] }
        let source = text as NSString
        let candidate = reference as NSString
        let sourceWords = wordRanges(in: text)
        let candidateWords = wordRanges(in: reference)
        guard !sourceWords.isEmpty, sourceWords.count == candidateWords.count else { return [] }

        return sourceWords.indices.compactMap { index in
            let sourceRange = NSRange(
                location: sourceWords[index].location,
                length: (index + 1 < sourceWords.count
                    ? sourceWords[index + 1].location
                    : source.length) - sourceWords[index].location
            )
            let candidateRange = NSRange(
                location: candidateWords[index].location,
                length: (index + 1 < candidateWords.count
                    ? candidateWords[index + 1].location
                    : candidate.length) - candidateWords[index].location
            )
            let originalSegment = source.substring(with: sourceRange)
            let correctedSegment = candidate.substring(with: candidateRange)
            guard originalSegment != correctedSegment else { return nil }
            return NSTextCheckingResult.correctionCheckingResult(
                range: sourceRange,
                replacementString: correctedSegment
            )
        }
    }

    private func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        return ranges
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
            flowProseOfferDelayNanoseconds: 0,
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

    private func assertSingleDiagnosticAttempt(
        _ diagnostics: FlowDiagnosticEventBox,
        owner: EditorFlowDiagnosticOwner,
        reason: EditorFlowTerminalReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> EditorFlowDiagnosticEvent? {
        guard let matched = diagnostics.events.first(where: {
            $0.owner == owner && $0.reason == reason
        }) else {
            XCTFail(
                "Missing \(owner.rawValue) diagnostic reason \(reason.rawValue)",
                file: file,
                line: line
            )
            return nil
        }

        let matchedOwner = matched.owner
        let matchedToken = matched.token
        await nextMainRunLoopTurn()
        try? await Task.sleep(nanoseconds: 30_000_000)
        await nextMainRunLoopTurn()

        let attemptEvents = diagnostics.events.filter {
            $0.owner == matchedOwner && $0.token == matchedToken
        }
        XCTAssertEqual(
            attemptEvents.count,
            1,
            "Diagnostic attempt \(matchedOwner.rawValue)#\(matchedToken) terminated more than once",
            file: file,
            line: line
        )
        XCTAssertEqual(
            attemptEvents.map(\.reason),
            [reason],
            "Diagnostic attempt \(matchedOwner.rawValue)#\(matchedToken) had the wrong sole reason",
            file: file,
            line: line
        )
        return matched
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
        replacement: String,
        acceptance: EditorFlowSuggestionAcceptance = .direct
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
            acceptance: acceptance,
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
        type: NSEvent.EventType = .keyDown,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isRepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
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

private enum FrozenCorpusInputPath: CustomStringConvertible {
    case characterTyping
    case pasteboard

    var description: String {
        switch self {
        case .characterTyping:
            return "character typing"
        case .pasteboard:
            return "pasteboard"
        }
    }
}

private enum FrozenAICorpusOutcome: Equatable {
    case direct
    case review
    case rejected
}

private final class EditorBoolBox {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private enum FrozenCorpusShard: CustomStringConvertible {
    case nonAI
    case ai(ClosedRange<Int>)

    var includesNonAI: Bool {
        if case .nonAI = self { return true }
        return false
    }

    func includesAI(id: String) -> Bool {
        guard case let .ai(range) = self,
              let suffix = id.split(separator: "-").last,
              let number = Int(suffix)
        else { return false }
        return range.contains(number)
    }

    var description: String {
        switch self {
        case .nonAI:
            return "nonAI"
        case let .ai(range):
            return String(format: "ai%03d-%03d", range.lowerBound, range.upperBound)
        }
    }
}

private final class EditorIntBox {
    var value = 0
}

private final class FlowDiagnosticEventBox {
    private(set) var events: [EditorFlowDiagnosticEvent] = []

    func append(_ event: EditorFlowDiagnosticEvent) {
        events.append(event)
    }

    func removeAll() {
        events.removeAll()
    }
}

private final class FlowValidatedRepairBox {
    private(set) var wasCaptured = false
    private(set) var value: EditorFlowValidatedRepair?

    func capture(_ value: EditorFlowValidatedRepair?) {
        wasCaptured = true
        self.value = value
    }
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

private final class FrozenCorpusTextView: MarkdownNSTextView {
    var rejectsSyntheticCantCorrection = false
    private(set) var rejectedSyntheticCantCorrectionCount = 0

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let source = string as NSString
        if rejectsSyntheticCantCorrection,
           affectedCharRange.location >= 0,
           NSMaxRange(affectedCharRange) <= source.length,
           source.substring(with: affectedCharRange).lowercased() == "cant",
           replacementString?.lowercased() == "can't" {
            rejectedSyntheticCantCorrectionCount += 1
            return false
        }
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
