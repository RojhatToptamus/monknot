import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownEditorInteractionTests: XCTestCase {
    func testNativeTextCheckingPreferencesNeverEnableAutomaticRewriting() {
        let textView = MarkdownNSTextView()
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true

        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: true,
            checksGrammar: true
        ))

        XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)

        textView.applyTextChecking(EditorTextCheckingOptions(
            checksSpelling: false,
            checksGrammar: false
        ))
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
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

    func testNativeSpellCheckerCanCheckMultipleInstalledLanguages() throws {
        let checker = NSSpellChecker.shared
        let cases = [
            (prefix: "en", misspelling: "helllo"),
            (prefix: "de", misspelling: "Hauus"),
        ]
        let installed = cases.compactMap { item -> (String, String)? in
            guard let language = checker.availableLanguages.first(where: {
                $0.lowercased().hasPrefix(item.prefix)
            }) else { return nil }
            return (language, item.misspelling)
        }
        guard installed.count == cases.count else {
            throw XCTSkip("English and German spell-check dictionaries are not both installed.")
        }

        for (language, misspelling) in installed {
            let range = checker.checkSpelling(
                of: misspelling,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            XCTAssertNotEqual(range.location, NSNotFound, "Expected \(language) to check \(misspelling)")
        }
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

    func testCurrentDocumentReplaceRevalidatesLiveBufferAndUsesNativeUndoRedo() throws {
        let source = "cat cat"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("cat")
        search.updateResult(coordinator.applySearch(search, theme: .defaultDark, in: textView).searchResult)

        let firstMatch = (textView.string as NSString).range(of: "cat")
        textView.insertText("dog", replacementRange: firstMatch)
        textView.undoManager?.removeAllActions()
        search.setReplacement("fox")
        search.replaceCurrent(in: "note.md")

        let application = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        let consumedSerial = try XCTUnwrap(application.consumedReplacementSerial)
        search.consumeReplacement(serial: consumedSerial)
        XCTAssertEqual(textView.string, "dog fox")
        XCTAssertEqual(box.value, "dog fox")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "dog cat")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "dog fox")
        withExtendedLifetime(window) {}
    }

    func testCurrentReplaceUsesVisibleMatchIndexWhenSourceEditorMountsFromPreview() {
        let source = "cat cat"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("cat")
        search.updateResult(.init(currentIndex: 2, totalCount: 2))
        search.setReplacement("dog")
        search.replaceCurrent(in: "note.md")

        _ = coordinator.applySearch(search, theme: .defaultDark, in: textView)

        XCTAssertEqual(textView.string, "cat dog")
        withExtendedLifetime(window) {}
    }

    func testReplaceAllIsOneUndoStepAndPreservesUnicodeCRLFAndSelection() throws {
        let source = "naïve\r\nNAIVE\r\nend"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("naive")
        search.updateResult(coordinator.applySearch(search, theme: .defaultDark, in: textView).searchResult)
        textView.setSelectedRange((source as NSString).range(of: "end"))
        textView.undoManager?.removeAllActions()
        search.setReplacement("🧭")
        search.replaceAll(in: "note.md")

        let application = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        XCTAssertEqual(application.searchResult.totalCount, 0)
        XCTAssertEqual(textView.string, "🧭\r\n🧭\r\nend")
        XCTAssertEqual(
            (textView.string as NSString).substring(with: textView.selectedRange()),
            "end"
        )

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "🧭\r\n🧭\r\nend")
        withExtendedLifetime(window) {}
    }

    func testReplaceAllUsesNonoverlappingCandidatesAndAllowsEmptyReplacement() {
        let source = "banana\r\nana"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("ana")
        search.updateResult(coordinator.applySearch(search, theme: .defaultDark, in: textView).searchResult)
        XCTAssertEqual(search.totalCount, 2)
        search.setReplacement("")
        search.replaceAll(in: "note.md")

        _ = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        XCTAssertEqual(textView.string, "bna\r\n")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        withExtendedLifetime(window) {}
    }

    func testCurrentDocumentSearchAndReplaceShareCaseAndWholeWordOptions() {
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
        search.updateResult(result.searchResult)
        search.setReplacement("dog")
        search.replaceAll(in: "note.md", options: options)
        _ = coordinator.applySearch(search, options: options, theme: .defaultDark, in: textView)

        XCTAssertEqual(result.searchResult.totalCount, 2)
        XCTAssertEqual(textView.string, "Cat dog scatter cat_2 dog-café")
        withExtendedLifetime(window) {}
    }

    func testReplacementRequestDoesNotEditReadOnlyOrDifferentDocument() throws {
        let source = "cat"
        let box = EditorTextBox(source)
        let coordinator = makeCoordinator(box)
        let (window, scrollView, textView) = makeHostedTextView(coordinator: coordinator, text: source)
        defer { dismantleHostedTextView(window, scrollView: scrollView, coordinator: coordinator) }
        var search = DocumentSearchState()
        search.present()
        search.setQuery("cat")
        search.setReplacement("dog")
        search.replaceAll(in: "different.md")

        let staleApplication = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        XCTAssertNotNil(staleApplication.consumedReplacementSerial)
        XCTAssertEqual(textView.string, source)
        search.consumeReplacement(serial: try XCTUnwrap(staleApplication.consumedReplacementSerial))

        textView.isEditable = false
        search.replaceAll(in: "note.md")
        let readOnlyApplication = coordinator.applySearch(search, theme: .defaultDark, in: textView)
        XCTAssertNotNil(readOnlyApplication.consumedReplacementSerial)
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

    private func makeCoordinator(_ box: EditorTextBox) -> MarkdownTextEditor.Coordinator {
        MarkdownTextEditor.Coordinator(
            text: Binding(
                get: { box.value },
                set: { box.value = $0 }
            )
        )
    }

    private func makeHostedTextView(
        coordinator: MarkdownTextEditor.Coordinator,
        text: String
    ) -> (NSWindow, NSScrollView, MarkdownNSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = MarkdownNSTextView(frame: scrollView.bounds)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scrollView.documentView = textView
        window.contentView = scrollView
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.externalTextDidChange()
        coordinator.attach(to: scrollView)
        window.makeFirstResponder(textView)
        return (window, scrollView, textView)
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
