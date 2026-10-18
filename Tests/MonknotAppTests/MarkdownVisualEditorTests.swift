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

    func testChangeFromOutsideReachesThePageWithoutReloadingIt() async throws {
        let fixture = try await makeFixture(markdown: "Line one\n")
        _ = try await fixture.evaluate("window.__marker = 'same page'; true")
        fixture.store.setDocumentText("Line one\nLine two\n")
        let synced = await waitUntil {
            ((try? await fixture.evaluate("window.MonknotEditor.source()")) as? String) == "Line one\nLine two\n"
        }
        XCTAssertTrue(synced)
        let marker = try await fixture.evaluate("window.__marker") as? String
        XCTAssertEqual(marker, "same page", "The page was patched, not reloaded")
    }

    // MARK: - Performance

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
        XCTAssertLessThan(p95, 16, "A keystroke must render within one frame")
        let stored = await waitUntil(timeout: 10) { fixture.store.documentText.count == markdown.count + 40 }
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
        XCTAssertLessThan(p95, 8)
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
    /// collapsed space at the caret), between words, twice in a row, and in every kind of block,
    /// with a pause between keys as a person types, the space must land in the file where it was
    /// typed and the next word must follow it.
    func testSpacesTypeWhereTheyAreTypedInEveryBlock() async throws {
        let cases: [(name: String, source: String, caretAfter: String, typed: String, expected: String)] = [
            ("paragraph end", "Hello\n", "Hello", " world", "Hello world\n"),
            ("two words", "Hello\n", "Hello", " big world", "Hello big world\n"),
            ("double space", "Hello\n", "Hello", "  x", "Hello  x\n"),
            ("mid word", "Helloworld\n", "Hello", " ", "Hello world\n"),
            // Typing at the end of bold continues it, spaces included (design.md §10.10).
            ("after bold", "**Bold**\n", "Bold", " text", "**Bold text**\n"),
            ("heading", "# Title\n", "Title", " here", "# Title here\n"),
            ("list item", "- item\n", "item", " two", "- item two\n"),
            ("task item", "- [ ] task\n", "task", " done", "- [ ] task done\n"),
            ("numbered item", "1. one\n", "one", " two", "1. one two\n"),
            ("quote", "> quote\n", "quote", " more", "> quote more\n"),
            ("callout", "> [!NOTE]\n> note\n", "note", " more", "> [!NOTE]\n> note more\n"),
            ("table cell", "| a | b |\n| --- | --- |\n| cell | x |\n", "cell", " two", "| a | b |\n| --- | --- |\n| cell two | x |\n"),
            ("toggle title", "<details open>\n<summary>Title</summary>\n\nBody\n\n</details>\n", "Title", " two", "<details open>\n<summary>Title two</summary>\n\nBody\n\n</details>\n"),
            ("toggle body", "<details open>\n<summary>Title</summary>\n\nBody\n\n</details>\n", "Body", " text", "<details open>\n<summary>Title</summary>\n\nBody text\n\n</details>\n"),
            ("code block", "```\nlet x\n```\n", "let x", " = 1", "```\nlet x = 1\n```\n"),
            ("before link", "see [link](u)\n", "see", " the", "see the [link](u)\n"),
        ]
        for testCase in cases {
            let fixture = try await makeFixture(markdown: testCase.source)
            let caret = (testCase.source as NSString).range(of: testCase.caretAfter).location + (testCase.caretAfter as NSString).length
            try await fixture.setSelection(caret)
            for character in testCase.typed {
                fixture.type(String(character))
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            let typed = await waitUntil(timeout: 2) { fixture.store.documentText == testCase.expected }
            XCTAssertTrue(typed, "\(testCase.name): \(fixture.store.documentText.debugDescription)")
            fixture.close()
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
        XCTAssertEqual(labels, "Turn into,Duplicate,Copy,Move up,Move down,Delete")
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

    private static let slashMenuShown = "Boolean(document.querySelector('.mk-menu.mk-visible[aria-label=\"Insert block\"]'))"

    /// Every floating surface and block state, captured into `MONKNOT_EDITOR_SNAPSHOT_DIR` for
    /// review; without it the test only checks each surface appears.
    func testEditorSurfaceGallery() async throws {
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

    /// Writes snapshots of the editor in both themes and at a narrow width when
    /// `MONKNOT_EDITOR_SNAPSHOT_DIR` is set; otherwise only checks that the page renders.
    func testSnapshotsInBothThemesAndANarrowWindow() async throws {
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

    // MARK: - Fixture

    private func makeFixture(
        markdown: String,
        theme: AppTheme = .defaultLight,
        width: CGFloat = 800,
        timeout: TimeInterval = 10,
        notes: [String] = []
    ) async throws -> Fixture {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotVisualEditor")
        let file = root.appendingPathComponent("Note.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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
            case escape
            case tab
            case down
            case character(String)

            var characters: String {
                switch self {
                case .return: return "\r"
                case .backspace: return "\u{7F}"
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
                case .escape: return 53
                case .tab: return 48
                case .down: return 125
                case .character(let value): return value == "k" ? 40 : value == "d" ? 2 : 0
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
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                ) else { continue }
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
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

    init(store: WorkspaceStore, theme: AppTheme) {
        self.store = store
        self.theme = theme
    }
}

/// The editor pane as `ContentView` mounts it, in Preview with no split.
private struct VisualEditorHarness: View {
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
            zoomScale: 1,
            codeFontSize: 13,
            contentWidthPercent: 88,
            showsDocumentOutline: false,
            usePointerCursors: false,
            fontSmoothing: true,
            activeViewportState: nil,
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
            onMarkdownFileDropRequest: { _ in },
            onMarkdownPreviewLinkRequest: { _ in },
            onMarkdownTaskRequest: { _ in }
        )
    }
}
