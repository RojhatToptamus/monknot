import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp

/// How a document snapshot is cut while a side pane opens or closes (design.md §10.0).
final class WorkspaceTransitionCoverBandsTests: XCTestCase {
    private let background: UInt32 = 0xFF_F5_F1_EF
    private let ink: UInt32 = 0xFF_40_3A_33

    /// A 4-byte-per-pixel bitmap of `width` × `height`, background everywhere except `inked` columns
    /// (in every row, or only in `rows`).
    private func bitmap(width: Int, height: Int = 12, inked: [(columns: Range<Int>, rows: Range<Int>?)]) -> [UInt32] {
        var pixels = [UInt32](repeating: background, count: width * height)
        for stroke in inked {
            for y in stroke.rows ?? 0..<height {
                for x in stroke.columns {
                    pixels[y * width + x] = ink
                }
            }
        }
        return pixels
    }

    private func detect(
        _ pixels: [UInt32],
        width: Int,
        height: Int = 12,
        padding: Int = 4,
        chrome: Int? = nil
    ) -> WorkspaceTransitionCoverBands {
        pixels.withUnsafeBytes { buffer in
            WorkspaceTransitionCoverBands.detect(
                pixels: buffer.baseAddress!,
                width: width,
                height: height,
                bytesPerRow: width * 4,
                background: background,
                paddingPixels: padding,
                trailingChromeStart: chrome
            )
        }
    }

    private func isBackground(column x: Int, in pixels: [UInt32], width: Int, height: Int = 12) -> Bool {
        (0..<height).allSatisfy { pixels[$0 * width + x] == background }
    }

    func testAWideDocumentKeepsItsColumnApartFromTheChromeOnItsEdge() {
        // A text column, then a wide margin, then a rail and a scroll thumb against the edge.
        let pixels = bitmap(width: 200, inked: [
            (40..<150, nil),
            (180..<190, 2..<10),
            (196..<198, 3..<6),
        ])

        let bands = detect(pixels, width: 200)

        XCTAssertEqual(bands.centreStart, 36, "The centre band starts a padding before the text")
        XCTAssertEqual(bands.centreEnd, 154, "and ends a padding after its last ink")
        XCTAssertEqual(bands.trailingStart, 164, "The chrome's band starts in the margin, past the column's mirror")
        XCTAssertTrue(isBackground(column: bands.trailingStart, in: pixels, width: 200))
    }

    func testMarkedChromeStartsTheTrailingBandEvenWhenTheTextComesClose() {
        // A narrow card: the text's ragged end reaches into the rail's frame, whose marks hug the
        // edge. The marker starts at 166; the text ends at 170 and the rail's marks start at 176.
        let pixels = bitmap(width: 200, inked: [
            (20..<170, nil),
            (176..<190, nil),
            (196..<198, 3..<6),
        ])

        let unmarked = detect(pixels, width: 200)
        XCTAssertEqual(unmarked.trailingStart, 190, "Without a marker the rail glides with the column")

        let bands = detect(pixels, width: 200, chrome: 166)
        XCTAssertEqual(bands.trailingStart, 170, "The background column nearest the marker, past the text")
        XCTAssertEqual(bands.centreEnd, 170)
        XCTAssertTrue(isBackground(column: bands.trailingStart, in: pixels, width: 200))
    }

    func testAMarkerOverInkWithNoBackgroundNearItFallsBackToTheMirror() {
        // A floating panel covers the text up to the edge's chrome: no clean cut near the marker.
        let pixels = bitmap(width: 200, inked: [(30..<196, nil)])

        let bands = detect(pixels, width: 200, chrome: 120)

        XCTAssertEqual(bands, WorkspaceTransitionCoverBands(centreStart: 26, centreEnd: 196, trailingStart: 196))
    }

    func testABlankSnapshotGlidesWhole() {
        let pixels = bitmap(width: 120, inked: [])

        XCTAssertEqual(detect(pixels, width: 120), .whole(width: 120))
    }

    func testInkAcrossTheWholeWidthGlidesWhole() {
        // A banner across the top leaves no background column anywhere.
        let pixels = bitmap(width: 120, inked: [(0..<120, 0..<2), (30..<90, nil)])

        let bands = detect(pixels, width: 120)

        XCTAssertEqual(bands.centreStart, 0)
        XCTAssertEqual(bands.centreEnd, 120)
        XCTAssertEqual(bands.trailingStart, 120)
    }

    func testAntialiasedBackgroundCountsAsBackgroundAndFaintInkAsInk() {
        var pixels = bitmap(width: 100, inked: [(30..<60, nil)])
        pixels[5 * 100 + 5] = background &- 0x00_00_00_02
        pixels[5 * 100 + 10] = background &- 0x00_00_00_08

        let bands = detect(pixels, width: 100)

        XCTAssertEqual(bands.centreStart, 6, "2 off the background at x 5 is background; 8 off at x 10 is the first ink")
    }

    func testEveryCutIsABackgroundColumn() {
        // Columns and chrome at many offsets: a cut never passes through ink.
        for start in stride(from: 4, to: 60, by: 7) {
            for gap in [2, 6, 12, 30] {
                let end = 150 - start / 2
                let chrome = min(193, end + gap)
                let pixels = bitmap(width: 200, inked: [
                    (start..<end, nil),
                    (chrome..<min(200, chrome + 5), 1..<9),
                ])
                for marker in [nil, chrome - 3, chrome + 1] as [Int?] {
                    let bands = detect(pixels, width: 200, chrome: marker)
                    XCTAssertLessThanOrEqual(bands.centreStart, start)
                    XCTAssertLessThanOrEqual(bands.centreEnd, bands.trailingStart)
                    if bands.trailingStart < 200 {
                        XCTAssertTrue(
                            isBackground(column: bands.trailingStart, in: pixels, width: 200),
                            "start \(start) gap \(gap) marker \(String(describing: marker)) cut \(bands.trailingStart)"
                        )
                    }
                }
            }
        }
    }
}

/// Side panes open and close as one native transition while the document lays out once
/// (design.md §10.0).
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

    func testAnAnimatedRevealCoversTheDocumentAndStartsNoAnimationsOfItsOwn() async throws {
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

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder, animated: true)

        let detail = controller.splitView.arrangedSubviews[1]
        XCTAssertNotNil(
            firstDescendant(of: WorkspaceTransitionCoverView.self, in: detail),
            "The document lies under a snapshot while the pane moves"
        )
        // AppKit reports the reveal from inside its own animation, where implicit animation is on;
        // frames the split sets there must not animate on their own and drift against the reveal.
        for view in descendants(of: detail) {
            XCTAssertEqual(view.layer?.animationKeys() ?? [], [], "\(type(of: view)) animates on its own")
        }

        let uncovered = await waitUntil(timeout: 3) {
            self.firstDescendant(of: WorkspaceTransitionCoverView.self, in: detail) == nil
        }
        XCTAssertTrue(uncovered, "The cover fades out once the pane has moved")
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
