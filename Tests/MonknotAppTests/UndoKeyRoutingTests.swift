import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// ⌘Z pressed in a real window, through the window's own key handling (`ContentView.handleKeyDown`)
/// with real keyboard focus: the editor's text keeps ⌘Z even with nothing left to undo, an older
/// workspace Replace never runs past a newer move, and the sidebar undoes the move first.
@MainActor
final class UndoKeyRoutingTests: FileOperationsTestCase {
    func testCommandZInSourceWithNothingToUndoLeavesAnOlderReplaceAndTheMoveAlone() async throws {
        try await checkCommandZ(in: .source)
    }

    func testCommandZInPreviewWithNothingToUndoLeavesAnOlderReplaceAndTheMoveAlone() async throws {
        try await checkCommandZ(in: .preview)
    }

    private func checkCommandZ(in mode: EditorMode) async throws {
        let modeKey = "Monknot.editorMode"
        let previousMode = UserDefaults.standard.object(forKey: modeKey)
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        defer { UserDefaults.standard.set(previousMode, forKey: modeKey) }

        let root = try makeRoot()
        try write("# Note\n", "note.md", in: root)
        try write("alpha beta\n", "a.md", in: root)
        try write("# other\n", "other.md", in: root)
        try mkdir("Archive", in: root)
        let defaultsName = "UndoKeyRoutingTests.\(UUID().uuidString)"
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
        let window = KeyRoutingTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        // The window stands in for the key window: its key handling runs and the Edit menu reads
        // its focus, without taking the active app away from whatever is in front.
        let keyWindow = MonknotKeyFocus.window
        MonknotKeyFocus.window = { [weak window] in window }
        window.orderFrontRegardless()
        defer {
            MonknotKeyFocus.window = keyWindow
            window.orderOut(nil)
            window.contentView = nil
            UserDefaults.standard.removeObject(forKey: WorkspaceTreeExpansionPersistence().key(for: root))
        }

        let note = root.appendingPathComponent("note.md")
        store.openWorkspace(root, selecting: note)
        let opened = await wait(timeout: 10) { !store.isBusy && store.documentText == "# Note\n" }
        XCTAssertTrue(opened)
        store.testing_stopFileWatcher()

        store.replaceInWorkspace(find: "beta", replacement: "gamma")
        _ = await wait { !store.isBusy && store.canUndoWorkspaceReplace }
        store.moveItem(id: root.appendingPathComponent("other.md").standardizedFileURL.path, toDirectory: root.appendingPathComponent("Archive"))
        await settle(store)
        XCTAssertTrue(store.canUndoWorkspaceReplace, "The move leaves the Replace's note alone")
        XCTAssertTrue(store.fileOperationUndo.undoPrecedesWorkspaceReplace)

        var editor: NSView?
        let editorShown = await wait(timeout: 15) {
            editor = Self.editingView(in: host, mode: mode)
            return editor != nil
        }
        XCTAssertTrue(editorShown, "The \(mode.rawValue) editor shows")
        let editingView = try XCTUnwrap(editor)
        window.makeFirstResponder(editingView)
        _ = await wait { MonknotNativePasteboardCommand.hasNativeEditingFocus }
        XCTAssertTrue(MonknotNativePasteboardCommand.hasNativeEditingFocus)
        XCTAssertFalse(MonknotNativeUndoCommand.canUndo, "The text has nothing to undo")

        pressCommandZ(in: window)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "alpha gamma\n", "The older Replace waits for the newer move")
        XCTAssertTrue(names("Archive", in: root).contains("other.md"), "Typing's ⌘Z never moves a file")

        // From the sidebar, ⌘Z undoes the move.
        let tree = try XCTUnwrap(Self.sidebarTree(in: host))
        window.makeFirstResponder(tree)
        pressCommandZ(in: window)
        let moveUndone = await wait { self.names("", in: root).contains("other.md") && !store.isBusy }
        XCTAssertTrue(moveUndone)

        // With the move undone, the Replace is next, from the text too.
        window.makeFirstResponder(editingView)
        pressCommandZ(in: window)
        let replaceUndone = await wait {
            (try? String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8)) == "alpha beta\n"
        }
        XCTAssertTrue(replaceUndone)
    }

    private func pressCommandZ(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: 6
            ) else { continue }
            NSApp.sendEvent(event)
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

    /// The sidebar tree's hosting view, which takes keyboard focus when the tree is clicked.
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

/// A window that answers as the key window, as the window's key handling asks.
private final class KeyRoutingTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
