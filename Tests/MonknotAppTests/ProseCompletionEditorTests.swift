import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class ProseCompletionEditorTests: FlowEditorTestCase {
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

        await renderFlowSuggestion(in: textView, window: window)
        let fullAcceptanceReady = try await holdTabUntilAccepted(
            in: textView,
            window: window,
            expectedText: "We can write clearer prose."
        )
        XCTAssertTrue(fullAcceptanceReady)
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
        let fullAcceptanceReady = await waitUntil(timeout: 1.5) {
            acceptanceCount.value == 1
        }
        XCTAssertTrue(fullAcceptanceReady)
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
        XCTAssertEqual(textView.flowProseSuggestion?.continuation, "with confidence.")
        await renderFlowSuggestion(in: textView, window: window)
        XCTAssertTrue(textView.canDirectlyAcceptFlowProseSuggestion(try XCTUnwrap(
            textView.flowProseSuggestion
        )))

        let fullAcceptanceReady = try await holdTabUntilAccepted(
            in: textView,
            window: window,
            expectedText: "We can write clearly, with confidence."
        )
        XCTAssertTrue(fullAcceptanceReady)
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
            proseCompletion: prose.service,
            flowCheckDelayNanoseconds: nil
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
        let fullAcceptanceReady = try await holdTabUntilAccepted(
            in: textView,
            window: window,
            expectedText: "We can write clearly, with confidence."
        )
        XCTAssertTrue(fullAcceptanceReady)
        XCTAssertEqual(textView.string, "We can write clearly, with confidence.")
        XCTAssertEqual(box.value, "We can write clearly, with confidence.")
        XCTAssertNil(textView.flowProseSuggestion)
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
}
