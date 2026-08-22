import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownEditorBasicInteractionTests: FlowEditorTestCase {
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

    func testInlineReviewUsesNormalTextAndHighlightsOnlyChangedWordWithThemeAccent() async throws {
        let source = "We will probbly finish before sunrise."
        let corrected = "We will probably finish before sunrise."
        let sourceText = source as NSString
        let correctedText = corrected as NSString
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(
            coordinator: coordinator,
            text: source
        )
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let typoRange = sourceText.range(of: "probbly")
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
                replacementText: "probably",
                kind: .spelling
            )]
        )
        let theme = AppTheme.defaultDark.replacing(accent: "#20B486")
        textView.applyFlowThemeForTesting(theme)
        textView.flowSuggestion = suggestion
        await renderFlowSuggestion(in: textView, window: window)

        let changedWord = correctedText.range(of: "probably")
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
        let source = "The lanterns is ready."
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
}
