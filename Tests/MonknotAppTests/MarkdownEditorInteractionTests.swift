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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(textView.inlinePredictionType, .default)

        textView.insertText("a", replacementRange: textView.selectedRange())
        let refreshBlocked = await waitUntil { provider.isCallBlocked }
        XCTAssertTrue(refreshBlocked)
        XCTAssertEqual(textView.inlinePredictionType, .default)

        textView.insertText("1", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .default)
        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.inlinePredictionType, .default)
        XCTAssertFalse(textView.flowWritingToolsReady)

        provider.resumeBlockedCall()
        let currentScanFinished = await waitUntil(timeout: 3) {
            textView.flowWritingToolsReady && provider.activeCallCount == 0
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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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

        XCTAssertEqual(textView.inlinePredictionType, .default)
        textView.didChangeText()
        XCTAssertEqual(textView.inlinePredictionType, .default)
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
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(grammar & NSTextCheckingResult.CheckingType.correction.rawValue, 0)
        XCTAssertNotEqual(grammar & NSTextCheckingResult.CheckingType.grammar.rawValue, 0)
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

    func testFlowSuggestionRejectsEveryStaleIdentityDimension() {
        let source = "Fix teh "
        let checkedRange = (source as NSString).range(of: "teh")
        let selection = NSRange(location: (source as NSString).length, length: 0)
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 4,
            selectedRange: selection,
            caretUTF16Offset: selection.location,
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
        let single = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: 4, length: 0),
            caretUTF16Offset: 4,
            edits: [EditorFlowCorrectionEdit(
                range: NSRange(location: 0, length: 3),
                originalText: "teh",
                replacementText: "the",
                kind: .spelling
            )]
        )

        XCTAssertEqual(single.fullChangeRows, ["teh → the"])
        XCTAssertEqual(
            single.accessibilityText,
            "Replace “teh” with “the”. Tab to continue; Escape to dismiss."
        )

        let batch = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 2,
            selectedRange: NSRange(location: 17, length: 0),
            caretUTF16Offset: 17,
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

        XCTAssertEqual(
            batch.fullChangeRows,
            ["teh → the", "is → are"]
        )
        XCTAssertEqual(
            batch.accessibilityText,
            "Fix 2 clear issues: replace “teh” with “the”, replace “is” with “are”. "
                + "Tab to continue; Escape to dismiss."
        )
    }

    func testFlowCueLayoutNeverTruncatesAppliedEditsAndScalesGeometry() throws {
        let suggestion = EditorFlowSuggestion(
            documentID: "note.md",
            revision: 1,
            selectedRange: NSRange(location: 50, length: 0),
            caretUTF16Offset: 50,
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
            editorFont: font,
            zoomScale: 1
        )
        XCTAssertEqual(wide.mode, .direct)
        XCTAssertEqual(wide.rows, [suggestion.fullChangeRows.joined(separator: " · ")])
        XCTAssertFalse(wide.rows.joined().contains("…"))

        var stackedLayout: EditorFlowCueLayout?
        for width in 120...900 {
            let candidate = EditorFlowCueLayout.make(
                for: suggestion,
                availableWidth: CGFloat(width),
                editorFont: font,
                zoomScale: 1
            )
            if candidate.mode == .direct, candidate.rows.count == 2 {
                stackedLayout = candidate
                break
            }
        }
        let stacked = try XCTUnwrap(stackedLayout)
        XCTAssertEqual(stacked.rows, suggestion.fullChangeRows)
        XCTAssertEqual(stacked.size.height, 60)

        let review = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 100,
            editorFont: font,
            zoomScale: 1
        )
        XCTAssertEqual(review.mode, .review)
        XCTAssertTrue(review.rows.first?.hasPrefix("Review") == true)

        let zoomed = EditorFlowCueLayout.make(
            for: suggestion,
            availableWidth: 2_000,
            editorFont: font,
            zoomScale: 2
        )
        XCTAssertEqual(zoomed.rowHeight, 60)
        XCTAssertEqual(zoomed.cornerRadius, 24)
    }

    func testFlowAccessibilityActionsNameEveryExactChangeWithoutTruncation() {
        let source = "abcdefghijklmnopqrstuvwx zyxwvutsrqponmlkjihgfe"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        let suggestion = EditorFlowSuggestion(
            documentID: coordinator.documentID!,
            revision: coordinator.revision,
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location,
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
        XCTAssertTrue(names.contains { $0.hasPrefix("Accept correction:") })
        XCTAssertTrue(names.contains { $0.hasPrefix("Dismiss correction:") })
        XCTAssertTrue(names.contains { $0.hasPrefix("Review correction:") })
        for name in names {
            XCTAssertTrue(name.contains("abcdefghijklmnopqrstuvwx"))
            XCTAssertTrue(name.contains("ABCDEFGHIJKLMNOPQRSTUVWX"))
            XCTAssertTrue(name.contains("zyxwvutsrqponmlkjihgfe"))
            XCTAssertTrue(name.contains("ZYXWVUTSRQPONMLKJIHGFE"))
            XCTAssertFalse(name.contains("…"))
        }
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
        XCTAssertEqual(textView.flowSuggestion?.edits.first?.replacementText, "the")
        XCTAssertEqual(textView.string, "teh ")
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
        XCTAssertEqual(textView.flowSuggestion?.fullChangeRows, ["teh → the"])
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

    func testMarkdownListIndentationKeepsPriorityOverVisibleFlowCorrection() throws {
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

        XCTAssertEqual(textView.string, "  - teh ")
        XCTAssertEqual(box.value, "  - teh ")
        XCTAssertNil(textView.flowSuggestion)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(box.value, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testNarrowFlowTabAndOptionReturnOpenReviewWithoutMutatingText() throws {
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
                    NSTextCheckingResult.grammarCheckingResult(
                        range: grammarRange,
                        details: [[NSGrammarCorrections: ["are"]]]
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
        XCTAssertEqual(
            textView.flowSuggestion?.fullChangeRows,
            ["teh → the", "is → are"]
        )
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
                    ], nil)
                case "The dogs am playig.":
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: "am",
                            corrections: ["is", "are"]
                        ),
                        NSTextCheckingResult.spellCheckingResult(
                            range: (checkedText as NSString).range(of: "playig")
                        ),
                    ], nil)
                case "The dogs are playig.":
                    completion([
                        NSTextCheckingResult.spellCheckingResult(
                            range: (checkedText as NSString).range(of: "playig")
                        ),
                    ], nil)
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
            "The dogs am playig.",
            "The dogs are playig.",
        ])
        XCTAssertTrue(requestedTypes.dropFirst().allSatisfy {
            $0 & NSTextCheckingResult.CheckingType.spelling.rawValue != 0
                && $0 & NSTextCheckingResult.CheckingType.grammar.rawValue != 0
        })
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.originalText), ["is", "playig"])
        XCTAssertEqual(textView.flowSuggestion?.edits.map(\.replacementText), ["are", "playing"])
        XCTAssertEqual(
            textView.flowSuggestion?.fullChangeRows,
            ["is → are", "playig → playing"]
        )

        textView.undoManager?.removeAllActions()
        recordingTextView.approvedChanges.removeAll()
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

    func testSentenceBatchNeverAppliesAnUnseenThirdCorrection() async throws {
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
        let suggestionReady = await waitUntil { textView.flowSuggestion?.edits.count == 2 }
        XCTAssertTrue(suggestionReady)
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.originalText),
            ["teh", "adn"]
        )
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.replacementText),
            ["the", "and"]
        )
        XCTAssertEqual(
            textView.flowSuggestion?.fullChangeRows,
            ["teh → the", "adn → and"]
        )
        XCTAssertFalse(textView.flowSuggestion?.fullChangeRows.joined().contains("wierd") == true)
        textView.undoManager?.removeAllActions()

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))

        XCTAssertEqual(textView.string, "the and wierd.")
        XCTAssertEqual(box.value, "the and wierd.")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh adn wierd.")
        XCTAssertEqual(box.value, "teh adn wierd.")
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testFlowRoutesLongClauseRewriteToWritingToolsInsteadOfTruncatedTabCue() async {
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
                                "This substantially rewritten clause is intentionally longer."
                            ],
                        ]]
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
        let checkerFinished = await waitUntil { requestCount.value > 0 }
        XCTAssertTrue(checkerFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(textView.flowSuggestion)
        XCTAssertEqual(textView.string, source + ".")
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

    func testReturnOffersPreviousListSentenceBatchWithoutStealingStructuralTab() async throws {
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
                    NSTextCheckingResult.grammarCheckingResult(
                        range: grammarRange,
                        details: [[NSGrammarCorrections: ["are"]]]
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
        XCTAssertEqual(
            textView.flowSuggestion?.fullChangeRows,
            ["teh → the", "is → are"]
        )
        XCTAssertEqual(
            textView.flowSuggestion?.edits.map(\.range),
            [
                (textView.string as NSString).range(of: "teh"),
                (textView.string as NSString).range(of: "is"),
            ]
        )

        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "- teh cats is ready\n  - ")
        XCTAssertEqual(box.value, "- teh cats is ready\n  - ")
        XCTAssertNil(textView.flowSuggestion)
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

        textView.insertText(" ", replacementRange: textView.selectedRange())
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
        let newTargetLocation = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: newTargetLocation, length: 0))
        textView.insertText("teh ", replacementRange: textView.selectedRange())
        let newSuggestionReady = await waitUntil {
            textView.flowSuggestion?.edits.first?.range.location == newTargetLocation
        }

        XCTAssertTrue(newSuggestionReady)
        XCTAssertEqual(textView.string, "the teh ")
        XCTAssertEqual(
            textView.flowSuggestion?.edits.first?.range,
            NSRange(location: newTargetLocation, length: 3)
        )
        XCTAssertEqual(textView.flowSuggestion?.fullChangeRows, ["teh → the"])
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

        textView.insertText(" ", replacementRange: textView.selectedRange())
        let suggestionReady = await waitUntil { textView.flowSuggestion != nil }
        XCTAssertTrue(suggestionReady)
        textView.keyDown(with: try XCTUnwrap(keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: 48,
            windowNumber: window.windowNumber
        )))
        XCTAssertEqual(textView.string, "the ")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "teh ")
        XCTAssertEqual(box.value, "teh ")
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
        XCTAssertEqual(textView.string, "teh ")
    }

    func testVisibleFlowCorrectionSuppressesNativeInlinePredictionThenDismissRestoresIt() async {
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
        coordinator.refreshNativeFlowAvailability()
        XCTAssertEqual(textView.inlinePredictionType, .default)

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
        XCTAssertEqual(textView.inlinePredictionType, .default)
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
        XCTAssertEqual(textView.flowSuggestion?.fullChangeRows, ["teh → the"])
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
                    ], nil)
                    return
                }

                let replacement = checkedText.contains(" are ") ? "are" : "were"
                if cleanReplacements.contains(replacement) {
                    completion([], nil)
                } else {
                    completion([
                        self.grammarResult(
                            in: checkedText,
                            target: replacement,
                            corrections: ["is"]
                        ),
                    ], nil)
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
        textView.flowSuggestionDismissalHandler = { coordinator.dismissFlowSuggestion() }
        textView.flowSuggestionCancellationHandler = { coordinator.cancelFlowForFocusLoss() }
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
            selectedRange: textView.selectedRange(),
            caretUTF16Offset: textView.selectedRange().location + textView.selectedRange().length,
            edits: [EditorFlowCorrectionEdit(
                range: (textView.string as NSString).range(of: checkedText),
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

private final class FlowTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@available(macOS 15.0, *)
private final class ActiveWritingToolsTextView: MarkdownNSTextView {
    override var isWritingToolsActive: Bool { true }
}
