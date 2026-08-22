import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WritingToolsLifecycleTests: FlowEditorTestCase {
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

        let defaultsName = "Monknot.WritingToolsLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = WorkspaceStore(userDefaults: defaults)
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
}
