import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp
@testable import MonknotCore

@MainActor
final class TypingAssistantEditorBridgeTests: XCTestCase {
    func testExactSuggestionAppliesThroughTextViewAndCanUndo() {
        let boundText = TextBox("She dont like coffee.")
        let coordinator = makeCoordinator(text: boundText)
        let (window, textView) = makeHostedTextView()
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.synchronizeExternalText(
            boundText.value,
            documentChanged: true
        )
        textView.setSelectedRange(
            NSRange(location: (boundText.value as NSString).length, length: 0)
        )

        var accepted: Bool?
        var editorChangeCount = 0
        coordinator.configureTypingAssistance(
            suggestion: suggestion(
                source: boundText.value,
                revision: 1,
                cursor: (boundText.value as NSString).length,
                replacement: "She doesn't like coffee."
            ),
            onEditorChange: { _ in
                editorChangeCount += 1
                return nil
            },
            onSelectionChange: nil,
            onDismissSuggestion: nil,
            onSuggestionApplicationFinished: { accepted = $0 }
        )

        XCTAssertTrue(coordinator.apply(.accept))
        XCTAssertEqual(textView.string, "She doesn't like coffee.")
        XCTAssertEqual(boundText.value, "She doesn't like coffee.")
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(editorChangeCount, 0)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "She dont like coffee.")
        withExtendedLifetime(window) {}
    }

    func testStaleRevisionCannotMutateEditorText() {
        let boundText = TextBox("Keep this text.")
        let coordinator = makeCoordinator(text: boundText)
        let (_, textView) = makeHostedTextView()
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.synchronizeExternalText(
            boundText.value,
            documentChanged: true
        )

        var accepted: Bool?
        coordinator.configureTypingAssistance(
            suggestion: suggestion(
                source: boundText.value,
                revision: 0,
                cursor: 0,
                replacement: "Changed."
            ),
            onEditorChange: nil,
            onSelectionChange: nil,
            onDismissSuggestion: nil,
            onSuggestionApplicationFinished: { accepted = $0 }
        )

        XCTAssertFalse(coordinator.apply(.accept))
        XCTAssertEqual(textView.string, "Keep this text.")
        XCTAssertEqual(boundText.value, "Keep this text.")
        XCTAssertEqual(accepted, false)
    }

    func testDismissDoesNotMutateEditorText() {
        let boundText = TextBox("Keep this text.")
        let coordinator = makeCoordinator(text: boundText)
        let (_, textView) = makeHostedTextView()
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.synchronizeExternalText(
            boundText.value,
            documentChanged: true
        )

        var dismissed = false
        coordinator.configureTypingAssistance(
            suggestion: suggestion(
                source: boundText.value,
                revision: 1,
                cursor: 0,
                replacement: "Changed."
            ),
            onEditorChange: nil,
            onSelectionChange: nil,
            onDismissSuggestion: { dismissed = true },
            onSuggestionApplicationFinished: nil
        )

        XCTAssertTrue(coordinator.apply(.dismiss))
        XCTAssertTrue(dismissed)
        XCTAssertEqual(textView.string, "Keep this text.")
        XCTAssertEqual(boundText.value, "Keep this text.")
    }

    func testUndoDoesNotImmediatelyReapplyBoundaryCorrection() async {
        let boundText = TextBox("")
        let coordinator = makeCoordinator(text: boundText)
        let (window, textView) = makeHostedTextView()
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.synchronizeExternalText("", documentChanged: true)
        let corrector = TypingAssistanceWordBoundaryCorrector()
        var automaticAccepted: Bool?
        coordinator.configureTypingAssistance(
            suggestion: nil,
            onEditorChange: { corrector.edit(for: $0) },
            onSelectionChange: { _ in },
            onDismissSuggestion: nil,
            onSuggestionApplicationFinished: nil,
            onAutomaticApplicationFinished: { _, accepted in
                automaticAccepted = accepted
            }
        )

        textView.insertText(
            "adn ",
            replacementRange: NSRange(location: 0, length: 0)
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(textView.string, "and ")
        XCTAssertEqual(automaticAccepted, true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "adn ")
        XCTAssertEqual(boundText.value, "adn ")
        withExtendedLifetime(window) {}
    }

    func testRemovingHighlightAfterLargeDeletionUsesCurrentTextBounds() {
        let boundText = TextBox("She dont like coffee.")
        let coordinator = makeCoordinator(text: boundText)
        let (window, textView) = makeHostedTextView()
        coordinator.textView = textView
        coordinator.documentID = "note.md"
        coordinator.synchronizeExternalText(
            boundText.value,
            documentChanged: true
        )
        coordinator.configureTypingAssistance(
            suggestion: suggestion(
                source: boundText.value,
                revision: 1,
                cursor: (boundText.value as NSString).length,
                replacement: "She doesn't like coffee."
            ),
            onEditorChange: nil,
            onSelectionChange: nil,
            onDismissSuggestion: nil,
            onSuggestionApplicationFinished: nil
        )
        coordinator.applyTypingAssistantHighlight(
            theme: CodexThemeCatalog.lightPresets[0].theme,
            in: textView
        )

        boundText.value = "x"
        coordinator.synchronizeExternalText(
            boundText.value,
            documentChanged: false
        )
        coordinator.configureTypingAssistance(
            suggestion: nil,
            onEditorChange: nil,
            onSelectionChange: nil,
            onDismissSuggestion: nil,
            onSuggestionApplicationFinished: nil
        )
        coordinator.applyTypingAssistantHighlight(
            theme: CodexThemeCatalog.lightPresets[0].theme,
            in: textView
        )

        XCTAssertEqual(textView.string, "x")
        XCTAssertNil(
            textView.layoutManager?.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: 0,
                effectiveRange: nil
            )
        )
        withExtendedLifetime(window) {}
    }

    private func makeCoordinator(
        text: TextBox
    ) -> MarkdownTextEditor.Coordinator {
        let binding = Binding<String>(
            get: { text.value },
            set: { text.value = $0 }
        )
        return MarkdownTextEditor.Coordinator(text: binding)
    }

    private func makeHostedTextView() -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = NSTextView(frame: scrollView.bounds)
        textView.allowsUndo = true
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        return (window, textView)
    }

    private func suggestion(
        source: String,
        revision: Int,
        cursor: Int,
        replacement: String
    ) -> TypingAssistanceSuggestion {
        TypingAssistanceSuggestion(
            requestKind: .grammar,
            sourceDocumentID: "note.md",
            sourceRevision: revision,
            sourceText: source,
            sourceCursorUTF16Offset: cursor,
            replacementRange: NSRange(
                location: 0,
                length: (source as NSString).length
            ),
            replacementText: replacement,
            model: "fake",
            latencyMilliseconds: 1
        )
    }
}

private final class TextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}
