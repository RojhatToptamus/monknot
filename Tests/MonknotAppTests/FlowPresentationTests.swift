import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class FlowPresentationTests: FlowEditorTestCase {
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

        await renderFlowSuggestion(in: textView, window: window)
        let fullAcceptanceReady = try await holdTabUntilAccepted(
            in: textView,
            window: window,
            expectedText: "We can write " + boundedContinuation
        )
        XCTAssertTrue(fullAcceptanceReady)
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

        let applyHandler = try XCTUnwrap(apply.handler)
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            XCTAssertFalse(applyHandler())
            XCTAssertEqual(textView.string, source)
            XCTAssertEqual(box.value, source)
            throw XCTSkip("Accessibility activation requires an app-hosted XCTest process")
        }

        NSApp.activate(ignoringOtherApps: true)
        let appActivated = await waitUntil(timeout: 1) { NSApp.isActive }
        guard appActivated else {
            XCTAssertFalse(applyHandler())
            XCTAssertEqual(textView.string, source)
            XCTAssertEqual(box.value, source)
            throw XCTSkip("The app-hosted XCTest process did not become active")
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

    func testDeletionOnlySettlementHighlightsSurvivorAndDeleteRestoresCollapsedCaret() async throws {
        let source = "A courier courier arrived before the office closed."
        let corrected = "A courier arrived before the office closed."
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
        let firstCourier = sourceText.range(of: "courier")
        let removedDuplicate = sourceText.range(of: " courier", options: [], range: NSRange(
            location: NSMaxRange(firstCourier),
            length: sourceText.length - NSMaxRange(firstCourier)
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
        let survivingCourier = correctedText.range(of: "courier")
        XCTAssertEqual(textView.string, corrected)
        XCTAssertEqual(box.value, corrected)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: correctedText.length, length: 0))
        XCTAssertEqual(textView.flowSettlementRangesForTesting, [survivingCourier])
        XCTAssertEqual(
            textView.flowSettlementDeletionCollapseRangesForTesting,
            [survivingCourier]
        )
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Removed courier") == true)
        XCTAssertTrue(textView.accessibilityHelp()?.contains("Delete to undo") == true)

        try? await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertEqual(textView.flowSettlementRangesForTesting, [survivingCourier])
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
}
