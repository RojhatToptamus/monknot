import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// A file made with New Markdown or New File opens in a tab of its own and shows in the editor, in a
/// real window: with other tabs open, and after every tab was closed, when the empty tab strip
/// must not keep the new file from opening.
@MainActor
final class NewFileOpensTabTests: FileOperationsTestCase {
    func testNewMarkdownOpensBesideOpenTabs() async throws {
        try await checkNewFileOpens(afterClosingEveryTab: false, named: nil)
    }

    func testNewMarkdownOpensAfterEveryTabWasClosed() async throws {
        try await checkNewFileOpens(afterClosingEveryTab: true, named: nil)
    }

    func testNewFileWithANameOpensAfterEveryTabWasClosed() async throws {
        try await checkNewFileOpens(afterClosingEveryTab: true, named: "Plan")
    }

    private func checkNewFileOpens(afterClosingEveryTab: Bool, named name: String?) async throws {
        let root = try makeRoot()
        try write("# Note\n", "note.md", in: root)
        let persistence = WorkspaceTabStatePersistence()
        if afterClosingEveryTab {
            // What closing the last tab leaves for the workspace.
            persistence.save(WorkspaceTabState(isEmptyByUserChoice: true), for: root)
        }
        let defaultsName = "NewFileOpensTabTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let store = makeWorkspaceStore()
        let host = NSHostingView(rootView: ContentView(
            store: store,
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: WorkspaceLibraryStore(userDefaults: defaults),
            terminationCoordinator: ApplicationTerminationCoordinator(),
            initialLayout: .init(showsSidebar: true, showsTerminal: false)
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            persistence.remove(for: root)
            UserDefaults.standard.removeObject(forKey: WorkspaceTreeExpansionPersistence().key(for: root))
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let note = root.appendingPathComponent("note.md")
        store.openWorkspace(root, selecting: afterClosingEveryTab ? nil : note)
        let opened = await wait(timeout: 10) { !store.isBusy && store.rootNode != nil }
        XCTAssertTrue(opened)
        store.testing_stopFileWatcher()
        if afterClosingEveryTab {
            let empty = await wait { store.selectedDocumentID == nil }
            XCTAssertTrue(empty, "The workspace opens with no tab, as it was left")
        } else {
            let shown = await wait { store.selectedDocument?.url.lastPathComponent == "note.md" }
            XCTAssertTrue(shown)
            let noteTabbed = await wait {
                persistence.load(for: root)?.tabs.contains { $0.documentID == note.standardizedFileURL.path } ?? false
            }
            XCTAssertTrue(noteTabbed, "The note opens in its tab")
        }

        let before = names("", in: root)
        if let name {
            store.createFile(named: name)
        } else {
            store.createMarkdownFile()
        }
        var created: URL?
        let made = await wait {
            guard !store.isBusy, let added = self.names("", in: root).subtracting(before).first else { return false }
            created = root.appendingPathComponent(added)
            return true
        }
        XCTAssertTrue(made, "The file is created")
        let createdID = try XCTUnwrap(created).standardizedFileURL.path

        // It is the open document, and stays so once the window has caught up with it.
        let selected = await wait { store.selectedDocumentID == createdID && !store.isDocumentLoading }
        XCTAssertTrue(selected, "The new file is the open document")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.selectedDocumentID, createdID, "Nothing closes it again")
        XCTAssertEqual(store.documentText, name == nil ? "# \(try XCTUnwrap(created).deletingPathExtension().lastPathComponent)\n\n" : "")

        // And it has a tab: the window's tabs, as it saves them.
        let tabbed = await wait {
            persistence.load(for: root).map { $0.tabs.contains { $0.documentID == createdID } && $0.selectedDocumentID == createdID } ?? false
        }
        XCTAssertTrue(tabbed, "The new file opens in its own tab")
        if !afterClosingEveryTab {
            XCTAssertTrue(persistence.load(for: root)?.tabs.contains { $0.documentID == note.standardizedFileURL.path } ?? false, "The tab that was open stays")
        }
    }
}
