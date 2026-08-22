import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class SentenceRepairCoordinatorTests: FlowEditorTestCase {
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

    func testNonEnglishOrthographyUsesLocaleAwareSentenceModelReview() async {
        let source = "Je suis ecritng clairement"
        let corrected = "Je suis écrit clairement."
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let modelCalls = EditorIntBox()
        let service = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                modelCalls.value += 1
                return corrected
            }
        )
        let french = NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["fr"]]
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == corrected {
                    completion([], french)
                    return
                }
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
        let reviewReady = await waitUntil {
            textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(reviewReady)
        let event = await assertSingleDiagnosticAttempt(
            diagnostics,
            owner: .sentenceRepair,
            reason: .visibleAIReviewOnlyRepair
        )
        XCTAssertEqual(modelCalls.value, 1)
        XCTAssertFalse(event?.nativeFallbackRestored == true)
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, corrected)
        XCTAssertEqual(textView.string, source + ".")
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

    func testAISentenceRepairFallbackReviewsThenSettlesAtomically() async throws {
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.string, source + ".")
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let settled = await waitUntil { textView.string == corrected }
        XCTAssertTrue(settled)
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

    func testAppleCleanCompletedSentenceUsesEnabledOnDeviceRepair() async throws {
        let source = "Could u snd the route"
        let completedSource = source + "?"
        let candidate = "Could you send the route?"
        let box = EditorTextBox(source)
        let modelRequestCount = EditorIntBox()
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in
                modelRequestCount.value += 1
                return candidate
            }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], self.englishOrthography())
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText("?", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.acceptance == .reviewOnly
        }

        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(modelRequestCount.value, 1)
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertEqual(textView.flowSuggestion?.source, .ai)
        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, candidate)
    }

    func testUndefinedCheckerLanguageUsesCurrentLocaleForOnDeviceRepair() async throws {
        let source = "Could u snd the route"
        let candidate = "Could you send the route?"
        let box = EditorTextBox(source)
        let requestedLocale = EditorTextBox("")
        let undefinedOrthography = NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": ["und"]]
        )
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { locale in
                requestedLocale.value = locale.identifier
                return locale.identifier == Locale.current.identifier
            },
            client: { _, _ in candidate }
        )
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], undefinedOrthography)
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText("?", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == candidate
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(requestedLocale.value, Locale.current.identifier)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
    }

    func testAppleCleanRunOnTextReachesMultiSentenceModelReviewAfterReturn() async throws {
        let source = "hey did the parcel arive yesturday was the box damagd can we call the shop tomorow qzpt"
        let candidate = "Hey, did the parcel arrive yesterday? Was the box damaged? Can we call the shop tomorrow?"
        let box = EditorTextBox(source)
        let modelRequestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                completion([], self.englishOrthography())
            },
            sentenceRepair: FlowSentenceRepairService(
                isAvailable: { _ in true },
                client: { _, _ in
                    modelRequestCount.value += 1
                    return candidate
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
            checksGrammar: true,
            inlinePredictions: false,
            onDeviceProseCompletions: true
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        )))
        let reviewReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == candidate
                && textView.flowSuggestion?.acceptance == .reviewOnly
        }

        XCTAssertTrue(reviewReady)
        XCTAssertEqual(modelRequestCount.value, 1)
        XCTAssertEqual(textView.string, source + "\n")
        XCTAssertEqual(textView.flowSuggestion?.originalSentence, source)
        XCTAssertEqual(
            textView.flowSuggestion?.sentenceRange,
            NSRange(location: 0, length: (source as NSString).length)
        )
    }

    func testAppleCleanCompletedSentenceTreatsUnchangedModelOutputAsClean() async {
        let source = "The report is ready"
        let completedSource = source + "."
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let modelRequestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], self.englishOrthography())
            },
            sentenceRepair: FlowSentenceRepairService(
                isAvailable: { _ in true },
                client: { _, _ in
                    modelRequestCount.value += 1
                    return completedSource
                }
            )
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let finished = await waitUntil {
            diagnostics.events.contains { $0.reason == .clean }
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(modelRequestCount.value, 1)
        XCTAssertEqual(textView.string, completedSource)
        XCTAssertNil(textView.flowSuggestion)
    }

    func testAppleCleanCompletedSentenceDoesNotCallDisabledOnDeviceRepair() async {
        let source = "The report is ready"
        let box = EditorTextBox(source)
        let diagnostics = FlowDiagnosticEventBox()
        let modelRequestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { _, _, _, _, completion in
                completion([], self.englishOrthography())
            },
            sentenceRepair: FlowSentenceRepairService(
                isAvailable: { _ in true },
                client: { _, _ in
                    modelRequestCount.value += 1
                    return "unused"
                }
            )
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
            onDeviceProseCompletions: false
        )
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let finished = await waitUntil {
            diagnostics.events.contains { $0.reason == .clean }
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(modelRequestCount.value, 0)
        XCTAssertNil(textView.flowSuggestion)
    }

    func testGeneratedMultiErrorAIRepairPresentsInlineReviewAndTabApplies() async throws {
        let incomplete = "My ankle did nt improve overnight after the new exercises the swelling look worse and the clinic have not replyed yet"
        let original = incomplete + "."
        let candidate = "My ankle did not improve overnight after the new exercises; the swelling looks worse, and the clinic has not replied yet."
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
                                NSGrammarRange: NSValue(range: source.range(of: "did nt improve")),
                                NSGrammarCorrections: [],
                            ],
                            [
                                NSGrammarRange: NSValue(range: source.range(
                                    of: "swelling look worse and the clinic have"
                                )),
                                NSGrammarCorrections: [],
                            ],
                        ]
                    ),
                    NSTextCheckingResult.correctionCheckingResult(
                        range: source.range(of: "replyed"),
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

    func testAISentenceRepairContentChangeRequiresExplicitReview() async {
        let source = "I saw a dag outside"
        let candidate = "I saw a cat outside."
        let box = EditorTextBox(source)
        let sentenceRepair = FlowSentenceRepairService(
            isAvailable: { _ in true },
            client: { _, _ in candidate }
        )
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                if checkedText == candidate {
                    completion([], self.englishOrthography())
                    return
                }
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
        let suggestionReady = await waitUntil {
            requestCount.value == 2 && textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(suggestionReady)

        XCTAssertEqual(textView.flowSuggestion?.correctedSentence, candidate)
        XCTAssertEqual(textView.string, source + ".")
        XCTAssertEqual(box.value, source + ".")
        XCTAssertEqual(requestCount.value, 2)
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

    func testBroadGrammarReplacementDisplaysAndDescribesOnlyChangedWord() {
        let original = "The lanterns is ready."
        let corrected = "The lanterns are ready."
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
                range: (original as NSString).range(of: "lanterns is"),
                originalText: "lanterns is",
                replacementText: "lanterns are",
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
        XCTAssertFalse(suggestion.exactChangeDescription.contains("lanterns"))
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "the cats are ready."
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
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
        let source = "The lanterns are flickring"
        let box = EditorTextBox(source)
        let candidateRequestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient(
                { checkedText, _, _, _, completion in
                    completion([
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "flickring"),
                            replacementString: "flickering"
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
        let settled = await waitUntil { textView.string == "The lanterns are flickering." }
        XCTAssertTrue(settled)
        XCTAssertEqual(candidateRequestCount.value, 0)
        XCTAssertEqual(acceptedSuggestion?.correctedSentence, "The lanterns are flickering.")
        XCTAssertEqual(acceptedSuggestion?.acceptance, .direct)
        XCTAssertNil(textView.flowSuggestion)
    }

    func testFlowGrammarRedoRestoresSentenceEndAfterNativeCorrectionUndo() async throws {
        let userTyped = "The lanterns is flickring."
        let nativeCorrected = "The lanterns is flickering."
        let flowCorrected = "The lanterns are flickering."
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

        let typoRange = (userTyped as NSString).range(of: "flickring")
        textView.insertText("flickering", replacementRange: typoRange)
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
        let source = "The lanterns is flickring"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        var requestedTypes: [NSTextCheckingTypes] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, types, _, completion in
                requestedTexts.append(checkedText)
                requestedTypes.append(types)
                switch checkedText {
                case "The lanterns is flickring.":
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "is",
                            corrections: ["am", "are"]
                        ),
                        NSTextCheckingResult.correctionCheckingResult(
                            range: (checkedText as NSString).range(of: "flickring"),
                            replacementString: "flickering"
                        ),
                    ], self.englishOrthography())
                case "The lanterns am flickering.":
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "am",
                            corrections: ["is", "are"]
                        ),
                    ], self.englishOrthography())
                case "The lanterns are flickering.":
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "The lanterns are flickering."
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let settled = await waitUntil { textView.string == "The lanterns are flickering." }
        XCTAssertTrue(settled)
        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "The lanterns is flickring.",
            "The lanterns am flickering.",
            "The lanterns are flickering.",
        ])
        XCTAssertTrue(requestedTypes.dropFirst().allSatisfy {
            $0 & NSTextCheckingResult.CheckingType.spelling.rawValue != 0
                && $0 & NSTextCheckingResult.CheckingType.grammar.rawValue != 0
        })
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, "The lanterns are flickering.")
        XCTAssertEqual(box.value, "The lanterns are flickering.")
        XCTAssertEqual(recordingTextView.approvedChanges.count, 2)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "The lanterns is flickring.")
        XCTAssertEqual(box.value, "The lanterns is flickring.")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "The lanterns are flickering.")
        XCTAssertEqual(box.value, "The lanterns are flickering.")
    }

    func testAmbiguousGrammarValidationAbstainsWhenNoAlternativeIsClean() async {
        await assertAmbiguousGrammarValidationAbstains(cleanReplacements: [])
    }

    func testGrammarOnlyRequestsUnifiedSpellingBitButHidesSpellingCorrections() async {
        let source = "thse lanterns is ready"
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
                        range: (checkedText as NSString).range(of: "thse"),
                        replacementString: "these"
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "thse lanterns are ready."
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try! XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let settled = await waitUntil { textView.string == "thse lanterns are ready." }
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
        let source = "thse lanterns is ready"
        let box = EditorTextBox(source)
        var requestedTexts: [String] = []
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestedTexts.append(checkedText)
                let checkedSource = checkedText as NSString
                let spelling = NSTextCheckingResult.correctionCheckingResult(
                    range: checkedSource.range(of: "thse"),
                    replacementString: "these"
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == "thse lanterns are ready."
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try! XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let settled = await waitUntil { textView.string == "thse lanterns are ready." }
        XCTAssertTrue(settled)

        XCTAssertEqual(Array(requestedTexts.prefix(3)), [
            "thse lanterns is ready.",
            "thse lanterns are ready.",
            "thse lanterns were ready.",
        ])
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.originalText), ["is"])
        XCTAssertEqual(acceptedSuggestion?.edits.map(\.replacementText), ["are"])
        XCTAssertEqual(acceptedSuggestion?.correctedSentence, "thse lanterns are ready.")
        XCTAssertFalse(acceptedSuggestion?.exactChangeDescription.contains("thse") == true)
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

    func testLexicalGrammarCorrectionRequiresReviewBeforeChangingText() async {
        let source = "Where you put the keys I no can find them"
        let completed = source + "."
        let corrected = "Where you put the keys I know can find them."
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                if checkedText == completed {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "no",
                            corrections: ["know"]
                        ),
                    ], self.englishOrthography())
                } else {
                    completion([], self.englishOrthography())
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
        textView.flowSourceMode = .plainText
        textView.applyTextChecking(options)
        coordinator.configureFlow(mode: .plainText, options: options)
        let rangesReady = await waitUntil { textView.flowWritingToolsReady }
        XCTAssertTrue(rangesReady)

        textView.insertText(".", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == corrected
        }

        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.string, completed)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        XCTAssertEqual(textView.flowSuggestion?.source, .deterministic)
    }

    func testMixedSpellingAndImpreciseBroadGrammarNeverOffersPartialRepair() async {
        let source = "thse lanterns is ready"
        let box = EditorTextBox(source)
        let requestCount = EditorIntBox()
        let coordinator = makeCoordinator(
            box,
            flowCheckingClient: EditorFlowCheckingClient { checkedText, _, _, _, completion in
                requestCount.value += 1
                let checkedSource = checkedText as NSString
                completion([
                    NSTextCheckingResult.correctionCheckingResult(
                        range: checkedSource.range(of: "thse"),
                        replacementString: "these"
                    ),
                    NSTextCheckingResult.grammarCheckingResult(
                        range: checkedSource.range(of: "lanterns is"),
                        details: [[NSGrammarCorrections: ["lanterns are"]]]
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
        let suggestionReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence.contains("the cats are ready") == true
        }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(textView.flowSuggestion?.acceptance, .reviewOnly)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
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
        let firstReviewReady = await waitUntil {
            textView.flowSuggestion?.correctedSentence == firstCorrected
                && textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(firstReviewReady)
        XCTAssertEqual(aiRequestCount.value, 1)
        XCTAssertEqual(textView.string, completedSource)
        await renderFlowSuggestion(in: textView, window: window)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        let firstRepairReady = await waitUntil { textView.string == firstCorrected }
        XCTAssertTrue(firstRepairReady)
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
        let changedReviewReady = await waitUntil {
            aiRequestCount.value == 2
                && textView.flowSuggestion?.correctedSentence == mutatedCorrected
                && textView.flowSuggestion?.acceptance == .reviewOnly
        }
        XCTAssertTrue(changedReviewReady)
        XCTAssertEqual(aiRequestCount.value, 2)
        XCTAssertEqual(textView.string, mutatedSource)
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
}
