import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Moving files in the sidebar (design.md §10.4), driven by real mouse and key events over the real
/// sidebar: the copy that rides under the pointer, Esc, a drop on no target, Option, spring-loading
/// and auto-scroll.
@MainActor
final class SidebarDragTests: FileOperationsTestCase {
    /// docs/{a.md,b.md}, other/ (closed), top.md, plus `extraFiles` at the root.
    private func makeFixture(extraFiles: Int = 0, expandDocs: Bool = true) async throws -> (URL, WorkspaceStore, SidebarMenuHarness) {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        try write("# b\n", "docs/b.md", in: root)
        try write("# o\n", "other/inner/deep.md", in: root)
        try write("# o\n", "other/o.md", in: root)
        try write("# top\n", "top.md", in: root)
        for index in 0..<extraFiles {
            try write("# \(index)\n", String(format: "z%02d.md", index), in: root)
        }
        let store = try await openStore(root, selecting: expandDocs ? "docs/a.md" : nil)
        let h = await harness(store, root)
        addTeardownBlock { @MainActor in
            MonknotContextMenuController.shared.close(animated: false)
            h.close()
        }
        return (root, store, h)
    }

    private func rowCenter(_ h: SidebarMenuHarness, _ relativePath: String) throws -> NSPoint {
        let index = try XCTUnwrap(h.visibleRowPaths(maxRows: 40).firstIndex(of: relativePath), "\(relativePath) is not a row: \(h.visibleRowPaths(maxRows: 40))")
        return try XCTUnwrap(h.rowCenter(index))
    }

    private var timestamp = ProcessInfo.processInfo.systemUptime

    private func send(_ type: NSEvent.EventType, _ h: SidebarMenuHarness, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        timestamp += 0.016
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: h.window.windowNumber,
            context: nil,
            eventNumber: Int(timestamp * 1000) % 100_000,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        h.window.sendEvent(event)
    }

    /// Mouse down at `start` and twelve steps to `end`, the button still down.
    private func press(_ h: SidebarMenuHarness, from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
        timestamp = max(timestamp, ProcessInfo.processInfo.systemUptime)
        send(.leftMouseDown, h, at: start, modifiers: modifiers)
        try? await Task.sleep(nanoseconds: 30_000_000)
        for step in 1...12 {
            let fraction = CGFloat(step) / 12
            send(.leftMouseDragged, h, at: NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction), modifiers: modifiers)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// The copy of the row riding under the pointer: a panel that takes no clicks, above the window.
    private func dragCopy(of h: SidebarMenuHarness) -> NSWindow? {
        h.window.childWindows?.first { $0 is MonknotContextMenuPanel && $0.ignoresMouseEvents && $0.isVisible && $0.alphaValue > 0 }
    }

    // MARK: - The drag

    /// The drop moves what the drag picked up, even when the tree changes under it: a compact row
    /// (pack/inner) that splits because another app added a file to its outer folder still drops
    /// the inner folder, never the outer one with everything in it.
    func testADropMovesWhatTheDragPickedUpWhenTheTreeChangesUnderIt() async throws {
        let (root, store, h) = try await makeFixture()
        try write("# x\n", "pack/inner/x.md", in: root)
        store.refresh()
        _ = await wait { self.doc(store, "pack/inner/x.md") != nil && !store.isBusy }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = try rowCenter(h, "pack/inner")
        let target = try rowCenter(h, "docs")

        await press(h, from: start, to: target)
        try write("# new\n", "pack/new.md", in: root)
        store.refresh()
        _ = await wait { self.doc(store, "pack/new.md") != nil && !store.isBusy }
        send(.leftMouseDragged, h, at: target)
        try? await Task.sleep(nanoseconds: 60_000_000)
        send(.leftMouseUp, h, at: target)
        await settle(store)

        XCTAssertEqual(names("pack", in: root), ["new.md"], "The outer folder and its new file stay")
        XCTAssertEqual(names("docs", in: root), ["a.md", "b.md", "inner"])
        XCTAssertEqual(names("docs/inner", in: root), ["x.md"])
    }

    func testTheRowLiftsACopyThatLandsAndTheDestinationOpensWithoutOpeningTheFile() async throws {
        let (root, store, h) = try await makeFixture()
        let selectedBefore = store.selectedDocumentID
        let source = try rowCenter(h, "top.md")
        let target = try rowCenter(h, "other")

        await press(h, from: source, to: target)
        XCTAssertNotNil(dragCopy(of: h), "A copy of the row rides under the pointer while it drags")
        send(.leftMouseUp, h, at: target)

        let moved = await wait { self.names("other", in: root).contains("top.md") }
        XCTAssertTrue(moved, "\(names("other", in: root))")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(dragCopy(of: h), "The copy is gone once the drop lands")
        let shown = await wait(timeout: 3) { h.visibleRowPaths(maxRows: 40).contains("other/top.md") }
        XCTAssertTrue(shown, "The destination opens to show what landed: \(h.visibleRowPaths(maxRows: 40))")
        XCTAssertEqual(store.selectedDocumentID, selectedBefore, "Moving a file never opens it")
    }

    func testEscapeCancelsTheDragAndTheReleaseDoesNothing() async throws {
        let (root, _, h) = try await makeFixture()
        let source = try rowCenter(h, "top.md")
        let target = try rowCenter(h, "other")

        await press(h, from: source, to: target)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(escape)
        // The button is still down: dragging on after the copy has glided back starts nothing.
        try await Task.sleep(nanoseconds: 400_000_000)
        send(.leftMouseDragged, h, at: NSPoint(x: target.x, y: target.y + 2))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(dragCopy(of: h), "The rest of a press Esc cancelled drags nothing")
        send(.leftMouseUp, h, at: target)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(names("", in: root).contains("top.md"), "Esc leaves the file where it was")
        XCTAssertFalse(names("other", in: root).contains("top.md"))
        XCTAssertNil(dragCopy(of: h), "The copy glides back and goes")
    }

    func testADropOnNoTargetChangesNothing() async throws {
        let (root, _, h) = try await makeFixture()
        let source = try rowCenter(h, "docs/b.md")
        // Its own folder's other file: the drop would change nothing.
        let ownFolder = try rowCenter(h, "docs/a.md")
        await press(h, from: source, to: ownFolder)
        send(.leftMouseUp, h, at: ownFolder)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(names("docs", in: root), ["a.md", "b.md"])
        XCTAssertNil(dragCopy(of: h))
    }

    func testOptionCopiesEvenIntoTheFolderItIsIn() async throws {
        let (root, _, h) = try await makeFixture()
        let source = try rowCenter(h, "docs/b.md")
        let ownFolder = try rowCenter(h, "docs/a.md")
        await press(h, from: source, to: ownFolder, modifiers: .option)
        send(.leftMouseUp, h, at: ownFolder, modifiers: .option)
        let copied = await wait { self.names("docs", in: root).contains("b copy.md") }
        XCTAssertTrue(copied, "Option duplicates the item where it is dropped, as Finder does: \(names("docs", in: root))")
        XCTAssertTrue(names("docs", in: root).contains("b.md"), "Copying leaves the original")
    }

    func testLettingGoOfOptionBeforeTheDropMovesAgain() async throws {
        let (root, _, h) = try await makeFixture()
        let source = try rowCenter(h, "top.md")
        let target = try rowCenter(h, "docs")
        await press(h, from: source, to: target, modifiers: .option)
        send(.leftMouseDragged, h, at: NSPoint(x: target.x, y: target.y + 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        send(.leftMouseUp, h, at: target)
        let moved = await wait { self.names("docs", in: root).contains("top.md") }
        XCTAssertTrue(moved)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(names("", in: root).contains("top.md"), "Option was let go before the drop, so it moves: \(names("", in: root))")
    }

    func testAClosedFolderSpringsOpenUnderARestingPointerAndClosesWhenTheDropGoesElsewhere() async throws {
        let (root, _, h) = try await makeFixture()
        let source = try rowCenter(h, "top.md")
        let other = try rowCenter(h, "other")
        XCTAssertFalse(h.visibleRowPaths(maxRows: 40).contains("other/o.md"))

        await press(h, from: source, to: other)
        let delay = SidebarDragSession.springLoadingDelay ?? 0.5
        try await Task.sleep(nanoseconds: UInt64((delay + 0.4) * 1_000_000_000))
        XCTAssertTrue(h.visibleRowPaths(maxRows: 40).contains("other/o.md"), "Resting on a closed folder opens it: \(h.visibleRowPaths(maxRows: 40))")

        // Dropped back on the folder it came from (the root): it stays, and the folder closes again.
        let docs = try rowCenter(h, "docs")
        for step in 1...6 {
            let fraction = CGFloat(step) / 6
            send(.leftMouseDragged, h, at: NSPoint(x: other.x, y: other.y + (docs.y - other.y) * fraction))
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        send(.leftMouseUp, h, at: docs)
        let movedIntoDocs = await wait { self.names("docs", in: root).contains("top.md") }
        XCTAssertTrue(movedIntoDocs)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(h.visibleRowPaths(maxRows: 40).contains("other/o.md"), "A folder the drag opened closes when the drop lands elsewhere")
    }

    func testTheListScrollsNearItsBottomEdge() async throws {
        let (_, _, h) = try await makeFixture(extraFiles: 40)
        let scroll = try XCTUnwrap(h.treeDocumentView?.enclosingScrollView)
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
        let source = try rowCenter(h, "top.md")
        let nearBottom = NSPoint(x: source.x, y: visible.minY + 6)
        await press(h, from: source, to: nearBottom)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 40, "Held near the bottom edge, the tree scrolls")
        send(.leftMouseUp, h, at: nearBottom)
    }

    // MARK: - Captures

    /// With `MONKNOT_SIDEBAR_DRAG_SNAPSHOT_DIR` set, renders the copy off screen, and captures the
    /// sidebar mid-drag (needs an awake, unlocked screen): over a folder's contents, over a closed
    /// folder once it has sprung open, over the root, with Option, and just after landing.
    func testCaptureTheDragStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_SIDEBAR_DRAG_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_SIDEBAR_DRAG_SNAPSHOT_DIR to capture the drag")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            let chip = SidebarDragChip(title: "Roadmap.md", systemImage: "doc.text", theme: theme, zoomScale: 1)
                .padding(SidebarDragSession.shadowMargin)
                .background(theme.chromeSurfaceColor)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
            let renderer = ImageRenderer(content: chip)
            renderer.scale = 2
            if let image = renderer.cgImage {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("chip-\(name).png"))
            }
        }

        let (_, _, h) = try await makeFixture()
        let source = try rowCenter(h, "top.md")
        let insideDocs = try rowCenter(h, "docs/b.md")
        await press(h, from: source, to: insideDocs)
        try await Task.sleep(nanoseconds: 500_000_000)
        try capture(h, name: "drag-1-over-folder", into: directory)

        let other = try rowCenter(h, "other")
        send(.leftMouseDragged, h, at: other)
        try await Task.sleep(nanoseconds: UInt64(((SidebarDragSession.springLoadingDelay ?? 0.5) + 0.5) * 1_000_000_000))
        try capture(h, name: "drag-2-sprung-open", into: directory)

        send(.leftMouseDragged, h, at: try rowCenter(h, "other"), modifiers: .option)
        try await Task.sleep(nanoseconds: 400_000_000)
        try capture(h, name: "drag-3-option", into: directory)
        send(.leftMouseUp, h, at: try rowCenter(h, "other"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try capture(h, name: "drag-4-landed", into: directory)
    }

    private func capture(_ h: SidebarMenuHarness, name: String, into directory: URL) throws {
        let windows = [h.window] + (h.window.childWindows ?? []).filter(\.isVisible)
        let union = windows.map(\.frame).reduce(h.window.frame) { $0.union($1) }
        guard let first = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(h.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
        let scale = CGFloat(first.width) / h.window.frame.width
        let size = NSSize(width: union.width * scale, height: union.height * scale)
        let composite = NSImage(size: size)
        composite.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for window in windows {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { continue }
            NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(
                x: (window.frame.minX - union.minX) * scale,
                y: (window.frame.minY - union.minY) * scale,
                width: window.frame.width * scale,
                height: window.frame.height * scale
            ))
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation else { return }
        try NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Rules

    func testAFileDropThatWouldChangeNothingIsRefused() {
        let docs = URL(fileURLWithPath: "/w/docs", isDirectory: true)
        XCTAssertTrue(SidebarFileDrop.changesNothing([URL(fileURLWithPath: "/w/docs/a.md")], destinationURL: docs), "Into the folder it is in")
        XCTAssertTrue(SidebarFileDrop.changesNothing([docs], destinationURL: docs), "Onto itself")
        XCTAssertTrue(SidebarFileDrop.changesNothing([docs], destinationURL: URL(fileURLWithPath: "/w/docs/sub")), "Into a folder inside it")
        XCTAssertFalse(SidebarFileDrop.changesNothing([URL(fileURLWithPath: "/w/docs/a.md")], destinationURL: URL(fileURLWithPath: "/w/other")))
        XCTAssertFalse(SidebarFileDrop.changesNothing([URL(fileURLWithPath: "/w/docs/a.md"), URL(fileURLWithPath: "/w/top.md")], destinationURL: docs), "One of them moves")
        XCTAssertFalse(SidebarFileDrop.changesNothing([], destinationURL: docs))
    }

    func testTheCopyIsTheRowOnTheFloatingSurface() throws {
        for zoom in [1.0, 2.0] {
            let theme = AppTheme.defaultLight
            let hosting = NSHostingView(rootView: SidebarDragChip(title: "Roadmap.md", systemImage: "doc.text", theme: theme, zoomScale: zoom))
            let size = hosting.fittingSize
            XCTAssertEqual(size.height, MonknotMetrics.scale(28, theme: theme, zoomScale: zoom), "zoom \(zoom): the 28 row")
            let long = NSHostingView(rootView: SidebarDragChip(title: String(repeating: "A long file name ", count: 8), systemImage: "doc.text", theme: theme, zoomScale: zoom))
            XCTAssertLessThanOrEqual(long.fittingSize.width, MonknotMetrics.interfaceDensity(240, theme: theme, zoomScale: zoom) + 0.5, "zoom \(zoom): at most 240 wide")
        }
    }
}
