import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp

/// Side panes open and close as one native transition while the document lays out live
/// (design.md §11).
final class WorkspacePaneTransitionTests: WorkspaceSplitViewTestCase {
    func testASidebarHiddenAtLaunchFirstOpensToTheDefaultWidth() {
        let autosaveName = WorkspaceSplitMetrics.autosaveName
        let framesKey = "NSSplitView Subview Frames \(autosaveName)"
        let savedFrames = UserDefaults.standard.object(forKey: framesKey)
        removeSplitAutosaveDefaults(named: autosaveName)
        defer {
            removeSplitAutosaveDefaults(named: autosaveName)
            if let savedFrames {
                UserDefaults.standard.set(savedFrames, forKey: framesKey)
            }
        }
        let recorder = PresentationRecorder()
        let controller = makeController(
            sidebarPresented: false,
            terminalPresented: false,
            autosaveName: autosaveName,
            recorder: recorder
        )
        let window = mount(controller, width: 1_300)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        XCTAssertTrue(controller.splitView.arrangedSubviews[0].isHidden)

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)
        layout(window, controller)

        XCTAssertFalse(controller.splitView.arrangedSubviews[0].isHidden)
        XCTAssertEqual(
            controller.splitView.arrangedSubviews[0].frame.width,
            WorkspaceSplitMetrics.sidebarDefaultWidth,
            accuracy: 1,
            "Not the minimum width AppKit gives a pane it has never laid out"
        )
    }

    func testAnAnimatedRevealAnnouncesWhereTheCardGoesAndStartsNoAnimationsOfItsOwn() async throws {
        let recorder = PresentationRecorder()
        let controller = makeController(sidebarPresented: true, terminalPresented: false, recorder: recorder)
        let window = mount(controller, width: 1_300)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        let openWidth = controller.splitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(openWidth, 0)
        // Closed at once, the sidebar remembers its width; the animated reveal restores it.
        update(controller, sidebarPresented: false, terminalPresented: false, recorder: recorder)
        layout(window, controller)
        XCTAssertTrue(controller.splitView.arrangedSubviews[0].isHidden)
        let closedCard = controller.splitView.arrangedSubviews[1].convert(
            controller.splitView.arrangedSubviews[1].bounds,
            to: nil
        )

        var began: WorkspacePaneTransition?
        var ended: WorkspacePaneTransition?
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: .workspacePaneTransitionWillBegin, object: window, queue: nil) { note in
                began = note.userInfo?[WorkspacePaneTransition.userInfoKey] as? WorkspacePaneTransition
            },
            center.addObserver(forName: .workspacePaneTransitionDidEnd, object: window, queue: nil) { note in
                ended = note.userInfo?[WorkspacePaneTransition.userInfoKey] as? WorkspacePaneTransition
            },
        ]
        defer { observers.forEach(center.removeObserver) }

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder, animated: true)

        let transition = try XCTUnwrap(began, "A web view learns where the card goes before it moves")
        XCTAssertEqual(transition.cardEnd.maxX, transition.cardStart.maxX, accuracy: 0.5, "The trailing edge stays")
        XCTAssertEqual(transition.cardEnd.minX - transition.cardStart.minX, openWidth, accuracy: 1)
        XCTAssertEqual(transition.cardStart.maxX, closedCard.maxX, accuracy: 7, "It starts where the document's card is")
        // AppKit reports the reveal from inside its own animation, where implicit animation is on;
        // frames the split sets there must not animate on their own and drift against the reveal.
        let detail = controller.splitView.arrangedSubviews[1]
        for view in descendants(of: detail) {
            XCTAssertEqual(view.layer?.animationKeys() ?? [], [], "\(type(of: view)) animates on its own")
        }

        let finished = await waitUntil(timeout: 3) { ended != nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(ended?.id, transition.id)
        XCTAssertEqual(controller.splitView.arrangedSubviews[0].frame.width, openWidth, accuracy: 1)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// ContentView keeps its own record of the panes a window asks for: `SceneStorage` restores them
/// with the window but takes no writes outside a scene (a preview, a window a test hosts).
final class ContentViewPanePreferenceTests: WorkspaceStoreTestCase {
    func testTheSidebarToggleMovesTheSplitOutsideAScene() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "Panes")
        let note = root.appendingPathComponent("Note.md")
        try "# Note\n\nA line.\n".write(to: note, atomically: true, encoding: .utf8)
        let defaultsName = "ContentViewPanePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = makeWorkspaceStore()
        let host = NSHostingView(rootView: ContentView(
            store: store,
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: WorkspaceLibraryStore(userDefaults: defaults),
            terminationCoordinator: ApplicationTerminationCoordinator(),
            initialLayout: .init(showsSidebar: true, showsTerminal: false, overlay: .toggleSidebar(at: [0.05, 0.8]))
        ))
        let window = UnconstrainedSplitTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_300, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        store.openWorkspace(root, selecting: note)

        func sidebarHidden() -> Bool? {
            guard let split = firstDescendant(of: WorkspaceNativeSplitView.self, in: host),
                  split.arrangedSubviews.count == 3 else { return nil }
            return split.arrangedSubviews[0].isHidden
        }
        let hid = await waitUntil(timeout: 5) { sidebarHidden() == true }
        XCTAssertTrue(hid, "The first toggle hides the sidebar")
        let showed = await waitUntil(timeout: 5) { sidebarHidden() == false }
        XCTAssertTrue(showed, "The second shows it again")
    }

    private func firstDescendant<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> ViewType? {
        if let match = view as? ViewType {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
