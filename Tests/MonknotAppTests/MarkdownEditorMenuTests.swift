import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Preview's menus, bars and cards in real WebKit: one menu at a time, a table's menu staying with its
/// table, the code language, the link card, the block menu's submenu under the keyboard and the
/// pointer, and every open surface following the column when it moves.
@MainActor
final class MarkdownEditorMenuTests: WorkspaceStoreTestCase {
    private var hostWindows: [NSWindow] = []

    override func tearDown() async throws {
        for window in hostWindows {
            window.contentView = nil
            window.close()
        }
        hostWindows.removeAll()
        try await super.tearDown()
    }

    // MARK: - One menu at a time

    /// The block menu's field takes focus a moment after ⌘/ opens the menu: Esc pressed before then
    /// still closes it, rather than reaching the text and leaving the menu open.
    func testEscapeRightAfterTheShortcutClosesTheBlockMenu() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n")
        try await fixture.setSelection(3)
        let menus = try await fixture.evaluate("""
        (() => {
          const root = document.getElementById('content');
          const press = (key, metaKey) => root.dispatchEvent(new KeyboardEvent('keydown', { key, metaKey, bubbles: true, cancelable: true }));
          const open = () => [...document.querySelectorAll('.mk-menu.mk-visible')].map((menu) => menu.getAttribute('aria-label'));
          press('/', true);
          const opened = open();
          press('Escape', false);
          return [opened.join(','), open().join(',')];
        })()
        """) as? [String]
        XCTAssertEqual(menus, ["Block", ""], "⌘/ opens the block menu, and Esc closes it before its field has focus")
    }

    func testOpeningAMenuClosesTheOneAlreadyOpen() async throws {
        let fixture = try await makeFixture(markdown: "Alpha\n\nBeta\n")
        try await fixture.setSelection(5)
        fixture.press(.return)
        fixture.type("/")
        let slash = await waitUntil { await fixture.openMenus() == ["Insert block"] }
        XCTAssertTrue(slash, "/ opens the slash menu")

        // ⌘/ at the caret: the block menu takes the slash menu's place.
        fixture.press(.character("/"), modifiers: .command)
        let block = await waitUntil { await fixture.openMenus() == ["Block"] }
        let afterShortcut = await fixture.openMenus()
        XCTAssertTrue(block, "Only the block menu is open: \(afterShortcut)")
        XCTAssertTrue(fixture.store.documentText.contains("/"), "The / typed stays: \(fixture.store.documentText.debugDescription)")
        fixture.press(.escape)
        let closed = await waitUntil { await fixture.openMenus().isEmpty }
        let afterEscape = await fixture.openMenus()
        XCTAssertTrue(closed, "Esc closes the block menu, and no other opens: \(afterEscape)")

        // A click on another block's grip while the slash menu is open.
        try await fixture.setSelection((fixture.store.documentText as NSString).range(of: "/").location + 1)
        fixture.press(.backspace)
        fixture.type("/")
        let reopened = await waitUntil { await fixture.openMenus() == ["Insert block"] }
        XCTAssertTrue(reopened)
        try await fixture.hoverBlock(containing: "Beta")
        try await fixture.clickGrip()
        let swapped = await waitUntil { await fixture.openMenus() == ["Block"] }
        let afterGrip = await fixture.openMenus()
        XCTAssertTrue(swapped, "The grip's menu closes the slash menu: \(afterGrip)")
    }

    // MARK: - Tables

    func testTheTableMenuStaysWithItsTableAndTheBarLeavesTheHeaderVisible() async throws {
        let first = "| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n"
        let source = first + "\nBetween\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection((source as NSString).range(of: "Ada").location + 1)
        let barShown = await waitUntil { await fixture.isVisible(".mk-table-bar.mk-visible") }
        XCTAssertTrue(barShown, "The caret in a cell shows the table bar")
        // The table opens the document, so there is no room above it: the bar goes below, never
        // over the header row.
        let clear = try await fixture.evaluate("""
        (() => {
          const bar = document.querySelector('.mk-table-bar').getBoundingClientRect();
          const head = document.querySelector('table th').closest('tr').getBoundingClientRect();
          return bar.bottom <= head.top + 0.5 || bar.top >= head.bottom - 0.5;
        })()
        """) as? Bool
        XCTAssertEqual(clear, true, "The table bar leaves the header row visible")

        // A click elsewhere closes the Row menu.
        try await fixture.clickTableBarMenu("Row")
        let rowMenu = await waitUntil { await fixture.openMenus() == ["Table"] }
        XCTAssertTrue(rowMenu)
        _ = try await fixture.evaluate("""
        [...document.querySelectorAll('[data-mk-u]')].find(e => e.textContent === 'Between')
          .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true
        """)
        let outside = await waitUntil { await fixture.openMenus().isEmpty }
        XCTAssertTrue(outside, "A click outside closes the table menu")
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); true")

        // The caret moving to another table closes it too, so it never edits a table it was not opened for.
        try await fixture.setSelection((source as NSString).range(of: "Ada").location + 1)
        try await fixture.clickTableBarMenu("Row")
        let again = await waitUntil { await fixture.openMenus() == ["Table"] }
        XCTAssertTrue(again)
        try await fixture.setSelection((source as NSString).range(of: "| 1 |").location + 2)
        let moved = await waitUntil { await fixture.openMenus().isEmpty }
        XCTAssertTrue(moved, "Moving to another table closes the menu")

        // Row and Column menus and Delete Table act on the caret's table only.
        try await fixture.clickTableBarMenu("Row")
        _ = await waitUntil { await fixture.openMenus() == ["Table"] }
        try await fixture.clickMenuRow("Insert row below")
        let rowAdded = await waitUntil {
            fixture.store.documentText.hasPrefix(first) && Self.tableLines(after: "Between", in: fixture.store.documentText).count == 4
        }
        XCTAssertTrue(rowAdded, fixture.store.documentText)

        try await fixture.setSelection((fixture.store.documentText as NSString).range(of: "| 1 |").location + 2)
        try await fixture.clickTableBarMenu("Column")
        _ = await waitUntil { await fixture.openMenus() == ["Table"] }
        try await fixture.clickMenuRow("Insert column right")
        let columnAdded = await waitUntil {
            let header = Self.tableLines(after: "Between", in: fixture.store.documentText).first ?? ""
            return fixture.store.documentText.hasPrefix(first) && header.filter { $0 == "|" }.count == 4
        }
        XCTAssertTrue(columnAdded, fixture.store.documentText)

        try await fixture.setSelection((fixture.store.documentText as NSString).range(of: "| 1 |").location + 2)
        _ = await waitUntil { await fixture.isVisible(".mk-table-bar.mk-visible") }
        _ = try await fixture.evaluate("document.querySelector('.mk-table-bar button[aria-label=\"Delete table\"]').click(); true")
        let deleted = await waitUntil { !fixture.store.documentText.contains("| A |") }
        XCTAssertTrue(deleted, fixture.store.documentText)
        XCTAssertTrue(fixture.store.documentText.hasPrefix(first + "\nBetween\n"), fixture.store.documentText)
    }

    // MARK: - Code language

    func testTheCodeLanguageMenuRewritesTheFence() async throws {
        let fixture = try await makeFixture(markdown: "Intro\n\n```\nlet answer = 42\n```\n")
        _ = try await fixture.evaluate("document.querySelector('.mk-code-language').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
        let open = await waitUntil { await fixture.openMenus() == ["Code language"] }
        XCTAssertTrue(open)
        try await fixture.clickMenuRow("Swift")
        let changed = await waitUntil { fixture.store.documentText == "Intro\n\n```swift\nlet answer = 42\n```\n" }
        XCTAssertTrue(changed, fixture.store.documentText)
        XCTAssertEqual(fixture.webView.undoManager?.undoActionName, "Code Language")
        let closed = await fixture.openMenus()
        XCTAssertTrue(closed.isEmpty, "\(closed)")
    }

    // MARK: - Link card

    func testTheLinkCardOpensEditsAndRemovesTheLink() async throws {
        let source = "See [Monki](https://monki.work) now.\n"
        let fixture = try await makeFixture(markdown: source)
        let inside = (source as NSString).range(of: "Monki").location + 2
        try await fixture.setSelection(inside)
        let card = await waitUntil { await fixture.isVisible(".mk-link-card.mk-visible") }
        XCTAssertTrue(card, "The caret in a link shows its card")
        let address = try await fixture.evaluate("document.querySelector('.mk-link-card .mk-link-url').textContent") as? String
        XCTAssertEqual(address, "https://monki.work")

        _ = try await fixture.evaluate("document.querySelector('.mk-link-card button[aria-label=\"Open link\"]').click(); true")
        let opened = await waitUntil { fixture.harness.linkRequests.last?.destination == "https://monki.work" }
        XCTAssertTrue(opened, "Open asks the app to open the address")

        // Edit, from the pointer: the editor grows in with the address in its field.
        _ = try await fixture.evaluate("document.querySelector('.mk-link-card button[aria-label=\"Edit link\"]').click(); true")
        let editing = await waitUntil {
            ((try? await fixture.evaluate("document.activeElement === document.querySelector('.mk-link-editor .mk-field')")) as? Bool) == true
        }
        XCTAssertTrue(editing, "Edit focuses the link field")
        let grown = try await fixture.evaluate("document.querySelector('.mk-link-editor').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(grown, true, "A link editor the pointer opens grows in")
        let value = try await fixture.evaluate("document.querySelector('.mk-link-editor .mk-field').value") as? String
        XCTAssertEqual(value, "https://monki.work")
        _ = try await fixture.evaluate("document.querySelector('.mk-link-editor .mk-field').value = 'https://example.com'; true")
        fixture.press(.return)
        let edited = await waitUntil { fixture.store.documentText == "See [Monki](https://example.com) now.\n" }
        XCTAssertTrue(edited, "↩ applies the address: \(fixture.store.documentText.debugDescription)")

        // ⌘K opens the same editor at once.
        try await fixture.setSelection(inside)
        fixture.press(.character("k"), modifiers: .command)
        let keyed = await waitUntil { await fixture.isVisible(".mk-link-editor.mk-visible") }
        XCTAssertTrue(keyed)
        let instant = try await fixture.evaluate("document.querySelector('.mk-link-editor').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(instant, false, "A link editor the keyboard opens appears at once")
        fixture.press(.escape)
        let cancelled = await waitUntil { !(await fixture.isVisible(".mk-link-editor.mk-visible")) }
        XCTAssertTrue(cancelled)

        try await fixture.setSelection(inside)
        _ = await waitUntil { await fixture.isVisible(".mk-link-card.mk-visible") }
        _ = try await fixture.evaluate("document.querySelector('.mk-link-card button[aria-label=\"Remove link\"]').click(); true")
        let removed = await waitUntil { fixture.store.documentText == "See Monki now.\n" }
        XCTAssertTrue(removed, fixture.store.documentText)
    }

    // MARK: - The block menu's submenu

    func testTurnIntoFollowsHowItWasOpenedAndRunsOnlyWhatWasChosen() async throws {
        let source = "One\n\nTwo\n"
        let fixture = try await makeFixture(markdown: source)
        try await fixture.setSelection(1)
        fixture.press(.character("/"), modifiers: .command)
        let focused = await waitUntil {
            ((try? await fixture.evaluate("document.activeElement === document.querySelector('.mk-menu.mk-visible[aria-label=\"Block\"] input')")) as? Bool) == true
        }
        XCTAssertTrue(focused, "⌘/ opens the block menu with its search field focused")
        let blockInstant = try await fixture.evaluate("document.querySelector('.mk-menu[aria-label=\"Block\"]').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(blockInstant, false, "A menu the keyboard opens appears at once")

        // → opens Turn Into at once on the current type; ↓↓ then → keeps the highlight where it is.
        fixture.press(.right)
        let submenu = await waitUntil { await fixture.openMenus() == ["Block", "Turn into"] }
        XCTAssertTrue(submenu)
        let submenuInstant = try await fixture.evaluate("document.querySelector('.mk-menu[aria-label=\"Turn into\"]').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(submenuInstant, false, "Turn Into opened by → appears at once")
        fixture.press(.down)
        fixture.press(.down)
        let before = await fixture.highlightedRow(in: "Turn into")
        XCTAssertEqual(before, "Heading 2")
        fixture.press(.right)
        let after = await fixture.highlightedRow(in: "Turn into")
        XCTAssertEqual(after, "Heading 2", "→ in the open submenu leaves its highlight alone")
        fixture.press(.escape)
        fixture.press(.escape)
        let closed = await waitUntil { await fixture.openMenus().isEmpty }
        XCTAssertTrue(closed)

        // From the grip: a hover on Turn into that typing interrupts runs nothing.
        try await fixture.hoverBlock(containing: "Two")
        try await fixture.clickGrip()
        let pointerMenu = await waitUntil { await fixture.openMenus() == ["Block"] }
        XCTAssertTrue(pointerMenu)
        let blockGrown = try await fixture.evaluate("document.querySelector('.mk-menu[aria-label=\"Block\"]').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(blockGrown, true, "A menu the pointer opens grows in")
        _ = try await fixture.evaluate("""
        (() => {
          const menu = document.querySelector('.mk-menu.mk-visible[aria-label="Block"]');
          [...menu.querySelectorAll('.mk-menu-row')].find(r => r.textContent.includes('Turn into')).dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
          const field = menu.querySelector('input');
          field.value = 'dup';
          field.dispatchEvent(new Event('input', { bubbles: true }));
          return true;
        })()
        """)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fixture.store.documentText, source, "Nothing runs that was not chosen")
        let stillFiltering = await fixture.openMenus()
        XCTAssertEqual(stillFiltering, ["Block"])
        _ = try await fixture.evaluate("""
        (() => {
          const field = document.querySelector('.mk-menu.mk-visible[aria-label="Block"] input');
          field.value = '';
          field.dispatchEvent(new Event('input', { bubbles: true }));
          return true;
        })()
        """)

        // A click opens Turn Into grown from its row; crossing another row on the way to it keeps it.
        try await fixture.clickMenuRow("Turn into")
        let clicked = await waitUntil { await fixture.openMenus() == ["Block", "Turn into"] }
        XCTAssertTrue(clicked)
        let submenuGrown = try await fixture.evaluate("document.querySelector('.mk-menu[aria-label=\"Turn into\"]').classList.contains('mk-animate')") as? Bool
        XCTAssertEqual(submenuGrown, true, "Turn Into a click opens grows in")
        try await fixture.moveOverMenuRow("Duplicate")
        _ = try await fixture.evaluate("document.querySelector('.mk-menu[aria-label=\"Turn into\"]').dispatchEvent(new MouseEvent('mouseenter')); true")
        try await Task.sleep(nanoseconds: 300_000_000)
        let kept = await fixture.openMenus()
        XCTAssertEqual(kept, ["Block", "Turn into"], "The submenu stays once the pointer reaches it")
        try await fixture.moveOverMenuRow("Copy")
        let gone = await waitUntil { await fixture.openMenus() == ["Block"] }
        XCTAssertTrue(gone, "Resting on another row closes the submenu")
        XCTAssertEqual(fixture.store.documentText, source)
    }

    // MARK: - Reflow

    func testOpenSurfacesFollowTheColumnWhenItMoves() async throws {
        let source = "Intro text\n\n> [!NOTE]\n> Body\n"
        let fixture = try await makeFixture(markdown: source)

        _ = try await fixture.evaluate("document.querySelector('.callout-title').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); true")
        _ = try await fixture.evaluate("document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); true")
        let callout = await waitUntil { await fixture.openMenus() == ["Callout type"] }
        XCTAssertTrue(callout)
        try await fixture.assertFollowsTheColumn(".mk-menu[aria-label=\"Callout type\"]", "the callout menu")
        fixture.press(.escape)

        try await fixture.setSelection(2)
        fixture.press(.character("/"), modifiers: .command)
        let block = await waitUntil { await fixture.openMenus() == ["Block"] }
        XCTAssertTrue(block)
        try await fixture.assertFollowsTheColumn(".mk-menu[aria-label=\"Block\"]", "the block menu")
        _ = try await fixture.evaluate("document.querySelector('.mk-menu.mk-visible[aria-label=\"Block\"] input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); true")
        _ = await waitUntil { await fixture.openMenus().isEmpty }

        try await fixture.setSelection(0, 5)
        fixture.press(.character("k"), modifiers: .command)
        let editor = await waitUntil { await fixture.isVisible(".mk-link-editor.mk-visible") }
        XCTAssertTrue(editor)
        try await fixture.assertFollowsTheColumn(".mk-link-editor", "the link editor")
    }

    // MARK: - Fixture

    private static func tableLines(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        return text[range.upperBound...].split(separator: "\n").map(String.init).filter { $0.hasPrefix("|") }
    }

    private func makeFixture(markdown: String, timeout: TimeInterval = 10) async throws -> Fixture {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotEditorMenus")
        let file = root.appendingPathComponent("Note.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: file)
        let loaded = await waitUntil(timeout: timeout) {
            !store.isBusy && store.selectedDocument?.displayName == "Note.md" && !store.isDocumentLoading
        }
        XCTAssertTrue(loaded, "Workspace did not load")
        store.testing_stopFileWatcher()

        let harness = MenuTestHarnessModel(store: store)
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // An animated order-front or close parks a GCD worker for good while the screen is locked.
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: MenuTestHarness(model: harness).frame(width: 800, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        hostWindows.append(window)
        let fixture = Fixture(store: store, harness: harness, window: window, host: host, test: self)
        try await fixture.waitForEditor(timeout: timeout)
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
        let harness: MenuTestHarnessModel
        let window: NSWindow
        let host: NSView
        unowned let test: MarkdownEditorMenuTests
        private(set) var webView: WKWebView!

        init(store: WorkspaceStore, harness: MenuTestHarnessModel, window: NSWindow, host: NSView, test: MarkdownEditorMenuTests) {
            self.store = store
            self.harness = harness
            self.window = window
            self.host = host
            self.test = test
        }

        func waitForEditor(timeout: TimeInterval) async throws {
            let ready = await test.waitUntil(timeout: timeout) {
                guard let webView = Self.descendants(of: WKWebView.self, in: self.host).first else { return false }
                let active = (try? await webView.evaluateJavaScript("Boolean(window.MonknotEditor && window.MonknotEditor.isActive() && window.MonknotEditor.source() !== null)")) as? Bool
                guard active == true else { return false }
                self.webView = webView
                return true
            }
            XCTAssertTrue(ready, "The editor did not become active")
            _ = try XCTUnwrap(webView)
        }

        private static func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
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
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        /// The open menus' names, in the page's order.
        func openMenus() async -> [String] {
            ((try? await evaluate("[...document.querySelectorAll('.mk-menu.mk-visible')].map(m => m.getAttribute('aria-label'))")) as? [String]) ?? []
        }

        func isVisible(_ selector: String) async -> Bool {
            ((try? await evaluate("Boolean(document.querySelector(\(Self.literal(selector))))")) as? Bool) == true
        }

        func highlightedRow(in menu: String) async -> String? {
            (try? await evaluate("document.querySelector('.mk-menu.mk-visible[aria-label=\(Self.literal(menu))] .mk-menu-row.mk-selected .mk-row-label')?.textContent ?? null")) as? String
        }

        func clickMenuRow(_ label: String) async throws {
            let found = try await evaluate("""
            (() => {
              const row = [...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.querySelector('.mk-row-label').textContent === \(Self.literal(label)));
              if (!row) return false;
              row.click();
              return true;
            })()
            """) as? Bool
            XCTAssertEqual(found, true, "A visible menu has the row \(label)")
        }

        func moveOverMenuRow(_ label: String) async throws {
            _ = try await evaluate("""
            [...document.querySelectorAll('.mk-menu.mk-visible .mk-menu-row')].find(r => r.querySelector('.mk-row-label').textContent === \(Self.literal(label)))
              .dispatchEvent(new MouseEvent('mousemove', { bubbles: true })); true
            """)
        }

        func clickTableBarMenu(_ label: String) async throws {
            _ = await test.waitUntil { await self.isVisible(".mk-table-bar.mk-visible") }
            let found = try await evaluate("""
            (() => {
              const button = [...document.querySelectorAll('.mk-table-bar .mk-tool-menu')].find(b => b.textContent.trim() === \(Self.literal(label)));
              if (!button) return false;
              button.click();
              return true;
            })()
            """) as? Bool
            XCTAssertEqual(found, true, "The table bar has \(label)")
        }

        /// Moves the pointer over the block holding `text` until its handles show.
        func hoverBlock(containing text: String) async throws {
            _ = try await evaluate("""
            (() => {
              const block = [...document.querySelectorAll('#content > *')].find(e => e.textContent.trim() === \(Self.literal(text)));
              const box = block.getBoundingClientRect();
              document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.left + 10, clientY: box.top + box.height / 2 }));
              return true;
            })()
            """)
            let shown = await test.waitUntil { await self.isVisible(".mk-handles.mk-visible") }
            XCTAssertTrue(shown, "Hovering \(text) shows its handles")
        }

        func clickGrip() async throws {
            _ = try await evaluate("""
            (() => {
              const grip = document.querySelector('.mk-handle-drag');
              const box = grip.getBoundingClientRect();
              grip.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: box.left + 4, clientY: box.top + 4, button: 0 }));
              document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, clientX: box.left + 4, clientY: box.top + 4, button: 0 }));
              return true;
            })()
            """)
        }

        /// Shifts the column sideways, as a pane opening beside it would, and checks the surface
        /// moves with it.
        func assertFollowsTheColumn(_ selector: String, _ name: String) async throws {
            let shift = 90.0
            let start = try await evaluate("parseFloat(document.querySelector(\(Self.literal(selector))).style.left)") as? Double
            _ = try await evaluate("document.getElementById('content').style.transform = 'translateX(\(shift)px)'; window.dispatchEvent(new Event('resize')); true")
            var now: Double?
            let followed = await test.waitUntil {
                now = (try? await self.evaluate("parseFloat(document.querySelector(\(Self.literal(selector))).style.left)")) as? Double
                guard let start, let now else { return false }
                return abs(now - start - shift) <= 1
            }
            XCTAssertTrue(followed, "\(name) follows the column: \(String(describing: start)) → \(String(describing: now))")
            _ = try await evaluate("document.getElementById('content').style.transform = ''; window.dispatchEvent(new Event('resize')); true")
            _ = await test.waitUntil {
                let back = (try? await self.evaluate("parseFloat(document.querySelector(\(Self.literal(selector))).style.left)")) as? Double
                return back == start
            }
        }

        enum Key {
            case `return`
            case backspace
            case escape
            case down
            case right
            case character(String)

            var characters: String {
                switch self {
                case .return: return "\r"
                case .backspace: return "\u{7F}"
                case .escape: return "\u{1B}"
                case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
                case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
                case .character(let value): return value
                }
            }

            var keyCode: UInt16 {
                switch self {
                case .return: return 36
                case .backspace: return 51
                case .escape: return 53
                case .down: return 125
                case .right: return 124
                case .character(let value): return ["k": 40, "/": 44][value] ?? 0
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
            PageKeyboard(window: window, webView: { self.webView }, settle: 0.05)
                .send(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }

        private static func literal(_ text: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
        }
    }
}

@MainActor
private final class MenuTestHarnessModel: ObservableObject {
    let store: WorkspaceStore
    @Published var editorMode = EditorMode.preview
    /// The links the page asked the app to open.
    var linkRequests: [MarkdownPreviewLinkRequest] = []

    init(store: WorkspaceStore) {
        self.store = store
    }
}

/// The editor pane as `ContentView` mounts it, in Preview with no split.
private struct MenuTestHarness: View {
    @ObservedObject var model: MenuTestHarnessModel
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
            theme: .defaultLight,
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
            onMarkdownPreviewLinkRequest: { [model] request in model.linkRequests.append(request) },
            onMarkdownTaskRequest: { _ in }
        )
    }
}
