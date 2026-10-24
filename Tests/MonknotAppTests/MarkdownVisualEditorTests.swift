import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Preview edits Markdown in place. These tests drive the real page in WebKit: keystrokes go
/// through AppKit's text input, undo through the Edit menu's undo manager, and the store must end
/// up with exactly the Markdown a user would expect, never a rewrite of what they did not touch.
@MainActor
final class MarkdownVisualEditorTests: WorkspaceStoreTestCase {
    private var hostWindows: [NSWindow] = []

    override func tearDown() async throws {
        for window in hostWindows {
            window.contentView = nil
            window.close()
        }
        hostWindows.removeAll()
        try await super.tearDown()
    }

    // MARK: - Typing

    func testTypingInPreviewChangesOnlyTheTypedText() async throws {
        let source = "# Title\n\nHello **bold** world\n\n<!-- kept as written -->\n\n[ref]: https://example.com\n"
        let fixture = try await makeFixture(markdown: source)

        let caret = (source as NSString).range(of: "bold").location + 4
        try await fixture.setSelection(caret)
        fixture.type("er")

        let typed = await waitUntil { fixture.store.documentText.contains("bolder") }
        XCTAssertTrue(typed, fixture.store.documentText)
        XCTAssertEqual(
            fixture.store.documentText,
            "# Title\n\nHello **bolder** world\n\n<!-- kept as written -->\n\n[ref]: https://example.com\n",
            "Typing at the end of bold text continues it and leaves everything else byte for byte"
        )
        XCTAssertTrue(fixture.store.hasUnsavedChanges)
    }

    func testReturnSplitsAndBackspaceJoinsParagraphs() async throws {
        let source = "First paragraph\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection(5)
        fixture.press(.return)
        let split = await waitUntil { fixture.store.documentText == "First\n\n paragraph\n" }
        XCTAssertTrue(split, fixture.store.documentText)

        fixture.press(.backspace)
        let joined = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(joined, fixture.store.documentText)
    }

    func testBackspaceAtTheStartOfAMiddleItemLeavesTextBetweenTwoLists() async throws {
        let source = "- [ ] Draft\n- [ ] Review\n- [x] Ship\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection((source as NSString).range(of: "Review").location)
        fixture.press(.backspace)
        let expected = "- [ ] Draft\n\nReview\n\n- [x] Ship\n"
        let changed = await waitUntil { fixture.store.documentText == expected }
        XCTAssertTrue(changed, fixture.store.documentText)
        // Without the blank lines Markdown reads the text as more of "Draft".
        let page = try await fixture.evaluate("[...document.querySelectorAll('#content > *')].map(e => e.tagName + ':' + e.textContent.trim()).join('|')") as? String
        XCTAssertEqual(page, "UL:Draft|P:Review|UL:Ship")

        fixture.type("Now ")
        let typed = await waitUntil { fixture.store.documentText == "- [ ] Draft\n\nNow Review\n\n- [x] Ship\n" }
        XCTAssertTrue(typed, "The caret stays at the start of the text: \(fixture.store.documentText)")
    }

    func testLeavingAListAtTheEndOfANewFileStartsAParagraph() async throws {
        // A new file has no final line break, so the list's last line ends the file.
        let fixture = try await makeFixture(markdown: "")
        try await fixture.setSelection(0)
        fixture.type("- ")
        fixture.type("Milk")
        fixture.press(.return)
        fixture.press(.return)
        fixture.type("Next")
        let typed = await waitUntil { fixture.store.documentText == "- Milk\n\nNext\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        let page = try await fixture.evaluate("[...document.querySelectorAll('#content > *')].map(e => e.tagName + ':' + e.textContent.trim()).join('|')") as? String
        XCTAssertEqual(page, "UL:Milk|P:Next")
    }

    func testMarkdownShortcutsTurnALineIntoABlock() async throws {
        let fixture = try await makeFixture(markdown: "Intro\n")
        let end = ("Intro" as NSString).length
        try await fixture.setSelection(end)
        fixture.press(.return)
        fixture.type("- ")
        fixture.type("Milk")
        let listed = await waitUntil { fixture.store.documentText.contains("- Milk") }
        XCTAssertTrue(listed, fixture.store.documentText)
        let rendered = try await fixture.evaluate("document.querySelector('#content ul li')?.textContent ?? ''") as? String
        XCTAssertEqual(rendered, "Milk")
    }

    // MARK: - Undo

    func testUndoAndRedoGoThroughTheEditMenuUndoManager() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n")
        try await fixture.setSelection(5)
        fixture.type(" beta")
        let typed = await waitUntil { fixture.store.documentText == "Alpha beta\n" }
        XCTAssertTrue(typed, fixture.store.documentText)

        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertTrue(undoManager.canUndo, "The Edit menu's Undo is enabled")
        XCTAssertEqual(undoManager.undoActionName, "Typing")
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "Alpha\n" }
        XCTAssertTrue(undone, "One undo reverts the whole typing run: \(fixture.store.documentText)")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        let redone = await waitUntil { fixture.store.documentText == "Alpha beta\n" }
        XCTAssertTrue(redone, fixture.store.documentText)
    }

    func testUndoSurvivesSwitchingToSourceAndBack() async throws {
        let fixture = try await makeFixture(markdown: "One\n")
        try await fixture.setSelection(3)
        fixture.type(" two")
        let typed = await waitUntil { fixture.store.documentText == "One two\n" }
        XCTAssertTrue(typed)

        fixture.harness.editorMode = .source
        let sourceShown = await waitUntil { fixture.documentTextView() != nil }
        XCTAssertTrue(sourceShown)
        fixture.harness.editorMode = .preview
        let webView = try await fixture.waitForEditor()
        let undoManager = try XCTUnwrap(webView.undoManager)
        XCTAssertTrue(undoManager.canUndo, "Preview's history outlives its page")
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "One\n" }
        XCTAssertTrue(undone, fixture.store.documentText)
    }

    /// An undo that no longer fits the text (Source changed part of the typed words) changes
    /// nothing: not the characters that still match, and nothing to redo afterwards.
    func testUndoAfterSourceChangedTheTypedWordsChangesNothing() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n")
        try await fixture.setSelection(5)
        fixture.type(" beta")
        let typed = await waitUntil { fixture.store.documentText == "Alpha beta\n" }
        XCTAssertTrue(typed, fixture.store.documentText)

        let webView = try await fixture.editInSource { $0.replacingOccurrences(of: "beta", with: "bXta") }
        let undoManager = try XCTUnwrap(webView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.store.documentText, "Alpha bXta\n", "No part of the typing run is taken back")
        let page = try await fixture.evaluate("window.MonknotEditor.source()") as? String
        XCTAssertEqual(page, "Alpha bXta\n")
        XCTAssertFalse(undoManager.canRedo, "A refused undo leaves nothing to redo")
    }

    /// Undoing a deletion inserts the deleted text again only where it was: after Source moved the
    /// text, it inserts nothing anywhere.
    func testUndoingADeletionAfterSourceMovedTheTextInsertsNothing() async throws {
        let fixture = try await makeFixture(markdown: "One two three\n")
        try await fixture.setSelection(8)
        for _ in 0..<4 { fixture.press(.backspace) }
        let deleted = await waitUntil { fixture.store.documentText == "One three\n" }
        XCTAssertTrue(deleted, fixture.store.documentText)

        let webView = try await fixture.editInSource { "Zero " + $0 }
        let undoManager = try XCTUnwrap(webView.undoManager)
        undoManager.undo()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.store.documentText, "Zero One three\n")
        XCTAssertFalse(undoManager.canRedo)
    }

    /// A Source edit away from a step leaves it undoable and redoable.
    func testUndoAfterAnUnrelatedSourceEditStillApplies() async throws {
        let tail = String(repeating: "Unrelated words in a later paragraph. ", count: 3)
        let fixture = try await makeFixture(markdown: "Alpha\n\n\(tail)\n")
        try await fixture.setSelection(5)
        fixture.type(" beta")
        let typed = await waitUntil { fixture.store.documentText.hasPrefix("Alpha beta\n") }
        XCTAssertTrue(typed, fixture.store.documentText)

        let webView = try await fixture.editInSource { $0 + "\nAdded in Source\n" }
        let undoManager = try XCTUnwrap(webView.undoManager)
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "Alpha\n\n\(tail)\n\nAdded in Source\n" }
        XCTAssertTrue(undone, fixture.store.documentText)
        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        let redone = await waitUntil { fixture.store.documentText == "Alpha beta\n\n\(tail)\n\nAdded in Source\n" }
        XCTAssertTrue(redone, fixture.store.documentText)
        let page = try await fixture.evaluate("window.MonknotEditor.source()") as? String
        XCTAssertEqual(page, fixture.store.documentText)
    }

    /// The page restarts its undo groups when it renders again; typing on a new page must not join
    /// the last step of the page before.
    func testTypingOnANewPageStartsItsOwnUndoStep() async throws {
        let fixture = try await makeFixture(markdown: "One\n")
        try await fixture.setSelection(3)
        fixture.type(" two")
        let typed = await waitUntil { fixture.store.documentText == "One two\n" }
        XCTAssertTrue(typed, fixture.store.documentText)

        let webView = try await fixture.editInSource { $0 }
        try await fixture.setSelection(7)
        fixture.type(" three")
        let typedAgain = await waitUntil { fixture.store.documentText == "One two three\n" }
        XCTAssertTrue(typedAgain, fixture.store.documentText)

        let undoManager = try XCTUnwrap(webView.undoManager)
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "One two\n" }
        XCTAssertTrue(undone, "Only the typing on the new page is taken back: \(fixture.store.documentText)")
        XCTAssertTrue(undoManager.canUndo, "The typing on the page before is still a step")
        undoManager.undo()
        let undoneAgain = await waitUntil { fixture.store.documentText == "One\n" }
        XCTAssertTrue(undoneAgain, fixture.store.documentText)
    }

    /// Typed characters merge into one patch, so an undo is one change on the page, not one per key.
    func testOneUndoOfATypingRunIsOneChangeOnThePage() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n")
        try await fixture.setSelection(5)
        fixture.type(" beta gamma")
        let typed = await waitUntil { fixture.store.documentText == "Alpha beta gamma\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        let version = try await fixture.evaluate("window.MonknotEditor.version()") as? Int
        fixture.webView.undoManager?.undo()
        let undone = await waitUntil { fixture.store.documentText == "Alpha\n" }
        XCTAssertTrue(undone, fixture.store.documentText)
        let synced = await waitUntil {
            ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == "Alpha\n"
        }
        XCTAssertTrue(synced)
        let after = try await fixture.evaluate("window.MonknotEditor.version()") as? Int
        XCTAssertEqual(after, (version ?? 0) + 1, "The page applied the whole step as one patch")
    }

    /// A change from outside the editor leaves no step that could still fit; typing after it
    /// starts a new history.
    func testAChangeFromOutsideEndsTheUndoHistory() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n")
        try await fixture.setSelection(5)
        fixture.type(" beta")
        let typed = await waitUntil { fixture.store.documentText == "Alpha beta\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)

        fixture.store.setDocumentText("Intro\n\nAlpha beta\n")
        let synced = await waitUntil {
            ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == "Intro\n\nAlpha beta\n"
        }
        XCTAssertTrue(synced)
        XCTAssertFalse(undoManager.canUndo, "The steps before the change no longer fit the text")

        try await fixture.setSelection(("Intro\n\nAlpha beta" as NSString).length)
        fixture.type("!")
        let typedAgain = await waitUntil { fixture.store.documentText == "Intro\n\nAlpha beta!\n" }
        XCTAssertTrue(typedAgain, fixture.store.documentText)
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == "Intro\n\nAlpha beta\n" }
        XCTAssertTrue(undone, fixture.store.documentText)
    }

    // MARK: - Formatting and structure

    func testBoldCommandWrapsTheSelectionAndKeepsItSelected() async throws {
        let fixture = try await makeFixture(markdown: "Make this strong\n")
        try await fixture.setSelection(10, 16)
        _ = try await fixture.evaluate("window.MonknotEditor.command('bold')")
        let bolded = await waitUntil { fixture.store.documentText == "Make this **strong**\n" }
        XCTAssertTrue(bolded, fixture.store.documentText)
        let selection = try await fixture.evaluate("JSON.stringify(window.MonknotEditor.selection())") as? String
        XCTAssertEqual(selection, #"{"anchor":12,"head":18}"#, "The same words stay selected")
    }

    func testTaskCheckboxTogglesTheSource() async throws {
        let fixture = try await makeFixture(markdown: "- [ ] Ship it\n")
        _ = try await fixture.evaluate("""
        (() => {
          const box = document.querySelector('input[data-monknot-task]');
          box.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
          return true;
        })()
        """)
        let checked = await waitUntil { fixture.store.documentText == "- [x] Ship it\n" }
        XCTAssertTrue(checked, fixture.store.documentText)
        XCTAssertEqual(fixture.webView.undoManager?.undoActionName, "Toggle Task")
    }

    func testCommandKOpensTheLinkEditorAndAppliesTheLink() async throws {
        let fixture = try await makeFixture(markdown: "Read the docs today\n")
        try await fixture.setSelection(9, 13)
        fixture.press(.character("k"), modifiers: .command)
        let opened = await waitUntil {
            ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-link-editor.mk-visible')) && document.activeElement === document.querySelector('.mk-field')")) as? Bool) == true
        }
        XCTAssertTrue(opened, "⌘K opens the link field with focus in it")
        _ = try await fixture.evaluate("""
        (() => {
          const field = document.querySelector('.mk-field');
          field.value = 'https://monki.work/docs';
          field.form.requestSubmit();
          return true;
        })()
        """)
        let linked = await waitUntil { fixture.store.documentText == "Read the [docs](https://monki.work/docs) today\n" }
        XCTAssertTrue(linked, fixture.store.documentText)
        let focusBack = try await fixture.evaluate("document.activeElement === document.getElementById('content')") as? Bool
        XCTAssertEqual(focusBack, true, "Applying the link returns focus to the text")
    }

    func testPastingRichTextInsertsMarkdown() async throws {
        let fixture = try await makeFixture(markdown: "Start\n")
        try await fixture.setSelection(5)
        _ = try await fixture.evaluate("""
        (() => {
          const data = new DataTransfer();
          data.setData('text/html', '<h2>Plan</h2><p>Ship <b>this</b> and <a href="https://monki.work">that</a>.</p><ul><li>One</li><li>Two</li></ul>');
          data.setData('text/plain', 'Plan Ship this and that. One Two');
          document.getElementById('content').dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
          return true;
        })()
        """)
        let pasted = await waitUntil { fixture.store.documentText.contains("- Two") }
        XCTAssertTrue(pasted, fixture.store.documentText)
        XCTAssertEqual(
            fixture.store.documentText,
            "Start## Plan\n\nShip **this** and [that](https://monki.work).\n\n- One\n- Two\n"
        )
        XCTAssertEqual(fixture.webView.undoManager?.undoActionName, "Paste")
    }

    func testCopyPutsBalancedMarkdownAndHTMLOnThePasteboard() async throws {
        let source = "Plain **bold words** end\n"
        let fixture = try await makeFixture(markdown: source)
        let start = (source as NSString).range(of: "words").location
        try await fixture.setSelection(start, start + 5)
        let copied = try await fixture.evaluate("""
        (() => {
          const data = new DataTransfer();
          document.getElementById('content').dispatchEvent(new ClipboardEvent('copy', { clipboardData: data, bubbles: true, cancelable: true }));
          return [data.getData('text/plain'), data.getData('text/html')];
        })()
        """) as? [String]
        XCTAssertEqual(copied?.first, "**words**", "A copy from inside bold text stays bold as Markdown")
        XCTAssertEqual(copied?.last?.contains("data-mk"), false, "The HTML carries no editor attributes")
    }

    func testCompositionIsTurnedIntoOnePatch() async throws {
        let fixture = try await makeFixture(markdown: "Cafe\n")
        try await fixture.setSelection(4)
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
          const text = root.querySelector('p').firstChild;
          text.data = 'Café';
          root.dispatchEvent(new InputEvent('input', { inputType: 'insertCompositionText', data: 'é', bubbles: true }));
          root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'é' }));
          return true;
        })()
        """)
        let composed = await waitUntil { fixture.store.documentText == "Caféé\n" || fixture.store.documentText == "Café\n" }
        XCTAssertTrue(composed, fixture.store.documentText)
        XCTAssertEqual(fixture.store.documentText, "Café\n", "The page's text after composing becomes the source")
    }

    func testTabMovesBetweenCellsAndAddsARowAtTheEnd() async throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let fixture = try await makeFixture(markdown: source)
        let last = (source as NSString).range(of: "2 |").location + 1
        try await fixture.setSelection(last)
        fixture.press(.tab)
        let added = await waitUntil { fixture.store.documentText.hasSuffix("| 1 | 2 |\n|  |  |\n") }
        XCTAssertTrue(added, fixture.store.documentText)
        fixture.type("3")
        let typed = await waitUntil { fixture.store.documentText.hasSuffix("| 3 |  |\n") }
        XCTAssertTrue(typed, fixture.store.documentText)
        let barShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-table-bar.mk-visible'))") as? Bool
        XCTAssertEqual(barShown, true, "The table bar shows while the caret is in a table")
    }

    // MARK: - Wikilinks

    private static let wikilinkNotes = ["Prototype.md", "Project Plan.md", "Improve process.md", "Archive/Meeting.md"]
    private static let wikilinkMenuRows = "[...document.querySelectorAll('.mk-menu.mk-visible[aria-label=\"Link to page\"] .mk-row-label')].map(e => e.textContent)"

    func testTypingDoubleBracketOpensTheNoteMenu() async throws {
        let fixture = try await makeFixture(markdown: "See\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(3)
        fixture.type(" [[")

        let rows = await fixture.wikilinkRows(matching: { !$0.isEmpty })
        XCTAssertEqual(
            rows,
            WikilinkAutocompleteService.suggestions(partial: "", documents: fixture.store.markdownDocuments),
            "The menu lists the notes Source would complete, in Source's order"
        )
        XCTAssertEqual(rows, ["Improve process", "Meeting", "Note", "Project Plan", "Prototype"])
        XCTAssertEqual(fixture.store.documentText, "See [[\n", "The brackets stay typed while the menu is open")
        let selected = try await fixture.evaluate("document.querySelector('.mk-menu.mk-visible .mk-menu-row.mk-selected .mk-row-label')?.textContent ?? ''") as? String
        XCTAssertEqual(selected, "Improve process", "The first note is selected")
        let slashShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible[aria-label=\"Insert block\"]'))") as? Bool
        XCTAssertEqual(slashShown, false)
    }

    func testWikilinkQueryFiltersAndTabInsertsTheTopNote() async throws {
        let fixture = try await makeFixture(markdown: "See\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(3)
        fixture.type(" [[pro")

        let filtered = await fixture.wikilinkRows(matching: { $0.first == "Prototype" })
        XCTAssertEqual(filtered, ["Prototype", "Project Plan", "Improve process"], "Prefix matches first, shorter titles first, then titles containing the text")
        XCTAssertEqual(filtered, WikilinkAutocompleteService.suggestions(partial: "pro", documents: fixture.store.markdownDocuments))

        fixture.type("j")
        let narrowed = await fixture.wikilinkRows(matching: { $0 == ["Project Plan"] })
        XCTAssertEqual(narrowed, ["Project Plan"])

        fixture.press(.tab)
        let inserted = await waitUntil { fixture.store.documentText == "See [[Project Plan]]\n" }
        XCTAssertTrue(inserted, fixture.store.documentText)
        let menuShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))") as? Bool
        XCTAssertEqual(menuShown, false, "Choosing a note closes the menu")
    }

    /// Ranking runs off the main thread, so a list can arrive after ↓: the row the keys moved to stays
    /// highlighted while it is listed, and ↩ chooses it.
    func testAListArrivingAfterTheKeysMovedKeepsTheirRow() async throws {
        let fixture = try await makeFixture(markdown: "See\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(3)
        fixture.type(" [[pro")
        let rows = await fixture.wikilinkRows(matching: { $0.first == "Prototype" && $0.contains("Project Plan") })
        fixture.press(.down)
        // The same list again, as a late answer: the page takes only the one carrying its current
        // query's serial, whichever of these that is.
        let titles = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        _ = try await fixture.evaluate("for (let serial = 1; serial <= 20; serial += 1) window.MonknotEditor.wikilinkSuggestions({ serial, titles: \(titles) }); true")
        let highlighted = try await fixture.evaluate("document.querySelector('.mk-menu.mk-visible .mk-menu-row.mk-selected .mk-row-label')?.textContent ?? ''") as? String
        XCTAssertEqual(highlighted, "Project Plan", "The list that arrived kept the row ↓ moved to")
        fixture.press(.return)
        let inserted = await waitUntil { fixture.store.documentText == "See [[Project Plan]]\n" }
        XCTAssertTrue(inserted, fixture.store.documentText)
    }

    func testChoosingANoteInsertsTheLinkAsOneUndoableStepWithTheCaretAfterIt() async throws {
        let fixture = try await makeFixture(markdown: "See\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(3)
        fixture.type(" [[pro")
        _ = await fixture.wikilinkRows(matching: { $0.first == "Prototype" })

        fixture.press(.down)
        let moved = try await fixture.evaluate("document.querySelector('.mk-menu.mk-visible .mk-menu-row.mk-selected .mk-row-label')?.textContent ?? ''") as? String
        XCTAssertEqual(moved, "Project Plan", "↓ moves the selection")
        fixture.press(.return)
        let inserted = await waitUntil { fixture.store.documentText == "See [[Project Plan]]\n" }
        XCTAssertTrue(inserted, "↩ replaces the brackets and query, and nothing else: \(fixture.store.documentText)")
        let link = try await fixture.evaluate("document.querySelector('#content a.wikilink')?.textContent ?? ''") as? String
        XCTAssertEqual(link, "Project Plan", "The inserted text renders as a wikilink")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Insert Link")

        fixture.type(" next")
        let typed = await waitUntil { fixture.store.documentText == "See [[Project Plan]] next\n" }
        XCTAssertTrue(typed, "The caret sits after the link, outside it: \(fixture.store.documentText)")

        undoManager.undo()
        let typingUndone = await waitUntil { fixture.store.documentText == "See [[Project Plan]]\n" }
        XCTAssertTrue(typingUndone, fixture.store.documentText)
        undoManager.undo()
        let linkUndone = await waitUntil { fixture.store.documentText == "See [[pro\n" }
        XCTAssertTrue(linkUndone, "One undo takes back the inserted link and restores the typed query: \(fixture.store.documentText)")
    }

    func testEscapeClosesTheNoteMenuAndKeepsTheTypedText() async throws {
        let fixture = try await makeFixture(markdown: "See\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(3)
        fixture.type(" [[Pro")
        _ = await fixture.wikilinkRows(matching: { !$0.isEmpty })

        fixture.press(.escape)
        let closed = await waitUntil {
            ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))")) as? Bool) == false
        }
        XCTAssertTrue(closed, "Esc closes the menu")
        XCTAssertEqual(fixture.store.documentText, "See [[Pro\n", "Esc keeps the typed text")

        fixture.type("x")
        let typed = await waitUntil { fixture.store.documentText == "See [[Prox\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        try await Task.sleep(nanoseconds: 200_000_000)
        let reopened = try await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))") as? Bool
        XCTAssertEqual(reopened, false, "Typing on after Esc does not bring the menu back")
    }

    func testDoubleBracketInsideInlineCodeStaysText() async throws {
        let fixture = try await makeFixture(markdown: "Use `code` here\n", notes: Self.wikilinkNotes)
        try await fixture.setSelection(7)
        fixture.type("[[")
        let typed = await waitUntil { fixture.store.documentText == "Use `co[[de` here\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        try await Task.sleep(nanoseconds: 200_000_000)
        let menuShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))") as? Bool
        XCTAssertEqual(menuShown, false, "Code keeps `[[` as typed")
    }

    // MARK: - Changes from outside the editor

    /// A change from outside reaches the page as a patch, not a reload, and is sent once however
    /// often SwiftUI updates before the page answers.
    func testAChangeFromOutsideReachesThePageOnceWithoutReloadingIt() async throws {
        let fixture = try await makeFixture(markdown: "Line one\n")
        _ = try await fixture.evaluate("window.__marker = 'same page'; true")
        fixture.store.setDocumentText("Line one\nLine two\n")
        for _ in 0..<5 {
            await Task.yield()
            fixture.harness.objectWillChange.send()
        }
        let synced = await waitUntil {
            ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == "Line one\nLine two\n"
        }
        XCTAssertTrue(synced)
        let marker = try await fixture.evaluate("window.__marker") as? String
        XCTAssertEqual(marker, "same page", "The page was patched, not reloaded")
        try await Task.sleep(nanoseconds: 300_000_000)
        let page = try await fixture.evaluate("window.MonknotEditor.source()") as? String
        XCTAssertEqual(page, "Line one\nLine two\n", "The insertion applied once")
        XCTAssertEqual(fixture.store.documentText, "Line one\nLine two\n")
    }

    /// The page types a character and reports it; before the report reaches the app, the store
    /// takes a change from outside and sends it. Both land once, in both places, and SwiftUI
    /// updating again before the page answers sends nothing twice.
    func testAChangeFromOutsideRacingATypedCharacterKeepsBoth() async throws {
        let fixture = try await makeFixture(markdown: "Hello\n")
        try await fixture.setSelection(5)
        fixture.webView.evaluateJavaScript(
            "document.getElementById('content').dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'X', bubbles: true, cancelable: true })); true",
            completionHandler: nil
        )
        fixture.store.setDocumentText("Intro\n\nHello\n")
        for _ in 0..<3 {
            await Task.yield()
            fixture.harness.objectWillChange.send()
        }
        let expected = "Intro\n\nHelloX\n"
        let synced = await waitUntil {
            guard fixture.store.documentText == expected else { return false }
            return ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == expected
        }
        XCTAssertTrue(synced, "store: \(fixture.store.documentText.debugDescription)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.store.documentText, expected)
        let page = try await fixture.evaluate("window.MonknotEditor.source()") as? String
        XCTAssertEqual(page, expected)
    }

    // MARK: - Performance

    /// Milliseconds a keystroke may take, measured on a Mac at a desk. A shared CI machine (GitHub
    /// sets `CI`) is several times slower and times in whole milliseconds, so there the budgets are
    /// four times larger: still far below what a whole-document re-render costs.
    private static func keystrokeBudget(_ milliseconds: Double) -> Double {
        ProcessInfo.processInfo.environment["CI"] == "true" ? milliseconds * 4 : milliseconds
    }

    /// A 1 MB document opens editable and a keystroke stays far under one frame.
    func testLargeDocumentKeystrokesStayUnderOneFrame() async throws {
        let section = """
        ## Section

        Paragraph with **bold**, *emphasis*, a [link](https://example.com) and `code`, wrapped
        over two source lines.

        - First item
        - Second item

        | A | B |
        | --- | --- |
        | 1 | 2 |


        """
        var markdown = ""
        while (markdown as NSString).length < 1_000_000 { markdown += section }
        let opened = Date()
        let fixture = try await makeFixture(markdown: markdown, timeout: 30)
        let openSeconds = Date().timeIntervalSince(opened)

        let target = (markdown as NSString).length / 2
        let insertion = (markdown as NSString).range(of: "wrapped", range: NSRange(location: target, length: 4000)).location
        try await fixture.setSelection(insertion)
        let timing = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          window.MonknotEditor.profile = [];
          const times = [];
          for (let i = 0; i < 40; i += 1) {
            const start = performance.now();
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'x', bubbles: true, cancelable: true }));
            times.push(performance.now() - start);
          }
          times.sort((a, b) => a - b);
          const profile = window.MonknotEditor.profile;
          window.MonknotEditor.profile = null;
          const sum = (key) => profile.reduce((total, entry) => total + entry[key], 0) / profile.length;
          return { median: times[20], p95: times[37], max: times[39], patch: sum('patch'), dom: sum('dom'), selection: sum('selection') };
        })()
        """) as? [String: Any]
        let median = try XCTUnwrap(timing?["median"] as? Double)
        let p95 = try XCTUnwrap(timing?["p95"] as? Double)
        print("Large document: opened editable in \(String(format: "%.2f", openSeconds)) s; keystroke median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms; mean patch \(timing?["patch"] ?? 0) dom \(timing?["dom"] ?? 0) selection \(timing?["selection"] ?? 0)")
        XCTAssertLessThan(p95, Self.keystrokeBudget(16), "A keystroke must render within one frame")
        // The document is ASCII, so its UTF-8 length counts characters without walking a megabyte.
        let stored = await waitUntil(timeout: 10) { fixture.store.documentText.utf8.count == markdown.utf8.count + 40 }
        XCTAssertTrue(stored, "Every keystroke reached the store")
    }

    /// A typical note: 50 KB, a keystroke well under a millisecond or two.
    func testTypicalDocumentKeystrokeCost() async throws {
        let paragraph = "A paragraph of ordinary notes with **bold** text and a [link](https://example.com).\n\n"
        var markdown = "# Notes\n\n"
        while (markdown as NSString).length < 50_000 { markdown += paragraph }
        let fixture = try await makeFixture(markdown: markdown)
        try await fixture.setSelection((markdown as NSString).length / 2 - ((markdown as NSString).length / 2) % (paragraph as NSString).length + 10)
        let timing = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const times = [];
          for (let i = 0; i < 40; i += 1) {
            const start = performance.now();
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'x', bubbles: true, cancelable: true }));
            times.push(performance.now() - start);
          }
          times.sort((a, b) => a - b);
          return { median: times[20], p95: times[37] };
        })()
        """) as? [String: Any]
        let median = try XCTUnwrap(timing?["median"] as? Double)
        let p95 = try XCTUnwrap(timing?["p95"] as? Double)
        print("Typical document: keystroke median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms")
        XCTAssertLessThan(p95, Self.keystrokeBudget(8))
    }

    /// A note with many footnotes: a keystroke in a paragraph without a reference costs what it
    /// costs in any note, and typing a reference still renumbers the notes.
    func testKeystrokeCostInANoteWithFootnotes() async throws {
        var markdown = "# Notes\n\n"
        for index in 1...150 {
            markdown += "Paragraph \(index) cites a source[^n\(index)] in passing.\n\nA plain paragraph with **bold** text and nothing to cite.\n\n"
        }
        for index in 1...150 { markdown += "[^n\(index)]: Source number \(index).\n\n" }
        let fixture = try await makeFixture(markdown: markdown)
        let plain = (markdown as NSString).range(of: "A plain paragraph", range: NSRange(location: (markdown as NSString).length / 3, length: 2000)).location
        try await fixture.setSelection(plain + 2)
        let timing = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const times = [];
          for (let i = 0; i < 40; i += 1) {
            const start = performance.now();
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'x', bubbles: true, cancelable: true }));
            times.push(performance.now() - start);
          }
          times.sort((a, b) => a - b);
          return { median: times[20], p95: times[37] };
        })()
        """) as? [String: Any]
        let median = try XCTUnwrap(timing?["median"] as? Double)
        let p95 = try XCTUnwrap(timing?["p95"] as? Double)
        print("Note with footnotes: keystroke median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms")
        XCTAssertLessThan(p95, Self.keystrokeBudget(8))

        try await fixture.setSelection(("# Notes\n\nParagraph" as NSString).length)
        _ = try await fixture.evaluate("document.getElementById('content').dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: '[^n150]', bubbles: true, cancelable: true })); true")
        let numbers = try await fixture.evaluate("""
        [...document.querySelectorAll('#content sup.footnote-ref a')].slice(0, 3).map(a => a.textContent).join(',') + '|' +
        document.querySelector('#content section.footnotes li')?.id
        """) as? String
        XCTAssertEqual(numbers, "1,2,3|fn-n150", "The new first reference is note 1 and the notes follow it")
    }

    /// A toggle holding 5,000 paragraphs: a keystroke in its body re-parses and redraws the paragraph
    /// it is in, as in a paragraph outside any toggle, instead of the whole toggle.
    func testKeystrokeCostInALongToggle() async throws {
        let paragraph = "Paragraph with **bold** text and a [link](https://example.com).\n\n"
        var markdown = "# Notes\n\n<details open>\n<summary>Archive</summary>\n\n"
        for index in 1...5000 { markdown += "Number \(index): \(paragraph)" }
        markdown += "</details>\n\nA plain paragraph after the toggle.\n"
        let fixture = try await makeFixture(markdown: markdown, timeout: 30)
        let source = markdown as NSString

        try await fixture.setSelection(source.range(of: "Number 2500: ").location + 3)
        let inside = try await measureKeystrokes(fixture)
        try await fixture.setSelection(source.range(of: "A plain paragraph").location + 2)
        let plain = try await measureKeystrokes(fixture)
        print("Long toggle: keystroke in the toggle median \(inside.median) ms, p95 \(inside.p95) ms (patch \(inside.patch), dom \(inside.dom)); in a plain paragraph median \(plain.median) ms, p95 \(plain.p95) ms")
        XCTAssertLessThan(inside.p95, Self.keystrokeBudget(8), "A keystroke in a long toggle costs what it does in a short note")
        XCTAssertLessThan(inside.median, plain.median * 3 + Self.keystrokeBudget(0.5), "A keystroke in the toggle costs about what one in a plain paragraph does")
        let stored = await waitUntil(timeout: 10) { fixture.store.documentText.utf8.count == markdown.utf8.count + 80 }
        XCTAssertTrue(stored, "Every keystroke reached the store")
    }

    /// A list of 5,000 items and a quote of 2,000 lines: a keystroke in an item or a quoted line
    /// re-parses only the items or blocks around it.
    func testKeystrokeCostInALongListAndALongQuote() async throws {
        var markdown = "# Notes\n\n"
        for index in 1...5000 {
            markdown += "- Item \(index) with **bold** text\n"
            if index % 10 == 0 { markdown += "  - A nested item under \(index)\n" }
        }
        markdown += "\n"
        for index in 1...2000 { markdown += "> Quoted line \(index) with *emphasis*.\n>\n" }
        markdown += "\nA plain paragraph after the quote.\n"
        let fixture = try await makeFixture(markdown: markdown, timeout: 30)
        let source = markdown as NSString

        try await fixture.setSelection(source.range(of: "Item 2500 ").location + 3)
        let item = try await measureKeystrokes(fixture)
        try await fixture.setSelection(source.range(of: "A nested item under 3000").location + 3)
        let nested = try await measureKeystrokes(fixture)
        try await fixture.setSelection(source.range(of: "Quoted line 1000 ").location + 3)
        let quote = try await measureKeystrokes(fixture)
        try await fixture.setSelection(source.range(of: "A plain paragraph").location + 2)
        let plain = try await measureKeystrokes(fixture)
        print("Long list: item median \(item.median) ms, p95 \(item.p95) ms (patch \(item.patch), dom \(item.dom), selection \(item.selection)); nested item median \(nested.median) ms, p95 \(nested.p95) ms; long quote median \(quote.median) ms, p95 \(quote.p95) ms; plain paragraph median \(plain.median) ms, p95 \(plain.p95) ms")
        for (name, timing) in [("an item", item), ("a nested item", nested), ("a quote", quote)] {
            XCTAssertLessThan(timing.p95, Self.keystrokeBudget(8), "A keystroke in \(name) of a long container costs what it does in a short note")
            XCTAssertLessThan(timing.median, plain.median * 3 + Self.keystrokeBudget(0.5), "A keystroke in \(name) costs about what one in a plain paragraph does")
        }
        let stored = await waitUntil(timeout: 10) { fixture.store.documentText.utf8.count == markdown.utf8.count + 160 }
        XCTAssertTrue(stored, "Every keystroke reached the store")
    }

    /// Typing inside a toggle, list item or quote replaces only the element of the text it changed:
    /// the container, the blocks and items beside it, and the item's own <li> stay the same elements.
    func testAnEditInsideAContainerReplacesOnlyWhatItChanged() async throws {
        let markdown = """
        <details open>
        <summary>Toggle</summary>

        First in the toggle.

        Second in the toggle.

        - Listed in the toggle
        - Also listed

        Third in the toggle.

        </details>

        - One
        - Two
          - Under two
        - Three

        > Quoted first.
        >
        > Quoted second.

        """
        let fixture = try await makeFixture(markdown: markdown)
        _ = try await fixture.evaluate("""
        (() => {
          window.__tagged = [...document.querySelectorAll('#content [data-mk-u], #content p, #content li, #content ul, #content blockquote, #content .mk-toggle')];
          window.__tagged.forEach((element, index) => { element.__mkTag = index; });
          return true;
        })()
        """)
        for needle in ["Second in the toggle", "Also listed", "Under two", "Quoted second"] {
            let current = fixture.store.documentText as NSString
            try await fixture.setSelection(current.range(of: needle).location + 3)
            fixture.type("x")
            let replaced = try await fixture.evaluate("""
            (() => {
              const replaced = window.__tagged.filter((element) => !element.isConnected).map((element) => element.textContent.trim());
              window.__tagged = window.__tagged.filter((element) => element.isConnected);
              return replaced;
            })()
            """) as? [String]
            // The item under "Two" goes alone: "Two" and its list stay.
            XCTAssertEqual(replaced?.count, 1, "Typing in \(needle) replaced only its own element: \(replaced ?? [])")
            XCTAssertTrue(replaced?.first?.hasPrefix(needle) == true, "Typing in \(needle) replaced only its own element: \(replaced ?? [])")
        }
        let edited = await waitUntil { fixture.store.documentText.contains("Quoxted second") }
        XCTAssertTrue(edited, "Every keystroke reached the store")
        for changed in ["Secxond in the toggle.", "Alsxo listed", "Undxer two"] {
            XCTAssertTrue(fixture.store.documentText.contains(changed), "The store has \(changed)")
        }
    }

    /// Deleting the last reference to a note from a list item takes the note off the list under the
    /// document, though the item keeps its <li> and only what it holds is replaced.
    func testDeletingTheLastReferenceInAListItemTakesItsNoteAway() async throws {
        let markdown = "- a [^n]\n  - b\n\n[^n]: note\n"
        let fixture = try await makeFixture(markdown: markdown)
        let notes = "document.querySelectorAll('#content section.footnotes li').length"
        let before = try await fixture.evaluate(notes) as? Int
        XCTAssertEqual(before, 1)

        try await fixture.setSelection((markdown as NSString).range(of: "b\n").location + 1)
        fixture.type("x")
        let reference = (markdown as NSString).range(of: "[^n]")
        try await fixture.setSelection(reference.location, reference.location + reference.length)
        fixture.press(.backspace)
        let edited = await waitUntil { fixture.store.documentText == "- a \n  - bx\n\n[^n]: note\n" }
        XCTAssertTrue(edited, "The reference went: \(fixture.store.documentText.debugDescription)")
        let after = try await fixture.evaluate(notes) as? Int
        XCTAssertEqual(after, 0, "No note is listed once nothing refers to it")
    }

    /// Random typing, returns and deletions inside toggles, lists, quotes and callouts: after each
    /// one the page is what a fresh render of the new Markdown draws.
    func testEditsInsideContainersLeaveThePageAsAFreshRenderDrawsIt() async throws {
        let markdown = """
        # Title

        <details open>
        <summary>Toggle</summary>

        A paragraph in the toggle with **bold** and a note.[^a]

        - An item
        - [ ] A task
          - Nested under the task

        > A quote in the toggle.

        </details>

        - Top item one
        - Top item two[^b]
          wrapped onto a second line
          1. Numbered under two
          2. Numbered again
        - Top item three

        > [!NOTE]
        > A callout's text.
        >
        > - A list in the callout

        > A plain quote,[^a]
        > on two lines.
        >
        > <details>
        > <summary>Nested toggle</summary>
        >
        > Inside the nested toggle.
        >
        > </details>

        Closing paragraph.

        [^a]: The first note.

        [^b]: The second note.

        """
        let fixture = try await makeFixture(markdown: markdown)
        let result = try await fixture.evaluate(Self.containerEditFuzz) as? String
        XCTAssertEqual(result, "ok")
        let synced = await waitUntil(timeout: 10) {
            ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == fixture.store.documentText
        }
        XCTAssertTrue(synced, "The store has every edit the page made")
    }

    private struct KeystrokeTiming {
        let median: Double
        let p95: Double
        let patch: Double
        let dom: Double
        let selection: Double
    }

    /// 40 typed characters at the caret, each timed from `beforeinput` to the page drawn.
    private func measureKeystrokes(_ fixture: Fixture) async throws -> KeystrokeTiming {
        let timing = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          window.MonknotEditor.profile = [];
          const times = [];
          for (let i = 0; i < 40; i += 1) {
            const start = performance.now();
            root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'x', bubbles: true, cancelable: true }));
            times.push(performance.now() - start);
          }
          times.sort((a, b) => a - b);
          const profile = window.MonknotEditor.profile;
          window.MonknotEditor.profile = null;
          const mean = (key) => profile.reduce((total, entry) => total + entry[key], 0) / Math.max(1, profile.length);
          return { median: times[20], p95: times[37], patch: mean('patch'), dom: mean('dom'), selection: mean('selection') };
        })()
        """) as? [String: Any]
        let round = { (value: Double) in (value * 1000).rounded() / 1000 }
        return KeystrokeTiming(
            median: round(try XCTUnwrap(timing?["median"] as? Double)),
            p95: round(try XCTUnwrap(timing?["p95"] as? Double)),
            patch: round(timing?["patch"] as? Double ?? 0),
            dom: round(timing?["dom"] as? Double ?? 0),
            selection: round(timing?["selection"] as? Double ?? 0)
        )
    }

    /// Edits at random places, through the page's own input handling; after each the page's markup,
    /// read as a tree of elements, must be a fresh render's, aside from unit ids, toggles' open state
    /// and the page's own marks (the current line, an empty document). The notes under the document
    /// must be a read-only render's, and the line the page maps each top-level block to a fresh
    /// render's: the page reads lines from the model, not from the elements' `data-source-line`,
    /// which blocks after an edit keep as they were.
    private static let containerEditFuzz = #"""
    (() => {
      const root = document.getElementById('content');
      const E = window.MonknotEditorCore;
      let seed = 4242;
      const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
      const canonical = (container) => {
        const ids = new Map();
        const out = [];
        const walk = (node) => {
          if (node.nodeType === 3) {
            if (node.nodeValue.trim()) out.push(JSON.stringify(node.nodeValue));
            return;
          }
          if (node.nodeType !== 1) return;
          if (node.classList.contains("footnotes")) return;
          const attributes = [];
          for (const attribute of [...node.attributes].sort((a, b) => a.name.localeCompare(b.name))) {
            const name = attribute.name;
            if (name === "data-source-line" || name === "data-open" || name === "aria-expanded" || name === "contenteditable" && node === root) continue;
            if (name === "aria-label" && /^(Collapse|Expand)$/.test(attribute.value)) continue;
            let value = attribute.value;
            if (name === "data-mk-u") {
              if (!ids.has(value)) ids.set(value, ids.size);
              value = String(ids.get(value));
            }
            if (name === "class") value = value.split(/\s+/).filter((name) => name && !/^mk-(current|only|block-moved)$/.test(name)).join(" ");
            if (name === "class" && !value) continue;
            attributes.push(name + "=" + value);
          }
          out.push("<" + node.tagName + " " + attributes.join(" ") + ">");
          for (const child of node.childNodes) walk(child);
          out.push("</" + node.tagName + ">");
        };
        for (const child of container.childNodes) walk(child);
        return out.join("");
      };
      const fresh = (source) => {
        const template = document.createElement("template");
        template.innerHTML = E.createModel(source).blocks.map((block) => block.html).join("");
        return canonical(template.content);
      };
      const typed = ["x", "x", "ab", " ", "*", "-", ">", "`"];
      let inside = 0;
      const steps = 300;
      for (let step = 0; step < steps; step += 1) {
        const source = window.MonknotEditor.source();
        const position = Math.floor(random() * (source.length + 1));
        window.MonknotEditor.setSelection(position, position);
        const caret = window.getSelection().anchorNode;
        const element = caret && (caret.nodeType === 1 ? caret : caret.parentElement);
        if (element && element.closest("#content li, #content blockquote, #content .callout, #content .mk-toggle-body")) inside += 1;
        const roll = random();
        let event;
        if (roll < 0.6) event = new InputEvent("beforeinput", { inputType: "insertText", data: typed[Math.floor(random() * typed.length)], bubbles: true, cancelable: true });
        else if (roll < 0.75) event = new InputEvent("beforeinput", { inputType: "insertParagraph", bubbles: true, cancelable: true });
        else event = new InputEvent("beforeinput", { inputType: "deleteContentBackward", bubbles: true, cancelable: true });
        root.dispatchEvent(event);
        const after = window.MonknotEditor.source();
        const page = canonical(root);
        const expected = fresh(after);
        if (page !== expected) {
          let index = 0;
          while (index < page.length && page[index] === expected[index]) index += 1;
          return "step " + step + " (" + event.inputType + " at " + position + ") in " + JSON.stringify(after) + ": page " + page.slice(Math.max(0, index - 120), index + 160) + " | fresh " + expected.slice(Math.max(0, index - 120), index + 160);
        }
        const ids = [...root.querySelectorAll("[data-mk-u]")].map((element) => element.getAttribute("data-mk-u"));
        if (new Set(ids).size !== ids.length) return "step " + step + ": a unit id is on the page twice";
        const notesTemplate = document.createElement("template");
        notesTemplate.innerHTML = window.MonknotMarkdown.renderMarkdown(after);
        const notes = (section) => (section ? canonical(section) : "none");
        const pageNotes = notes(root.querySelector(":scope > section.footnotes"));
        const freshNotes = notes(notesTemplate.content.querySelector("section.footnotes"));
        if (pageNotes !== freshNotes) return "step " + step + " (" + event.inputType + " at " + position + ") notes in " + JSON.stringify(after) + ": page " + pageNotes + " | fresh " + freshNotes;
        const lineTemplate = document.createElement("template");
        lineTemplate.innerHTML = E.createModel(after).blocks.map((block) => block.html).join("");
        const drawn = (container) => [...container.children].filter((element) => !element.classList.contains("mk-empty") && !element.classList.contains("footnotes"));
        const mapped = window.MonknotEditor.sourceLineElements();
        const lines = mapped.map((entry) => entry.line).join(",");
        const freshLines = drawn(lineTemplate.content).map((element) => element.getAttribute("data-source-line")).join(",");
        if (lines !== freshLines) return "step " + step + " (" + event.inputType + " at " + position + ") lines in " + JSON.stringify(after) + ": page " + lines + " | fresh " + freshLines;
        const elements = drawn(root);
        if (mapped.length !== elements.length || mapped.some((entry, index) => entry.element !== elements[index])) return "step " + step + ": the line map's elements are not the page's blocks";
      }
      return inside > steps / 3 ? "ok" : "only " + inside + " of " + steps + " edits were inside a container";
    })()
    """#

    // MARK: - Clicks below the text

    /// A click below the last block is no edit: the file stays clean and there is nothing to undo.
    /// After text, typing continues it.
    func testAClickBelowTheTextChangesNothingAndTypingContinuesIt() async throws {
        let fixture = try await makeFixture(markdown: "Hello\n")
        try await fixture.clickBelowTheLastBlock()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, "Hello\n")
        XCTAssertFalse(fixture.store.hasUnsavedChanges, "A click does not make the document dirty")
        XCTAssertEqual(fixture.webView.undoManager?.canUndo, false)

        fixture.type("!")
        let typed = await waitUntil { fixture.store.documentText == "Hello!\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
    }

    /// After a table, which typing cannot continue, the first character typed opens a line below
    /// it, and one undo takes both back.
    func testTypingAfterAClickBelowATableOpensALineAfterIt() async throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.clickBelowTheLastBlock()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, source)
        XCTAssertFalse(fixture.store.hasUnsavedChanges)

        fixture.type("xy")
        let typed = await waitUntil { fixture.store.documentText == source + "\nxy\n" }
        XCTAssertTrue(typed, fixture.store.documentText.debugDescription)
        let page = try await fixture.evaluate("[...document.querySelectorAll('#content > *')].map(e => e.tagName + ':' + e.textContent.trim()).pop()") as? String
        XCTAssertEqual(page, "P:xy")
        fixture.webView.undoManager?.undo()
        let undone = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(undone, "The line and the typing are one step: \(fixture.store.documentText.debugDescription)")
    }

    // MARK: - Input methods and substitutions

    /// Korean starts the next syllable's composition as soon as one ends. Driven through the web
    /// view's own marked-text calls, each syllable must land once.
    func testACompositionThatStartsRightAfterAnotherTypesEachSyllableOnce() async throws {
        let fixture = try await makeFixture(markdown: "A\n")
        try await fixture.setSelection(1)
        let client = try XCTUnwrap(fixture.webView as? NSTextInputClient, "WKWebView takes marked text as an NSTextInputClient")
        let none = NSRange(location: NSNotFound, length: 0)
        client.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        client.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        client.insertText("하", replacementRange: none)
        client.setMarkedText("ㄴ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        client.setMarkedText("나", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        client.insertText("나", replacementRange: none)
        let typed = await waitUntil { fixture.store.documentText == "A하나\n" }
        XCTAssertTrue(typed, fixture.store.documentText.debugDescription)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, "A하나\n")
        let page = try await fixture.evaluate("window.MonknotEditor.source()") as? String
        XCTAssertEqual(page, "A하나\n")
    }

    /// The page's own reconcile after a composition ends waits while the next one is open, so
    /// nothing of a syllable still being composed reaches the file.
    func testNothingReachesTheFileWhileTheNextCompositionIsOpen() async throws {
        let fixture = try await makeFixture(markdown: "A\n")
        try await fixture.setSelection(1)
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const text = root.querySelector('p').firstChild;
          root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
          text.data = 'A하';
          root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '하' }));
          root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
          text.data = 'A하ㄴ';
          return true;
        })()
        """)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, "A\n", "The marked ㄴ is not written while it is composed")
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          root.querySelector('p').firstChild.data = 'A하나';
          root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '나' }));
          return true;
        })()
        """)
        let typed = await waitUntil { fixture.store.documentText == "A하나\n" }
        XCTAssertTrue(typed, fixture.store.documentText.debugDescription)
    }

    /// Tab while an input method has marked text belongs to the input method, not to the list.
    func testTabDuringACompositionLeavesTheListAlone() async throws {
        let fixture = try await makeFixture(markdown: "- One\n- Two\n")
        try await fixture.setSelection(("- One\n- Two" as NSString).length)
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          root.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
          const event = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
          root.dispatchEvent(event);
          root.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }));
          return event.defaultPrevented;
        })()
        """)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, "- One\n- Two\n", "The item was not indented")
    }

    /// macOS turns "--" into a dash by replacing the two hyphens; in code they stay as typed.
    func testSmartDashInCodeKeepsTheHyphens() async throws {
        let source = "Run `cmd --` now\n"
        let fixture = try await makeFixture(markdown: source)
        let dashes = (source as NSString).range(of: "--")
        try await fixture.setSelection(NSMaxRange(dashes))
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const code = root.querySelector('code');
          const text = code.firstChild;
          const at = text.data.indexOf('--');
          const range = new StaticRange({ startContainer: text, startOffset: at, endContainer: text, endOffset: at + 2 });
          root.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertReplacementText', data: '\\u2014', targetRanges: [range], bubbles: true, cancelable: true }));
          return true;
        })()
        """)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.store.documentText, source, "Code keeps the two hyphens")
        XCTAssertFalse(fixture.store.hasUnsavedChanges)
    }

    // MARK: - Dropped files

    /// Files dropped on the page go through the same import as Source's drop, linked where they
    /// were dropped.
    func testFilesDroppedOnThePageGoThroughTheImport() async throws {
        let fixture = try await makeFixture(markdown: "Before after\n")
        let file = fixture.store.workspaceURL!.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let drag = NSPasteboard(name: .drag)
        drag.clearContents()
        drag.writeObjects([file as NSURL])
        _ = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const text = root.querySelector('p').firstChild;
          const range = document.createRange();
          range.setStart(text, 6);
          const box = range.getBoundingClientRect();
          const data = new DataTransfer();
          data.items.add(new File([new Uint8Array([1])], 'photo.png', { type: 'image/png' }));
          root.dispatchEvent(new DragEvent('drop', { dataTransfer: data, clientX: box.left + 1, clientY: box.top + box.height / 2, bubbles: true, cancelable: true }));
          return true;
        })()
        """)
        let requested = await waitUntil { !fixture.harness.fileDropRequests.isEmpty }
        XCTAssertTrue(requested, "The drop reached the import")
        let request = try XCTUnwrap(fixture.harness.fileDropRequests.first)
        XCTAssertEqual(request.urls.map(\.standardizedFileURL), [file.standardizedFileURL])
        XCTAssertEqual(request.insertionRange, NSRange(location: 6, length: 0))
        XCTAssertTrue(request.insertMarkdown("![photo](photo.png)"))
        let inserted = await waitUntil { fixture.store.documentText == "Before![photo](photo.png) after\n" }
        XCTAssertTrue(inserted, fixture.store.documentText)
    }

    // MARK: - Snapshots for design review

    // MARK: - Icons

    /// A selection the app sets (a restored caret, a revealed search match) is not a gesture: the format
    /// bar stays hidden until the person selects something themselves.
    func testFormatBarWaitsForThePersonsOwnSelection() async throws {
        let markdown = "A paragraph with plain words to select.\n"
        let fixture = try await makeFixture(markdown: markdown)
        _ = try await fixture.evaluate("(() => { const s = document.createElement('style'); s.textContent = '.mk-floating { transition: none !important; }'; document.head.appendChild(s); return true; })()")
        let plain = (markdown as NSString).range(of: "plain").location
        try await fixture.setSelection(plain, plain + 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        let shownForHost = try await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible'))") as? Bool
        XCTAssertEqual(shownForHost, false, "The app's selection shows no format bar")

        _ = try await fixture.evaluate("document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
        try await Task.sleep(nanoseconds: 300_000_000)
        let shownForPerson = try await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible'))") as? Bool
        XCTAssertEqual(shownForPerson, true, "Selecting with the mouse shows it")
    }

    /// A document reopens with the selection it was left with, and restoring it is no gesture either:
    /// the format bar stays hidden until the person selects something.
    func testARestoredSelectionComesBackWithoutTheFormatBar() async throws {
        let markdown = "A paragraph with plain words to select.\n"
        let plain = (markdown as NSString).range(of: "plain")
        let fixture = try await makeFixture(
            markdown: markdown,
            viewportState: DocumentViewportState(textSelection: DocumentTextSelection(location: plain.location, length: plain.length))
        )
        _ = try await fixture.evaluate("(() => { const s = document.createElement('style'); s.textContent = '.mk-floating { transition: none !important; }'; document.head.appendChild(s); return true; })()")
        try await Task.sleep(nanoseconds: 300_000_000)

        let selection = try await fixture.evaluate("JSON.stringify(window.MonknotEditor.selection())") as? String
        XCTAssertTrue(selection?.contains("\(plain.location)") == true, "The selection comes back: \(selection ?? "none")")
        let shown = try await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible'))") as? Bool
        XCTAssertEqual(shown, false, "A restored selection shows no format bar")
    }

    /// The format bar's and link card's buttons are built once; when the page builds them before
    /// the app's glyphs arrive they must fill in then, not stay solid squares.
    func testGlyphsThatArriveAfterTheBarsAreBuiltStillDraw() async throws {
        let fixture = try await makeFixture(markdown: "Make this strong\n")
        try await fixture.setSelection(10, 16)
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup')); true")
        try await Task.sleep(nanoseconds: 300_000_000)
        let drawn = try await fixture.evaluate("[...document.querySelectorAll('.mk-layer .mk-icon')].filter(s => !s.style.webkitMaskImage).length") as? Int
        XCTAssertEqual(drawn, 0, "Every built glyph has its image")

        let result = try await fixture.evaluate("""
        (() => {
          const spans = [...document.querySelectorAll('.mk-layer .mk-icon')];
          const map = {};
          for (const span of spans) map[span.dataset.mkIcon] = { url: 'data:image/png;base64,iVBORw0KGgo=', width: 10, height: 10 };
          window.MonknotEditor.setIcons({});
          spans.forEach(span => { span.style.webkitMaskImage = ''; span.style.maskImage = ''; });
          window.MonknotEditor.setIcons({});
          const pending = spans.filter(span => span.classList.contains('mk-icon-pending')).length;
          window.MonknotEditor.setIcons(map);
          const filled = spans.filter(span => span.style.webkitMaskImage.includes('data:image/png') && !span.classList.contains('mk-icon-pending')).length;
          return [spans.length, pending, filled];
        })()
        """) as? [Int]
        let counts = try XCTUnwrap(result)
        XCTAssertGreaterThan(counts[0], 5, "The format bar's buttons exist")
        XCTAssertEqual(counts[1], counts[0], "Without glyphs a span draws nothing")
        XCTAssertEqual(counts[2], counts[0], "Glyphs that arrive later fill every built span")
    }

    // MARK: - Spaces

    /// A space is a character like any other: typed at the end of a line (where WebKit draws a
    /// collapsed space at the caret), twice in a row, inside a word and in every kind of block, with
    /// a pause after it as a person types, the space must land in the file where it was typed and the
    /// next word must follow it. Paragraphs, headings, list items, table cells and toggle titles are
    /// typed into the same way by the next test, and words in a row by the one after.
    func testSpacesTypeWhereTheyAreTypedInEveryBlock() async throws {
        // One note holds every case, each by a word found nowhere else, so one page serves them all.
        let cases: [(name: String, block: String, caretAfter: String, typed: String, expected: String)] = [
            ("double space", "Charlie", "Charlie", "  x", "Charlie  x"),
            ("mid word", "Deltaworld", "Delta", " ", "Delta world"),
            // Typing at the end of bold continues it, spaces included (design.md §10.10).
            ("after bold", "**Bold**", "Bold", " x", "**Bold x**"),
            ("task item", "- [ ] task", "task", " x", "- [ ] task x"),
            ("numbered item", "1. one", "one", " x", "1. one x"),
            ("quote", "> quote", "quote", " x", "> quote x"),
            ("callout", "> [!NOTE]\n> note", "note", " x", "> [!NOTE]\n> note x"),
            ("toggle body", "<details open>\n<summary>Toggle</summary>\n\nInside\n\n</details>", "Inside", " x", "\n\nInside x\n\n"),
            ("code block", "```\nlet z\n```", "let z", " = 1", "```\nlet z = 1\n```"),
            ("before link", "see [link](u)", "see", " the", "see the [link](u)"),
        ]
        // A paragraph between blocks keeps the lists, the quote and the callout apart.
        let markdown = cases.map(\.block).joined(separator: "\n\nSep\n\n") + "\n"
        let fixture = try await makeFixture(markdown: markdown)
        for testCase in cases {
            let text = fixture.store.documentText as NSString
            try await fixture.setSelection(NSMaxRange(text.range(of: testCase.caretAfter)))
            for character in testCase.typed {
                fixture.type(String(character))
                if character == " " { try await Task.sleep(nanoseconds: 120_000_000) }
            }
            let typed = await waitUntil(timeout: 2) { fixture.store.documentText.contains(testCase.expected) }
            XCTAssertTrue(typed, "\(testCase.name): \(fixture.store.documentText.debugDescription)")
        }
    }

    /// A space typed at the end of a line is drawn at once: the caret moves past it before the next
    /// word is typed, in a paragraph, a heading, a list item, a table cell and a toggle title.
    func testASpaceAtTheEndOfALineMovesTheCaretRightAway() async throws {
        let source = "Hello\n\n# Title\n\n- item\n\n| a | b |\n| --- | --- |\n| cell | x |\n\n<details open>\n<summary>Toggle</summary>\n\nBody\n\n</details>\n"
        let fixture = try await makeFixture(markdown: source)
        let caretLeft = "(() => { const r = window.getSelection().getRangeAt(0).cloneRange(); r.collapse(true); const box = r.getClientRects()[0] || r.getBoundingClientRect(); return box.left; })()"
        for word in ["Hello", "Title", "item", "cell", "Toggle"] {
            let text = fixture.store.documentText as NSString
            let caret = text.range(of: word).location + (word as NSString).length
            try await fixture.setSelection(caret)
            let before = try await fixture.evaluate(caretLeft) as? Double ?? 0
            fixture.type(" ")
            try await Task.sleep(nanoseconds: 150_000_000)
            let after = try await fixture.evaluate(caretLeft) as? Double ?? 0
            XCTAssertGreaterThan(after - before, 2, "\(word): the caret moves past the space it just typed")
            fixture.type("x")
            let typed = await waitUntil(timeout: 2) { fixture.store.documentText.contains("\(word) x") }
            XCTAssertTrue(typed, "\(word): \(fixture.store.documentText.debugDescription)")
        }
    }

    /// A new line typed as words with spaces between them, as a person writes a sentence.
    func testTypingASentenceOnANewLineKeepsEverySpace() async throws {
        let fixture = try await makeFixture(markdown: "Intro\n")
        try await fixture.setSelection(5)
        fixture.press(.return)
        for character in "The quick brown fox " {
            fixture.type(String(character))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        fixture.type("j")
        let typed = await waitUntil(timeout: 2) { fixture.store.documentText == "Intro\n\nThe quick brown fox j\n" }
        XCTAssertTrue(typed, fixture.store.documentText.debugDescription)
        let visible = try await fixture.evaluate("[...document.querySelectorAll('#content > p')].pop().textContent") as? String
        XCTAssertEqual(visible, "The quick brown fox j")
    }

    // MARK: - Blocks, menus and handles

    func testSlashOpensTheBlockMenuOnlyAtTheStartOfABlock() async throws {
        let fixture = try await makeFixture(markdown: "Hello world\n\n| A | B |\n| --- | --- |\n| x | y |\n")
        try await fixture.setSelection(11)
        fixture.type("/")
        try await Task.sleep(nanoseconds: 200_000_000)
        let midSentence = try await fixture.evaluate(Self.slashMenuShown) as? Bool
        XCTAssertEqual(midSentence, false, "A / typed after text is just a slash")
        fixture.press(.backspace)

        let cell = (fixture.store.documentText as NSString).range(of: "x").location + 1
        try await fixture.setSelection(cell)
        fixture.type("/")
        try await Task.sleep(nanoseconds: 200_000_000)
        let inCell = try await fixture.evaluate(Self.slashMenuShown) as? Bool
        XCTAssertEqual(inCell, false, "A table cell takes a / as text")
        fixture.press(.backspace)

        try await fixture.setSelection(11)
        fixture.press(.return)
        fixture.type("/")
        let opened = await waitUntil { ((try? await fixture.evaluate(Self.slashMenuShown)) as? Bool) == true }
        XCTAssertTrue(opened, "A / on an empty line opens the block menu")
        let groups = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-group')].map(e => e.textContent).join(',')") as? String
        XCTAssertEqual(groups, "Basic blocks,Media,Advanced blocks,Inline", "Notion's sections, in sentence case")
    }

    func testToggleListTakesItsTitleAndBodyFromTheKeyboard() async throws {
        let fixture = try await makeFixture(markdown: "Intro\n")
        try await fixture.setSelection(5)
        fixture.press(.return)
        fixture.type("/togg")
        fixture.press(.return)
        fixture.type("Details")
        fixture.press(.return)
        fixture.type("Hidden")
        let expected = "Intro\n\n<details>\n<summary>Details</summary>\n\nHidden\n\n</details>\n"
        let built = await waitUntil { fixture.store.documentText == expected }
        XCTAssertTrue(built, fixture.store.documentText)

        _ = try await fixture.evaluate("document.querySelector('.mk-toggle-arrow').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
        let closed = try await fixture.evaluate("document.querySelector('.mk-toggle').dataset.open") as? String
        XCTAssertEqual(closed, "false", "The arrow closes the toggle on the page")
        XCTAssertEqual(fixture.store.documentText, expected, "Opening and closing never edits the file")
        let caret = try await fixture.evaluate("window.MonknotEditor.selection().head") as? Int
        XCTAssertEqual(caret, (expected as NSString).range(of: "Details").location + 7, "A caret in the hidden body moves to the title")
    }

    func testCalloutFromTheSlashMenuChangesKindFromItsTitle() async throws {
        let fixture = try await makeFixture(markdown: "Intro\n")
        try await fixture.setSelection(5)
        fixture.press(.return)
        fixture.type("/callo")
        fixture.press(.return)
        fixture.type("Back up first")
        let made = await waitUntil { fixture.store.documentText == "Intro\n\n> [!NOTE]\n> Back up first\n" }
        XCTAssertTrue(made, fixture.store.documentText)

        _ = try await fixture.evaluate("document.querySelector('.callout-title').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
        let rows = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-row-label')].map(e => e.textContent).join(',')") as? String
        XCTAssertEqual(rows, "Note,Tip,Important,Warning,Caution")
        _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Warning')).click(); true")
        let changed = await waitUntil { fixture.store.documentText == "Intro\n\n> [!WARNING]\n> Back up first\n" }
        XCTAssertTrue(changed, fixture.store.documentText)
    }

    func testPlusAddsABlockBelowWithTheSlashMenuOpenAndEscapeLeavesAnEmptyLine() async throws {
        let fixture = try await makeFixture(markdown: "First\n\nSecond\n")
        try await fixture.hoverBlock(containing: "First")
        _ = try await fixture.evaluate("document.querySelector('.mk-handle-add').click(); true")
        let opened = await waitUntil { ((try? await fixture.evaluate(Self.slashMenuShown)) as? Bool) == true }
        XCTAssertTrue(opened, "+ opens the block menu on a new line")
        XCTAssertEqual(fixture.store.documentText, "First\n\n/\n\nSecond\n")
        fixture.press(.escape)
        let cleared = await waitUntil { fixture.store.documentText == "First\n\n\nSecond\n" }
        XCTAssertTrue(cleared, "Esc takes the / back out: \(fixture.store.documentText.debugDescription)")
    }

    func testDraggingAGripMovesTheBlockAsOneUndoableStep() async throws {
        let source = "Alpha\n\nBeta\n\nGamma\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.hoverBlock(containing: "Alpha")
        _ = try await fixture.evaluate("""
        (() => {
          const grip = document.querySelector('.mk-handle-drag').getBoundingClientRect();
          const target = [...document.querySelectorAll('#content > p')].find(p => p.textContent === 'Gamma').getBoundingClientRect();
          const at = (type, x, y, element) => (element || document).dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 }));
          at('mousedown', grip.left + 4, grip.top + 4, document.querySelector('.mk-handle-drag'));
          at('mousemove', grip.left + 20, grip.top + 30);
          at('mousemove', grip.left + 40, target.bottom + 6);
          return Boolean(document.querySelector('.mk-drop-line.mk-visible'));
        })()
        """)
        let lineShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-drop-line.mk-visible'))") as? Bool
        XCTAssertEqual(lineShown, true, "A line shows where the block will land")
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 })); true")
        let moved = await waitUntil { fixture.store.documentText == "Beta\n\nGamma\n\nAlpha\n" }
        XCTAssertTrue(moved, fixture.store.documentText)

        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Move")
        undoManager.undo()
        let restored = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(restored, fixture.store.documentText)
    }

    func testBlockMenuAndShortcutsDuplicateMoveTurnIntoAndDelete() async throws {
        let fixture = try await makeFixture(markdown: "One\n\nTwo\n")
        try await fixture.setSelection(1)
        fixture.press(.character("d"), modifiers: .command)
        let duplicated = await waitUntil { fixture.store.documentText == "One\n\nOne\n\nTwo\n" }
        XCTAssertTrue(duplicated, fixture.store.documentText)

        fixture.press(.down, modifiers: [.command, .shift])
        let movedDown = await waitUntil { fixture.store.documentText == "One\n\nTwo\n\nOne\n" }
        XCTAssertTrue(movedDown, fixture.store.documentText)

        try await fixture.hoverBlock(containing: "Two")
        _ = try await fixture.evaluate("""
        (() => {
          const grip = document.querySelector('.mk-handle-drag');
          const box = grip.getBoundingClientRect();
          grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: box.left + 4, clientY: box.top + 4, button: 0 }));
          document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, clientX: box.left + 4, clientY: box.top + 4, button: 0 }));
          return true;
        })()
        """)
        let labels = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-row-label')].map(e => e.textContent).join(',')") as? String
        XCTAssertEqual(labels, "Turn into,Align,Duplicate,Copy,Move up,Move down,Delete")
        let picked = try await fixture.evaluate("document.querySelector('.mk-block-picked')?.textContent ?? ''") as? String
        XCTAssertEqual(picked, "Two", "The block the menu acts on stays tinted")

        _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Turn into')).click(); true")
        let submenu = await waitUntil { ((try? await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible')].length")) as? Int) == 2 }
        XCTAssertTrue(submenu, "Turn into opens beside the menu")
        _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.trim().startsWith('H1')).click(); true")
        let heading = await waitUntil { fixture.store.documentText == "One\n\n# Two\n\nOne\n" }
        XCTAssertTrue(heading, fixture.store.documentText)

        try await fixture.hoverBlock(containing: "Two")
        _ = try await fixture.evaluate("""
        (() => {
          const grip = document.querySelector('.mk-handle-drag');
          grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
          document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 }));
          [...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Delete')).click();
          return true;
        })()
        """)
        let deleted = await waitUntil { fixture.store.documentText == "One\n\nOne\n" }
        XCTAssertTrue(deleted, fixture.store.documentText)
    }

    // MARK: - Alignment and media size

    /// ⇧⌘E, ⇧⌘R and ⇧⌘L wrap the caret's block in `<div align>`, change it and take it away, each one
    /// undo step; the caret stays in the text, and taking the alignment away gives back the file.
    func testAlignmentKeysWrapTheBlockAsOneUndoStepEach() async throws {
        let source = "Intro\n\nTitle\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection((source as NSString).range(of: "Title").location + 2)
        fixture.press(.character("e"), modifiers: [.command, .shift])
        let centered = "Intro\n\n<div align=\"center\">\n\nTitle\n\n</div>\n"
        let wrapped = await waitUntil { fixture.store.documentText == centered }
        XCTAssertTrue(wrapped, fixture.store.documentText)
        let alignment = try await fixture.evaluate("getComputedStyle([...document.querySelectorAll('#content p')].find(p => p.textContent === 'Title')).textAlign") as? String
        XCTAssertEqual(alignment, "-webkit-center", "The page draws the div as GitHub does")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Center")

        fixture.press(.character("r"), modifiers: [.command, .shift])
        let right = "Intro\n\n<div align=\"right\">\n\nTitle\n\n</div>\n"
        let moved = await waitUntil { fixture.store.documentText == right }
        XCTAssertTrue(moved, fixture.store.documentText)
        XCTAssertEqual(undoManager.undoActionName, "Align Right")
        fixture.press(.character("l"), modifiers: [.command, .shift])
        let back = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(back, "Left takes the div away: \(fixture.store.documentText)")

        fixture.type("!")
        let typed = await waitUntil { fixture.store.documentText == "Intro\n\nTi!tle\n" }
        XCTAssertTrue(typed, "The caret stayed where it was: \(fixture.store.documentText)")
        undoManager.undo()
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == right }
        XCTAssertTrue(undone, "One undo for each alignment: \(fixture.store.documentText)")
        undoManager.undo()
        undoManager.undo()
        let original = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(original, fixture.store.documentText)
    }

    /// The format bar's alignment button and the block menu's Align › list the three alignments with
    /// the block's checked, and choosing one aligns that block.
    func testFormatBarAndBlockMenuAlignTheBlock() async throws {
        let source = "One\n\nTwo words\n"
        let fixture = try await makeFixture(markdown: source)
        let words = (source as NSString).range(of: "words").location
        try await fixture.setSelection(words, words + 5)
        _ = try await fixture.evaluate("document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
        let barShown = await waitUntil { ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible button[aria-label=\"Align\"]:not(:disabled)'))")) as? Bool) == true }
        XCTAssertTrue(barShown, "The format bar offers the block's alignment")
        _ = try await fixture.evaluate("document.querySelector('.mk-toolbar.mk-visible button[aria-label=\"Align\"]').click(); true")
        let rows = try await fixture.evaluate(Self.alignMenuRows) as? String
        XCTAssertEqual(rows, "Left ✓,Center,Right", "Its menu lists the alignments, the block's checked")
        _ = try await fixture.evaluate(Self.clickAlignRow("Right"))
        let right = "One\n\n<div align=\"right\">\n\nTwo words\n\n</div>\n"
        let aligned = await waitUntil { fixture.store.documentText == right }
        XCTAssertTrue(aligned, fixture.store.documentText)
        let selected = try await fixture.evaluate("window.getSelection().toString()") as? String
        XCTAssertEqual(selected, "words", "The selection stays on the words")

        try await fixture.hoverBlock(containing: "Two words")
        try await fixture.openBlockMenu()
        let labels = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-row-label')].map(e => e.textContent).join(',')") as? String
        XCTAssertEqual(labels, "Turn into,Align,Duplicate,Copy,Move up,Delete")
        _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Align')).click(); true")
        let submenu = await waitUntil { ((try? await fixture.evaluate(Self.alignMenuRows)) as? String) == "Left,Center,Right ✓" }
        XCTAssertTrue(submenu, "Align opens beside the menu with the block's alignment checked")
        _ = try await fixture.evaluate(Self.clickAlignRow("Center"))
        let centered = await waitUntil { fixture.store.documentText == "One\n\n<div align=\"center\">\n\nTwo words\n\n</div>\n" }
        XCTAssertTrue(centered, fixture.store.documentText)

        try await fixture.hoverBlock(containing: "Two words")
        try await fixture.openBlockMenu()
        _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Align')).click(); true")
        _ = await waitUntil { ((try? await fixture.evaluate(Self.alignMenuRows)) as? String) != nil }
        _ = try await fixture.evaluate(Self.clickAlignRow("Left"))
        let left = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(left, fixture.store.documentText)
    }

    /// The pointer over an image shows a bar of its alignments; choosing one aligns the image's
    /// paragraph, and the image stays selected with the bar showing the new alignment.
    func testMediaBarAlignsAnImage() async throws {
        let source = "Intro\n\n![Chart](chart.png)\n"
        let fixture = try await makeFixture(markdown: source, images: ["chart.png": CGSize(width: 320, height: 160)])
        try await fixture.hoverImage()
        let pressed = try await fixture.evaluate(Self.mediaBarPressed) as? String
        XCTAssertEqual(pressed, "Align left")
        _ = try await fixture.evaluate("document.querySelector('.mk-media-bar button[aria-label=\"Center\"]').click(); true")
        let centered = "Intro\n\n<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n"
        let aligned = await waitUntil { fixture.store.documentText == centered }
        XCTAssertTrue(aligned, fixture.store.documentText)
        let followed = await waitUntil { ((try? await fixture.evaluate(Self.mediaBarPressed)) as? String) == "Center" }
        XCTAssertTrue(followed, "The bar stays on the image and shows its alignment")
        let selected = try await fixture.evaluate("(() => { const r = window.getSelection().getRangeAt(0); return r.startContainer.childNodes[r.startOffset]?.tagName ?? ''; })()") as? String
        XCTAssertEqual(selected, "IMG", "The image stays selected")
        let formatBar = try await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible:not(.mk-media-bar)'))") as? Bool
        XCTAssertEqual(formatBar, false, "A selected image has the media bar, not the format bar")
        let center = try await fixture.evaluate("(() => { const img = document.querySelector('#content img').getBoundingClientRect(); const p = img && document.querySelector('#content img').parentElement.getBoundingClientRect(); return Math.abs((img.left + img.right) / 2 - (p.left + p.right) / 2) < 1; })()") as? Bool
        XCTAssertEqual(center, true, "The image sits in the middle of the column")

        _ = try await fixture.evaluate("document.querySelector('.mk-media-bar button[aria-label=\"Align left\"]').click(); true")
        let back = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(back, fixture.store.documentText)
    }

    /// Dragging an image's side handle resizes it at once, shows its size and writes the width as
    /// one undo step when it lets go; Esc puts it back, a centred image grows from both sides, the
    /// width stays between 80 and the column, and a double-click gives the image its own size.
    func testDraggingAMediaHandleResizesAsOneUndoStep() async throws {
        let source = "![Chart](chart.png)\n"
        let fixture = try await makeFixture(markdown: source, images: ["chart.png": CGSize(width: 400, height: 200)])
        try await fixture.hoverImage()
        let grips = try await fixture.evaluate("document.querySelectorAll('.mk-resize-handle.mk-visible').length") as? Int
        XCTAssertEqual(grips, 2, "A handle on each side")

        let live = try await fixture.evaluate(Self.dragGrip("right", by: 60, release: false)) as? String
        XCTAssertEqual(live, "460px|460 × 230", "The image follows the pointer and shows its size")
        XCTAssertEqual(fixture.store.documentText, source, "Nothing is written until the handle lets go")
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 })); true")
        let resized = await waitUntil { fixture.store.documentText == "![Chart|460](chart.png)\n" }
        XCTAssertTrue(resized, fixture.store.documentText)
        let width = try await fixture.evaluate("document.querySelector('#content img').getBoundingClientRect().width") as? Double
        XCTAssertEqual(width ?? 0, 460, accuracy: 0.5)
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Resize")
        undoManager.undo()
        let undone = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(undone, "One undo takes the whole drag back: \(fixture.store.documentText)")

        // Esc while dragging puts the image back as it was.
        try await fixture.hoverImage()
        _ = try await fixture.evaluate(Self.dragGrip("right", by: 50, release: false))
        let cancelled = try await fixture.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, button: 0 })); document.querySelector('#content img').style.width") as? String
        XCTAssertEqual(cancelled, "", "Esc puts the image back")
        XCTAssertEqual(fixture.store.documentText, source)

        // Never narrower than 80 px, never wider than the column.
        try await fixture.hoverImage()
        _ = try await fixture.evaluate(Self.dragGrip("left", by: 1000, release: true))
        let narrow = await waitUntil { fixture.store.documentText == "![Chart|80](chart.png)\n" }
        XCTAssertTrue(narrow, fixture.store.documentText)
        try await fixture.hoverImage()
        _ = try await fixture.evaluate(Self.dragGrip("right", by: 2000, release: true))
        let column = try await fixture.evaluate("Math.round(document.querySelector('#content p').clientWidth)") as? Int
        let wide = await waitUntil { fixture.store.documentText == "![Chart|\(column ?? 0)](chart.png)\n" }
        XCTAssertTrue(wide, "\(fixture.store.documentText) for a column of \(column ?? 0)")

        // Centred, the image grows from both sides: the handle's edge follows the pointer.
        try await fixture.setImageWidth(200)
        try await fixture.hoverImage()
        _ = try await fixture.evaluate("document.querySelector('.mk-media-bar button[aria-label=\"Center\"]').click(); true")
        _ = await waitUntil { fixture.store.documentText.hasPrefix("<div align=\"center\">") }
        try await fixture.hoverImage()
        let grown = try await fixture.evaluate(Self.dragGrip("right", by: 30, release: false)) as? String
        XCTAssertEqual(grown?.components(separatedBy: "|").first, "260px")
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 })); true")
        let centred = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\n![Chart|260](chart.png)\n\n</div>\n" }
        XCTAssertTrue(centred, fixture.store.documentText)

        try await fixture.hoverImage()
        _ = try await fixture.evaluate("document.querySelector('.mk-resize-handle[data-side=\"left\"]').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); true")
        let original = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n" }
        XCTAssertTrue(original, fixture.store.documentText)
        XCTAssertEqual(undoManager.undoActionName, "Original Size")
    }

    /// Writing on in an aligned block: Return keeps the alignment for the next line, the next line's
    /// text gets a blank line before `</div>`, Return on the empty last line leaves the alignment,
    /// and the line after it reads left aligned again.
    func testReturnInAlignedTextKeepsTheAlignmentUntilAnEmptyLine() async throws {
        let source = "Title\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection(5)
        fixture.press(.character("e"), modifiers: [.command, .shift])
        let centered = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\nTitle\n\n</div>\n" }
        XCTAssertTrue(centered, fixture.store.documentText)
        fixture.press(.return)
        fixture.type("Sub")
        let typed = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\nTitle\n\nSub\n\n</div>\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        let subAlignment = try await fixture.evaluate(Self.textAlign(of: "Sub")) as? String
        XCTAssertEqual(subAlignment, "-webkit-center", "The new line is centred as the one above")
        fixture.press(.return)
        fixture.press(.return)
        fixture.type("Body")
        let left = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\nTitle\n\nSub\n\n</div>\n\nBody\n" }
        XCTAssertTrue(left, "Return on the empty last line leaves the alignment: \(fixture.store.documentText)")
        let bodyAlignment = try await fixture.evaluate(Self.textAlign(of: "Body")) as? String
        XCTAssertEqual(bodyAlignment, "start")
    }

    /// Return after an aligned image starts a line of text after it, left aligned, whether the image
    /// is selected (as the media bar leaves it) or the caret is after it; it never replaces the image.
    func testReturnAfterAnAlignedImageStartsATextLine() async throws {
        let source = "Intro\n\n![Chart](chart.png)\n\nAfter\n"
        let fixture = try await makeFixture(markdown: source, images: ["chart.png": CGSize(width: 320, height: 160)])
        try await fixture.hoverImage()
        _ = try await fixture.evaluate("document.querySelector('.mk-media-bar button[aria-label=\"Center\"]').click(); true")
        let centered = "Intro\n\n<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n\nAfter\n"
        let aligned = await waitUntil { fixture.store.documentText == centered }
        XCTAssertTrue(aligned, fixture.store.documentText)
        let selected = await waitUntil { ((try? await fixture.evaluate("window.getSelection().toString() === '' && !window.getSelection().isCollapsed")) as? Bool) == true }
        XCTAssertTrue(selected, "The image is selected")
        fixture.press(.return)
        fixture.type("Caption")
        let captioned = "Intro\n\n<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n\nCaption\n\nAfter\n"
        let typed = await waitUntil { fixture.store.documentText == captioned }
        XCTAssertTrue(typed, "Return with the image selected keeps it and starts a line after it: \(fixture.store.documentText)")
        let alignment = try await fixture.evaluate(Self.textAlign(of: "Caption")) as? String
        XCTAssertEqual(alignment, "start")

        // The caret right after the image: the same.
        let image = (captioned as NSString).range(of: "![Chart](chart.png)")
        try await fixture.setSelection(image.location + image.length)
        fixture.press(.return)
        fixture.type("Note")
        let noted = await waitUntil { fixture.store.documentText == "Intro\n\n<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n\nNote\n\nCaption\n\nAfter\n" }
        XCTAssertTrue(noted, fixture.store.documentText)
    }

    /// An empty line takes an alignment to type in: the placeholder sits where the caret does, the
    /// typed text is centred, and ⌫ on the empty centred line takes it away as it would any line.
    func testAnEmptyLineTakesAnAlignmentToTypeIn() async throws {
        let source = "Intro\n\n\n\nAfter\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection(7)
        fixture.press(.character("e"), modifiers: [.command, .shift])
        let wrapped = "Intro\n\n<div align=\"center\">\n\n</div>\n\n\nAfter\n"
        let centered = await waitUntil { fixture.store.documentText == wrapped }
        XCTAssertTrue(centered, fixture.store.documentText)
        let placeholder = try await fixture.evaluate("(() => { const line = document.querySelector('#content div[align=center] .mk-empty'); return line ? Math.abs(parseFloat(getComputedStyle(line, '::before').left) - line.clientWidth / 2) < 1 : false; })()") as? Bool
        XCTAssertEqual(placeholder, true, "The placeholder starts at the caret, in the middle of the line")
        fixture.press(.backspace)
        let removed = await waitUntil { fixture.store.documentText == "Intro\n\n\nAfter\n" }
        XCTAssertTrue(removed, "⌫ takes the empty centred line away: \(fixture.store.documentText)")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        undoManager.undo()
        let back = await waitUntil { fixture.store.documentText == wrapped }
        XCTAssertTrue(back, fixture.store.documentText)
        try await fixture.setSelection((wrapped as NSString).range(of: "<div align=\"center\">\n").upperBound)
        fixture.type("Centered")
        let typed = await waitUntil { fixture.store.documentText == "Intro\n\n<div align=\"center\">\n\nCentered\n\n</div>\n\n\nAfter\n" }
        XCTAssertTrue(typed, fixture.store.documentText)
        let alignment = try await fixture.evaluate(Self.textAlign(of: "Centered")) as? String
        XCTAssertEqual(alignment, "-webkit-center")
    }

    /// ⌫ at the start of the line after an aligned block and ⌦ at the end of its last line join the
    /// two as they would any two lines; the joined text keeps the aligned block's alignment.
    func testBackspaceAndDeleteJoinAcrossAnAlignedBlock() async throws {
        let source = "<div align=\"center\">\n\nAlpha\n\n</div>\n\nBeta\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection((source as NSString).range(of: "Beta").location)
        fixture.press(.backspace)
        let joined = "<div align=\"center\">\n\nAlphaBeta\n\n</div>\n"
        let backspaced = await waitUntil { fixture.store.documentText == joined }
        XCTAssertTrue(backspaced, fixture.store.documentText)
        fixture.type(" ")
        let caret = await waitUntil { fixture.store.documentText == "<div align=\"center\">\n\nAlpha Beta\n\n</div>\n" }
        XCTAssertTrue(caret, "The caret stays where the two met: \(fixture.store.documentText)")
        let undoManager = try XCTUnwrap(fixture.webView.undoManager)
        undoManager.undo()
        undoManager.undo()
        let restored = await waitUntil { fixture.store.documentText == source }
        XCTAssertTrue(restored, fixture.store.documentText)

        try await fixture.setSelection((source as NSString).range(of: "Alpha").upperBound)
        fixture.press(.forwardDelete)
        let forward = await waitUntil { fixture.store.documentText == joined }
        XCTAssertTrue(forward, fixture.store.documentText)
    }

    /// A selected aligned image deleted with ⌫ leaves an empty centred line; ⌫ again takes the line
    /// and its alignment away.
    func testDeletingASelectedAlignedImage() async throws {
        let source = "Intro\n\n<div align=\"center\">\n\n![Chart](chart.png)\n\n</div>\n\nAfter\n"
        let fixture = try await makeFixture(markdown: source, images: ["chart.png": CGSize(width: 320, height: 160)])
        try await fixture.hoverImage()
        _ = try await fixture.evaluate("(() => { const img = document.querySelector('#content img'); const box = img.getBoundingClientRect(); img.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: box.left + 10, clientY: box.top + 10, button: 0 })); return true; })()")
        let selected = await waitUntil { ((try? await fixture.evaluate("Boolean(document.querySelector('.mk-media-bar.mk-visible'))")) as? Bool) == true }
        XCTAssertTrue(selected, "Clicking the image selects it and shows its bar")
        fixture.press(.backspace)
        let emptied = await waitUntil { fixture.store.documentText == "Intro\n\n<div align=\"center\">\n\n\n\n</div>\n\nAfter\n" }
        XCTAssertTrue(emptied, fixture.store.documentText)
        fixture.press(.backspace)
        let gone = await waitUntil { fixture.store.documentText == "Intro\n\nAfter\n" }
        XCTAssertTrue(gone, fixture.store.documentText)
    }

    private static func textAlign(of text: String) -> String {
        "getComputedStyle([...document.querySelectorAll('#content p, #content h1, #content h2')].find(e => e.textContent === '\(text)')).textAlign"
    }

    private static let alignMenuRows = """
    (() => {
      const menu = document.querySelector('.mk-menu.mk-visible[aria-label="Align"]');
      return menu ? [...menu.querySelectorAll('.mk-menu-row')].map(r => r.querySelector('.mk-row-label').textContent + (r.querySelector('.mk-row-check:not(.mk-row-unchecked)') ? ' ✓' : '')).join(',') : null;
    })()
    """

    private static func clickAlignRow(_ label: String) -> String {
        "[...document.querySelectorAll('.mk-menu.mk-visible[aria-label=\"Align\"] .mk-menu-row')].find(r => r.querySelector('.mk-row-label').textContent === '\(label)').click(); true"
    }

    private static let mediaBarPressed = "[...document.querySelectorAll('.mk-media-bar.mk-visible .mk-tool.mk-on')].map(b => b.getAttribute('aria-label')).join(',')"

    /// Presses a resize handle and moves the pointer `by` points outward (inward for the left one),
    /// letting go when `release`. Returns the image's inline width and the size shown.
    fileprivate static func dragGrip(_ side: String, by distance: Int, release: Bool) -> String {
        """
        (() => {
          const grip = document.querySelector('.mk-resize-handle[data-side="\(side)"]');
          const box = grip.getBoundingClientRect();
          const x = box.left + box.width / 2;
          const y = box.top + box.height / 2;
          const at = (type, clientX, element) => (element || document).dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX, clientY: y, button: 0 }));
          at('mousedown', x, grip);
          at('mousemove', x + \(distance));
          const shown = document.querySelector('#content img').style.width + '|' + [...document.querySelectorAll('.mk-tooltip.mk-visible')].map(e => e.textContent).join('');
          if (\(release)) at('mouseup', x + \(distance));
          return shown;
        })()
        """
    }

    private static let slashMenuShown = "Boolean(document.querySelector('.mk-menu.mk-visible[aria-label=\"Insert block\"]'))"

    /// Every floating surface and block state, captured into `MONKNOT_EDITOR_SNAPSHOT_DIR` for
    /// review. It skips otherwise: each surface's behaviour has its own test.
    func testEditorSurfaceGallery() async throws {
        guard ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set MONKNOT_EDITOR_SNAPSHOT_DIR to capture the editor's surfaces")
        }
        let markdown = """
        # Gallery

        [TOC]

        A paragraph with **bold**, a [link](https://monki.work) and `code`.

        > [!WARNING]
        > Back up before migrating.

        <details>
        <summary>Closed toggle</summary>

        Hidden body.

        </details>

        <details open>
        <summary>Open toggle</summary>

        Visible body.

        </details>

        | Name | Role |
        | --- | --- |
        | Ada | Engineer |

        ```swift
        let answer = 42
        ```

        Last line.

        """
        let directory = ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for (name, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            let fixture = try await makeFixture(markdown: markdown, theme: theme, width: 900)
            // CSS transitions do not run in a window behind other apps, so the images show end states.
            _ = try await fixture.evaluate("(() => { const s = document.createElement('style'); s.textContent = '*, *::before, *::after { transition: none !important; } .mk-block-moved { animation: none !important; }'; document.head.appendChild(s); return true; })()")
            func shot(_ label: String) async throws {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let directory { try await fixture.snapshot(to: directory.appendingPathComponent("gallery-\(name)-\(label).png")) }
            }
            func visible(_ selector: String) async throws -> Bool {
                (try await fixture.evaluate("Boolean(document.querySelector('\(selector)'))") as? Bool) == true
            }
            let source = markdown as NSString
            try await shot("page")

            // Format bar over bold text, selected as a person would: the mouse comes up on the page.
            let bold = source.range(of: "bold").location
            try await fixture.setSelection(bold, bold + 4)
            _ = try await fixture.evaluate("document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
            try await shot("format-bar")
            let barShown = try await visible(".mk-toolbar.mk-visible")
            XCTAssertTrue(barShown, "\(name): format bar")
            _ = try await fixture.evaluate("document.querySelector('.mk-toolbar.mk-visible .mk-tool-menu').click(); true")
            try await shot("format-bar-turn-into")
            fixture.press(.escape)

            // Link card, then the link editor.
            let link = source.range(of: "link]").location + 2
            try await fixture.setSelection(link)
            try await shot("link-card")
            let cardShown = try await visible(".mk-link-card.mk-visible")
            XCTAssertTrue(cardShown, "\(name): link card")
            fixture.press(.character("k"), modifiers: .command)
            try await shot("link-editor")
            fixture.press(.escape)

            // Table bar and its Row menu.
            let cell = source.range(of: "Engineer").location + 2
            try await fixture.setSelection(cell)
            try await shot("table-bar")
            _ = try await fixture.evaluate("document.querySelector('.mk-table-bar .mk-tool-menu').click(); true")
            try await shot("table-row-menu")
            fixture.press(.escape)

            // Code language menu.
            _ = try await fixture.evaluate("document.querySelector('.mk-code-language').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
            try await shot("code-language-menu")
            _ = try await fixture.evaluate("document.activeElement && document.activeElement.blur(); true")
            fixture.press(.escape)

            // Callout kind menu.
            _ = try await fixture.evaluate("document.querySelector('.callout-title').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
            try await shot("callout-menu")
            fixture.press(.escape)

            // Handles with the grip's tooltip, then the block menu.
            try await fixture.hoverBlock(containing: "Last line.")
            _ = try await fixture.evaluate("document.querySelector('.mk-handle-drag').dispatchEvent(new MouseEvent('mouseenter')); true")
            try await Task.sleep(nanoseconds: 600_000_000)
            try await shot("handles-tooltip")
            _ = try await fixture.evaluate("document.querySelector('.mk-handle-drag').dispatchEvent(new MouseEvent('mouseleave')); true")

            // Drag in progress.
            _ = try await fixture.evaluate("""
            (() => {
              const grip = document.querySelector('.mk-handle-drag').getBoundingClientRect();
              const target = document.querySelector('.callout').getBoundingClientRect();
              const at = (type, x, y, element) => (element || document).dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 }));
              at('mousedown', grip.left + 4, grip.top + 4, document.querySelector('.mk-handle-drag'));
              at('mousemove', grip.left + 30, grip.top - 20);
              at('mousemove', grip.left + 60, target.top - 4);
              return true;
            })()
            """)
            try await shot("dragging")
            fixture.press(.escape)
            _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, button: 0 })); true")

            try await fixture.hoverBlock(containing: "Last line.")
            _ = try await fixture.evaluate("""
            (() => {
              const grip = document.querySelector('.mk-handle-drag');
              grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
              document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 }));
              return true;
            })()
            """)
            try await shot("block-menu")
            _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Turn into'))?.click(); true")
            try await shot("block-menu-turn-into")
            _ = try await fixture.evaluate("document.activeElement && document.activeElement.blur(); true")
            fixture.press(.escape)
            fixture.press(.escape)

            // Slash menu on a new line, and an empty document's placeholder.
            let last = source.range(of: "Last line.").location + 10
            try await fixture.setSelection(last)
            fixture.press(.return)
            fixture.type("/")
            try await shot("slash-menu")
            fixture.type("med")
            try await shot("slash-filter-empty-ish")
            fixture.press(.escape)
            fixture.close()
        }
    }

    /// Writes snapshots of the editor in both themes and at a narrow width into
    /// `MONKNOT_EDITOR_SNAPSHOT_DIR`. It skips otherwise: the menus it opens have their own tests.
    func testSnapshotsInBothThemesAndANarrowWindow() async throws {
        guard ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set MONKNOT_EDITOR_SNAPSHOT_DIR to capture the editor in both themes and a narrow window")
        }
        let markdown = """
        # Product brief

        [TOC]

        Monknot keeps **notes** as plain *Markdown* files, with `inline code`, [links](https://monki.work) and
        a [[Wiki Page|wiki link]].

        ## Tasks

        - [ ] Draft the outline
        - [x] Collect feedback from the design review and fold it into the spec before Friday
          - [ ] Nested follow-up

        - Bullet
          - Nested bullet

        1. First step
        2. Second step

        > [!TIP]
        > Callouts keep **any** Markdown.

        <details open>
        <summary>A toggle</summary>

        Its body, shown while open.

        </details>

        > Quotes keep their ~~struck~~ text.

        | Name | Role |
        | --- | --- |
        | Ada | Engineer |

        ```swift
        let answer = 42
        ```

        ---

        Text after the divider.

        """
        let directory = ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
        for (name, theme, width) in [("light", AppTheme.defaultLight, 900.0), ("dark", AppTheme.defaultDark, 900.0), ("narrow", AppTheme.defaultLight, 420.0)] {
            let fixture = try await makeFixture(markdown: markdown, theme: theme, width: width, notes: Self.wikilinkNotes)
            // A test window behind other apps pauses WebKit's transitions; show the end state.
            _ = try await fixture.evaluate("(() => { const s = document.createElement('style'); s.textContent = '.mk-floating, .mk-handles, .mk-tooltip { transition: none !important; }'; document.head.appendChild(s); return true; })()")
            let height = try await fixture.evaluate("document.getElementById('content').getBoundingClientRect().height") as? Double
            XCTAssertGreaterThan(height ?? 0, 200, name)
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name).png"))
            }

            let paragraph = (markdown as NSString).range(of: "plain").location
            try await fixture.setSelection(paragraph, paragraph + 5)
            _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup')); document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
            try await Task.sleep(nanoseconds: 400_000_000)
            let barShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-toolbar.mk-visible'))") as? Bool
            XCTAssertEqual(barShown, true, "\(name): selecting text shows the format bar")
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-format-bar.png"))
            }

            let end = (markdown as NSString).range(of: "Text after the divider.").location + 23
            try await fixture.setSelection(end)
            fixture.press(.return)
            fixture.type("/")
            try await Task.sleep(nanoseconds: 400_000_000)
            let menuShown = try await fixture.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible'))") as? Bool
            XCTAssertEqual(menuShown, true, "\(name): typing / on an empty line opens the block menu")
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-slash-menu.png"))
            }
            fixture.type("tab")
            try await Task.sleep(nanoseconds: 300_000_000)
            let rows = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-row-label')].map(e => e.textContent).join(',')") as? String
            XCTAssertEqual(rows?.components(separatedBy: ",").first, "Table", "\(name): the query filters the menu")
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-slash-filter.png"))
            }
            fixture.press(.escape)

            fixture.type(" [[pro")
            let notes = await fixture.wikilinkRows(matching: { !$0.isEmpty })
            XCTAssertEqual(notes.first, "Prototype", "\(name): typing [[ lists matching notes")
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-wikilink-menu.png"))
            }
            fixture.press(.escape)

            try await fixture.hoverBlock(containing: "Text after the divider.")
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-handles.png"))
            }
            _ = try await fixture.evaluate("""
            (() => {
              const grip = document.querySelector('.mk-handle-drag');
              grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
              document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 }));
              return true;
            })()
            """)
            _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Turn into'))?.click(); true")
            try await Task.sleep(nanoseconds: 300_000_000)
            if let directory {
                try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-block-menu.png"))
            }
            fixture.press(.escape)
            fixture.press(.escape)

            if name != "narrow" {
                let word = (markdown as NSString).range(of: "notes").location
                try await fixture.setSelection(word, word + 5)
                fixture.press(.character("k"), modifiers: .command)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let directory {
                    try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-link-editor.png"))
                }
                fixture.press(.escape)
                let cell = (markdown as NSString).range(of: "Engineer").location + 3
                try await fixture.setSelection(cell)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let directory {
                    try await fixture.snapshot(to: directory.appendingPathComponent("editor-\(name)-table-bar.png"))
                }
            }
            fixture.close()
        }
    }

    /// Aligned blocks, a sized image with its bar and handles, a resize under way, and the alignment
    /// menus, in both themes and a narrow window, into `MONKNOT_EDITOR_SNAPSHOT_DIR` for review
    /// (`MONKNOT_EDITOR_SNAPSHOT_ZOOM` for another zoom). It skips otherwise.
    func testAlignmentAndMediaSnapshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_EDITOR_SNAPSHOT_DIR to capture alignment and media sizing")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = """
        # Launch notes

        <div align="center">

        ## A centred heading

        A centred paragraph under it, set in the middle of the column.

        </div>

        <div align="right">

        Signed, the team

        </div>

        <div align="center">

        ![Chart|360](chart.png)

        </div>

        Text after the image.

        """
        let zoom = ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_ZOOM"].map { "-zoom\($0)" } ?? ""
        for (name, theme, width) in [("light", AppTheme.defaultLight, 900.0), ("dark", AppTheme.defaultDark, 900.0), ("narrow", AppTheme.defaultLight, 420.0)] {
            let fixture = try await makeFixture(markdown: markdown, theme: theme, width: width, images: ["chart.png": CGSize(width: 480, height: 240)])
            _ = try await fixture.evaluate("(() => { const s = document.createElement('style'); s.textContent = '*, *::before, *::after { transition: none !important; }'; document.head.appendChild(s); return true; })()")
            func shot(_ label: String) async throws {
                try await Task.sleep(nanoseconds: 250_000_000)
                try await fixture.snapshot(to: directory.appendingPathComponent("align-\(name)\(zoom)-\(label).png"))
            }
            try await fixture.hoverImage()
            try await shot("media-bar")
            _ = try await fixture.evaluate(Self.dragGrip("right", by: 40, release: false))
            try await shot("resizing")
            _ = try await fixture.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, button: 0 })); true")

            _ = try await fixture.evaluate("document.querySelector('#content h1').dispatchEvent(new MouseEvent('mousemove', { bubbles: true })); true")
            try await Task.sleep(nanoseconds: 300_000_000)
            let words = (markdown as NSString).range(of: "centred paragraph").location
            try await fixture.setSelection(words, words + 17)
            _ = try await fixture.evaluate("document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
            try await shot("format-bar")
            _ = try await fixture.evaluate("document.querySelector('.mk-toolbar.mk-visible button[aria-label=\"Align\"]')?.click(); true")
            try await shot("format-bar-align")
            fixture.press(.escape)

            // Return at the end of a right-aligned and a centred line: an empty aligned line.
            for (label, line) in [("new-line-right", "Signed, the team"), ("new-line-center", "middle of the column.")] {
                let end = (markdown as NSString).range(of: line)
                try await fixture.setSelection(end.location + end.length)
                fixture.press(.return)
                try await shot(label)
                let empty = await waitUntil { fixture.store.documentText == markdown.replacingOccurrences(of: line + "\n\n", with: line + "\n\n\n") }
                XCTAssertTrue(empty, "\(name): Return makes an empty aligned line")
                try XCTUnwrap(fixture.webView.undoManager).undo()
                _ = await waitUntil { fixture.store.documentText == markdown }
            }

            try await fixture.hoverBlock(containing: "Signed, the team")
            try await fixture.openBlockMenu()
            _ = try await fixture.evaluate("[...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.textContent.includes('Align'))?.click(); true")
            try await shot("block-menu-align")
            fixture.press(.escape)
            fixture.press(.escape)
            fixture.close()
        }
    }

    // MARK: - Fixture

    private func makeFixture(
        markdown: String,
        theme: AppTheme = .defaultLight,
        width: CGFloat = 800,
        timeout: TimeInterval = 10,
        notes: [String] = [],
        images: [String: CGSize] = [:],
        viewportState: DocumentViewportState? = nil
    ) async throws -> Fixture {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotVisualEditor")
        let file = root.appendingPathComponent("Note.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        for (name, size) in images {
            try Self.png(size).write(to: root.appendingPathComponent(name))
        }
        for note in notes {
            let url = root.appendingPathComponent(note)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(url.deletingPathExtension().lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: file)
        let loaded = await waitUntil(timeout: timeout) {
            !store.isBusy && store.selectedDocument?.displayName == "Note.md" && !store.isDocumentLoading
                && store.markdownDocuments.count == notes.count + 1
        }
        XCTAssertTrue(loaded, "Workspace did not load")
        store.testing_stopFileWatcher()

        let harness = VisualEditorHarnessModel(store: store, theme: theme)
        harness.viewportState = viewportState
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // As in FlowEditorTestFixture: an animated order-front or close parks a GCD worker for good
        // while the screen is locked, and enough of them stall WebKit's page loads.
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: VisualEditorHarness(model: harness).frame(width: width, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        hostWindows.append(window)
        let fixture = Fixture(store: store, harness: harness, window: window, host: host, test: self)
        _ = try await fixture.waitForEditor(timeout: timeout)
        return fixture
    }

    /// A PNG of one colour, `size` pixels at one pixel per point.
    private static func png(_ size: CGSize) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    fileprivate func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @MainActor
    fileprivate final class Fixture {
        let store: WorkspaceStore
        let harness: VisualEditorHarnessModel
        let window: NSWindow
        let host: NSView
        unowned let test: MarkdownVisualEditorTests
        private(set) var webView: WKWebView!

        init(store: WorkspaceStore, harness: VisualEditorHarnessModel, window: NSWindow, host: NSView, test: MarkdownVisualEditorTests) {
            self.store = store
            self.harness = harness
            self.window = window
            self.host = host
            self.test = test
        }

        func waitForEditor(timeout: TimeInterval = 10) async throws -> WKWebView {
            let ready = await test.waitUntil(timeout: timeout) {
                guard let webView = self.findWebView() else { return false }
                let active = (try? await webView.evaluateJavaScript("Boolean(window.MonknotEditor && window.MonknotEditor.isActive() && window.MonknotEditor.source() !== null)")) as? Bool
                if active == true {
                    self.webView = webView
                    return true
                }
                return false
            }
            XCTAssertTrue(ready, "The editor did not become active")
            return try XCTUnwrap(webView)
        }

        func findWebView() -> WKWebView? {
            descendants(of: WKWebView.self, in: host).first
        }

        func documentTextView() -> NSTextView? {
            descendants(of: NSTextView.self, in: host).first { $0.identifier == .monknotDocumentFocusTarget }
        }

        private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
            var result: [T] = []
            if let match = view as? T { result.append(match) }
            for subview in view.subviews { result += descendants(of: type, in: subview) }
            return result
        }

        @discardableResult
        func evaluate(_ script: String) async throws -> Any? {
            try await webView.evaluateJavaScript(script)
        }

        func setSelection(_ anchor: Int, _ head: Int? = nil) async throws {
            window.makeFirstResponder(webView)
            let ok = try await evaluate("window.MonknotEditor.setSelection(\(anchor), \(head ?? anchor))") as? Bool
            XCTAssertEqual(ok, true)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        /// Switches to Source, changes the text there as `transform` says and comes back to a new
        /// Preview page showing it.
        func editInSource(_ transform: (String) -> String) async throws -> WKWebView {
            harness.editorMode = .source
            let shown = await test.waitUntil { self.documentTextView() != nil && self.findWebView() == nil }
            XCTAssertTrue(shown, "Source shows")
            store.setDocumentText(transform(store.documentText))
            let expected = store.documentText
            harness.editorMode = .preview
            let webView = try await waitForEditor()
            let synced = await test.waitUntil {
                ((try? await self.evaluate("window.MonknotEditor.source()")) as? String) == expected
            }
            XCTAssertTrue(synced, "Preview shows the text from Source")
            return webView
        }

        /// A click in the margin below the document's last block.
        func clickBelowTheLastBlock() async throws {
            window.makeFirstResponder(webView)
            _ = try await evaluate("""
            (() => {
              const root = document.getElementById('content');
              const blocks = [...root.children].filter(e => !e.classList.contains('footnotes'));
              const box = blocks[blocks.length - 1].getBoundingClientRect();
              const point = { clientX: box.left + 10, clientY: box.bottom + 16, bubbles: true, cancelable: true };
              root.dispatchEvent(new MouseEvent('mousedown', point));
              root.dispatchEvent(new MouseEvent('mouseup', point));
              return true;
            })()
            """)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        /// Moves the pointer over the block holding `text`, as a hover would, until its handles show.
        func hoverBlock(containing text: String) async throws {
            let literal = String(data: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
            _ = try await evaluate("""
            (() => {
              const block = [...document.querySelectorAll('#content > *')].find(e => e.textContent.trim() === \(literal));
              const box = block.getBoundingClientRect();
              document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.left + 10, clientY: box.top + box.height / 2 }));
              return true;
            })()
            """)
            let shown = await test.waitUntil {
                ((try? await self.evaluate("Boolean(document.querySelector('.mk-handles.mk-visible'))")) as? Bool) == true
            }
            XCTAssertTrue(shown, "Hovering \(text) shows its handles")
        }

        /// Moves the pointer over the document's image, once it has loaded, until its handles show.
        func hoverImage() async throws {
            let loaded = await test.waitUntil {
                ((try? await self.evaluate("(() => { const img = document.querySelector('#content img'); return Boolean(img && img.complete && img.naturalWidth > 0); })()")) as? Bool) == true
            }
            XCTAssertTrue(loaded, "The image loads")
            _ = try await evaluate("""
            (() => {
              const img = document.querySelector('#content img');
              const box = img.getBoundingClientRect();
              img.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 }));
              return true;
            })()
            """)
            let shown = await test.waitUntil {
                ((try? await self.evaluate("document.querySelectorAll('.mk-resize-handle.mk-visible').length")) as? Int) == 2
            }
            XCTAssertTrue(shown, "Hovering the image shows its handles")
        }

        /// Drags the left-aligned image's right handle until the image is `width` wide.
        func setImageWidth(_ width: Int) async throws {
            try await hoverImage()
            let current = try await evaluate("Math.round(document.querySelector('#content img').getBoundingClientRect().width)") as? Int ?? width
            _ = try await evaluate(MarkdownVisualEditorTests.dragGrip("right", by: width - current, release: true))
            let written = await test.waitUntil { self.store.documentText.contains("|\(width)]") }
            XCTAssertTrue(written, self.store.documentText)
        }

        /// A click on the grip of the block the pointer is over: its block menu.
        func openBlockMenu() async throws {
            _ = try await evaluate("""
            (() => {
              const grip = document.querySelector('.mk-handle-drag');
              grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
              document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 }));
              return true;
            })()
            """)
            let opened = await test.waitUntil {
                ((try? await self.evaluate("Boolean(document.querySelector('.mk-menu.mk-visible[aria-label=\"Block\"]'))")) as? Bool) == true
            }
            XCTAssertTrue(opened, "The grip opens the block menu")
        }

        /// The wikilink menu's rows once they satisfy `condition` (the app answers each query
        /// asynchronously), or whatever it shows when the wait runs out.
        func wikilinkRows(matching condition: @escaping ([String]) -> Bool) async -> [String] {
            var rows: [String] = []
            _ = await test.waitUntil {
                rows = ((try? await self.evaluate(MarkdownVisualEditorTests.wikilinkMenuRows)) as? [String]) ?? []
                return condition(rows)
            }
            return rows
        }

        enum Key {
            case `return`
            case backspace
            case forwardDelete
            case escape
            case tab
            case down
            case character(String)

            var characters: String {
                switch self {
                case .return: return "\r"
                case .backspace: return "\u{7F}"
                case .forwardDelete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
                case .escape: return "\u{1B}"
                case .tab: return "\t"
                case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
                case .character(let value): return value
                }
            }

            var keyCode: UInt16 {
                switch self {
                case .return: return 36
                case .backspace: return 51
                case .forwardDelete: return 117
                case .escape: return 53
                case .tab: return 48
                case .down: return 125
                case .character(let value): return ["k": 40, "d": 2, "e": 14, "l": 37, "r": 15][value] ?? 0
                }
            }
        }

        /// Types through AppKit's key handling, as a keyboard would.
        func type(_ text: String) {
            for character in text {
                send(characters: String(character), keyCode: 0)
            }
        }

        func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) {
            send(characters: key.characters, keyCode: key.keyCode, modifiers: modifiers)
        }

        private func send(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            PageKeyboard(window: window, webView: { self.webView })
                .send(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }

        func snapshot(to url: URL) async throws {
            let configuration = WKSnapshotConfiguration()
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            try png.write(to: url)
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}

@MainActor
private final class VisualEditorHarnessModel: ObservableObject {
    let store: WorkspaceStore
    let theme: AppTheme
    @Published var editorMode = EditorMode.preview
    /// What the document was left with: its scroll position and selection.
    var viewportState: DocumentViewportState?
    /// The file imports the editor asked for, as a drop would.
    var fileDropRequests: [MarkdownFileDropRequest] = []

    init(store: WorkspaceStore, theme: AppTheme) {
        self.store = store
        self.theme = theme
    }
}

/// The editor pane as `ContentView` mounts it, in Preview with no split.
private struct VisualEditorHarness: View {
    /// `MONKNOT_EDITOR_SNAPSHOT_ZOOM` takes the editor and its snapshots at that workspace zoom.
    static let zoomScale = ProcessInfo.processInfo.environment["MONKNOT_EDITOR_SNAPSHOT_ZOOM"]
        .flatMap(Double.init).map(WorkspaceZoomPolicy.clamp) ?? 1

    @ObservedObject var model: VisualEditorHarnessModel
    @State private var isSplitViewEnabled = false
    @State private var sourceLocation: MarkdownSourceLocation?
    @State private var previewLocation: MarkdownSourceLocation?
    @State private var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @State private var documentSearch = DocumentSearchState()
    @StateObject private var pdfViewportCaptureBridge = PDFViewportCaptureBridge()

    var body: some View {
        EditorPaneView(
            store: model.store,
            editorMode: $model.editorMode,
            isSplitViewEnabled: $isSplitViewEnabled,
            theme: model.theme,
            zoomScale: Self.zoomScale,
            codeFontSize: 13,
            contentWidthPercent: 88,
            showsDocumentOutline: false,
            usePointerCursors: false,
            fontSmoothing: true,
            activeViewportState: model.viewportState,
            pdfViewportCaptureBridge: pdfViewportCaptureBridge,
            updateViewportState: { _, _ in },
            pdfUndoCommandSerial: 0,
            pdfRedoCommandSerial: 0,
            updatePDFAnnotationUndoState: { _, _ in },
            sourceLocation: $sourceLocation,
            previewLocation: $previewLocation,
            pdfSearchTarget: $pdfSearchTarget,
            pdfPageNavigationRequest: nil,
            pdfNavigatorToggleCommandSerial: 0,
            documentSearch: $documentSearch,
            searchOptions: MonknotSearchOptions(),
            newMarkdown: {},
            bootstrapStarterWorkspace: {},
            openFolder: {},
            saveDocument: {},
            outlineItems: [],
            textStatistics: nil,
            selectOutlineItem: { _ in },
            onPreviewSourceJump: { _ in },
            copyPDFLinkedExcerpt: { _ in },
            updatePDFSelectionSnapshot: { _ in },
            consumePDFPageNavigationRequest: { _ in },
            onMarkdownSelectionChange: { _ in },
            onMarkdownLinkRequest: { _ in },
            onInspectLinks: nil,
            onMarkdownImagePasteRequest: { _ in },
            onMarkdownFileDropRequest: { model.fileDropRequests.append($0) },
            onMarkdownPreviewLinkRequest: { _ in },
            onMarkdownTaskRequest: { _ in }
        )
    }
}
