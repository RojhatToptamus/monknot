import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// A note chosen in the sidebar, with the window's own focus handling. A click, on the note's row or
/// in Recents, opens it and leaves keyboard focus in the tree, so Paste puts an image beside the note
/// instead of into the note (which would save it to an `assets` folder); ⌘↓ gives the note's text
/// the focus, to type in.
@MainActor
final class SidebarDocumentFocusTests: FileOperationsTestCase {
    func testAClickOnANoteKeepsFocusInTheSidebarInSource() async throws {
        try await checkAClickOnANote(in: .source)
    }

    func testAClickOnANoteKeepsFocusInTheSidebarInPreview() async throws {
        try await checkAClickOnANote(in: .preview)
    }

    /// A click in Recents opens the note and gives the tree keyboard focus, as a click on its row does.
    func testAClickInRecentsGivesTheTreeFocus() async throws {
        let root = try makeRoot()
        try write("# A\n", "a.md", in: root)
        try write("# B\n", "docs/b.md", in: root)
        let store = try await openStore(root)
        let h = await harness(store, root)
        defer { h.close() }
        let a = try XCTUnwrap(doc(store, "a.md")).id
        let b = try XCTUnwrap(doc(store, "docs/b.md")).id

        // b.md and then a.md were opened, so Recents lists a.md, then b.md. Recents keeps notes opened
        // after the workspace, not the one it opens with, so the test starts with none open.
        store.selectDocument(id: nil)
        for id in [b, a] {
            XCTAssertTrue(store.selectDocument(id: id))
            let recorded = await wait(timeout: 3) { store.recentDocuments().contains { $0.documentID == id } }
            XCTAssertTrue(recorded)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let tree = try XCTUnwrap(h.treeFrameInWindow())
        await h.click(at: NSPoint(x: tree.midX, y: tree.minY - 16))
        try await Task.sleep(nanoseconds: 400_000_000)
        let rows = h.recentsRowPoints()
        XCTAssertEqual(rows.count, 2, "Recents lists both notes")

        XCTAssertTrue(h.window.makeFirstResponder(nil))
        await h.click(at: try XCTUnwrap(rows.last))
        let opened = await wait { store.selectedDocumentID == b && !store.isBusy }
        XCTAssertTrue(opened)
        XCTAssertEqual(h.openedDocumentFocus.last, .tree)
        XCTAssertTrue(h.window.firstResponder === h.treeDocumentView, "The tree takes focus")
        XCTAssertEqual(store.sidebarTargetFolderURL?.standardizedFileURL.path, root.appendingPathComponent("docs").standardizedFileURL.path)
    }

    private func checkAClickOnANote(in mode: EditorMode) async throws {
        let modeKey = "Monknot.editorMode"
        let previousMode = UserDefaults.standard.object(forKey: modeKey)
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        defer { UserDefaults.standard.set(previousMode, forKey: modeKey) }

        let root = try makeRoot()
        try write("# Note\n\nText.\n", "note.md", in: root)
        try write("# Other\n\nMore text.\n", "docs/other.md", in: root)
        try write("# Third\n\nNever opened.\n", "docs/third.md", in: root)
        let defaultsName = "SidebarDocumentFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = makeWorkspaceStore()
        let host = NSHostingView(rootView: ContentView(
            store: store,
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: WorkspaceLibraryStore(userDefaults: defaults),
            terminationCoordinator: ApplicationTerminationCoordinator(),
            initialLayout: .init(showsSidebar: true, showsTerminal: false)
        ))
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        // The window stands in for the key window, as the app's is, so its focus handling runs.
        let keyWindow = MonknotKeyFocus.window
        MonknotKeyFocus.window = { [weak window] in window }
        window.orderFrontRegardless()
        let pasteboard = makePasteboard()
        defer {
            pasteboard.releaseGlobally()
            MonknotKeyFocus.window = keyWindow
            window.orderOut(nil)
            window.contentView = nil
            UserDefaults.standard.removeObject(forKey: WorkspaceTreeExpansionPersistence().key(for: root))
            WorkspaceTabStatePersistence().remove(for: root)
        }

        store.openWorkspace(root, selecting: root.appendingPathComponent("note.md"))
        let opened = await wait(timeout: 10) { !store.isBusy && store.documentText.hasPrefix("# Note") }
        XCTAssertTrue(opened)
        store.testing_stopFileWatcher()
        var editor: NSView?
        let editorShown = await wait(timeout: 15) {
            editor = Self.editingView(in: host, mode: mode)
            return editor != nil
        }
        XCTAssertTrue(editorShown, "The \(mode.rawValue) editor shows")
        let tree = try XCTUnwrap(Self.sidebarTree(in: host))

        // The folder's row opens it; then the note is being typed in.
        await click(try XCTUnwrap(rowCenter("docs", in: tree, store: store, root: root)), in: window)
        let docsOpen = await wait { self.rowCenter("other.md", in: tree, store: store, root: root) != nil }
        XCTAssertTrue(docsOpen)
        window.makeFirstResponder(try XCTUnwrap(editor))
        XCTAssertTrue(MonknotNativePasteboardCommand.hasNativeEditingFocus)

        // A click on another note's row opens it and leaves focus in the tree, also once the note
        // has loaded and its view has mounted.
        let other = root.appendingPathComponent("docs/other.md").standardizedFileURL.path
        await click(try XCTUnwrap(rowCenter("other.md", in: tree, store: store, root: root)), in: window)
        let switched = await wait(timeout: 10) { store.selectedDocumentID == other && !store.isBusy }
        XCTAssertTrue(switched)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(window.firstResponder === tree, "\(mode.rawValue): focus went to \(String(describing: window.firstResponder))")
        XCTAssertFalse(MonknotNativePasteboardCommand.hasNativeEditingFocus, "⌘V goes to the workspace")
        let target = try XCTUnwrap(store.sidebarTargetFolderURL)
        XCTAssertEqual(target.standardizedFileURL.path, root.appendingPathComponent("docs").standardizedFileURL.path)

        // ↓ selects a note never opened, and ⌘↓ opens it with its text focused, to type in, once it
        // has loaded.
        let third = root.appendingPathComponent("docs/third.md").standardizedFileURL.path
        press("\u{F701}", keyCode: 125, modifiers: [], in: window)
        XCTAssertEqual(store.sidebarSelectionIDs, [third])
        XCTAssertEqual(store.selectedDocumentID, other, "↓ opens nothing")
        press("\u{F701}", keyCode: 125, modifiers: .command, in: window)
        let typing = await wait {
            store.selectedDocumentID == third && store.documentText.hasPrefix("# Third")
                && MonknotNativePasteboardCommand.hasNativeEditingFocus
        }
        XCTAssertTrue(typing, "\(mode.rawValue): ⌘↓ left focus in \(String(describing: window.firstResponder))")

        // What Paste does from the tree: an image copied from elsewhere lands beside the note.
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        XCTAssertTrue(store.pasteFromPasteboard(pasteboard, into: target))
        let pasted = await wait { self.names("docs", in: root).contains("Pasted Image.png") && !store.isBusy }
        XCTAssertTrue(pasted)
        XCTAssertFalse(names("", in: root).contains("assets"))
        XCTAssertFalse(names("docs", in: root).contains("assets"))
        XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "# Other\n\nMore text.\n", "The note is unchanged")
    }

    /// The centre of the row showing `name`, in window coordinates, from the sidebar's row geometry;
    /// nil while no row shows it.
    private func rowCenter(_ name: String, in tree: NSView, store: WorkspaceStore, root: URL) -> NSPoint? {
        let rows = SidebarTreePresentation.visibleNodes(
            from: store.rootNode?.children ?? [],
            expandedFolderIDs: WorkspaceTreeExpansionPersistence().load(for: root) ?? []
        )
        guard let index = rows.firstIndex(where: { $0.displayName == name }) else { return nil }
        let theme = AppTheme.defaultDark
        let rowHeight = MonknotMetrics.scale(MonknotMetrics.rowHeightBase, theme: theme, zoomScale: 1)
        let spacing = MonknotMetrics.scale(MonknotMetrics.rowGapBase, theme: theme, zoomScale: 1)
        let top = MonknotMetrics.scale(MonknotMetrics.listTopInsetBase, theme: theme, zoomScale: 1)
        let y = top + CGFloat(index) * (rowHeight + spacing) + rowHeight / 2
        let local = NSPoint(x: tree.bounds.midX, y: tree.isFlipped ? y : tree.bounds.height - y)
        return tree.convert(local, to: nil)
    }

    private func click(_ point: NSPoint, in window: NSWindow) async {
        var timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            timestamp += 0.016
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            window.sendEvent(event)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
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
    }

    /// Source's text view, or Preview's web view.
    private static func editingView(in view: NSView, mode: EditorMode) -> NSView? {
        switch mode {
        case .source:
            if let textView = view as? NSTextView, textView.isEditable, !textView.isFieldEditor {
                return textView
            }
        case .preview:
            if let webView = view as? WKWebView, webView.identifier == .monknotDocumentFocusTarget, !webView.isLoading {
                return webView
            }
        }
        for subview in view.subviews {
            if let found = editingView(in: subview, mode: mode) {
                return found
            }
        }
        return nil
    }

    /// The sidebar tree's hosting view, which holds keyboard focus while the sidebar has it.
    private static func sidebarTree(in view: NSView) -> NSView? {
        if let scroll = view as? NSScrollView, String(describing: type(of: scroll)).contains("SidebarNativeScrollView") {
            return scroll.documentView
        }
        for subview in view.subviews {
            if let found = sidebarTree(in: subview) {
                return found
            }
        }
        return nil
    }
}
