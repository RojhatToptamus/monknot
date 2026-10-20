import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Monknot's own context menu (design.md §5.8), opened by real right-clicks over the real sidebar:
/// what it lists, what choosing does, the keyboard, what closes it, where it goes, and what keeps the
/// system's menu.
@MainActor
final class MonknotContextMenuTests: FileOperationsTestCase {
    private var controller: MonknotContextMenuController {
        .shared
    }

    /// docs/{a.md,b.md}, top.md; docs/a.md selected, its window reporting its appearance.
    private func makeFixture(theme: AppTheme = .defaultDark, zoomScale: Double = 1) async throws -> (URL, WorkspaceStore, SidebarMenuHarness) {
        let root = try makeRoot()
        try write("# a\n", "docs/a.md", in: root)
        try write("# b\n", "docs/b.md", in: root)
        try write("# top\n", "top.md", in: root)
        let store = try await openStore(root, selecting: "docs/a.md")
        let h = SidebarMenuHarness(store: store, root: root, theme: theme)
        await h.waitUntilLaidOut()
        controller.setAppearance(theme: theme, zoomScale: zoomScale, for: h.window)
        addTeardownBlock { @MainActor in
            MonknotContextMenuController.shared.close(animated: false)
            h.close()
        }
        return (root, store, h)
    }

    private func rowIndex(_ h: SidebarMenuHarness, _ relativePath: String) -> Int? {
        h.visibleRowPaths().firstIndex(of: relativePath)
    }

    private func rightClick(_ h: SidebarMenuHarness, at point: NSPoint) -> Bool {
        guard let event = h.rightMouseDown(at: point) else { return false }
        return controller.handleForTesting(event)
    }

    private func mouse(_ type: NSEvent.EventType, _ h: SidebarMenuHarness, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: h.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    private func key(_ keyCode: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func press(_ keyCode: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], in h: SidebarMenuHarness) {
        guard let event = key(keyCode, characters, modifiers: modifiers, window: h.window) else {
            return XCTFail("Could not make a key event")
        }
        XCTAssertTrue(controller.handleForTesting(event), "An open menu takes every key")
    }

    private var highlightedTitle: String? {
        guard let model = controller.openModel, let index = model.highlighted else { return nil }
        return model.entries[index].item?.title
    }

    // MARK: - Opening and choosing

    func testARightClickOnARowOpensMonknotsMenuWithThatRowsItems() async throws {
        let (root, _, h) = try await makeFixture()
        let b = try XCTUnwrap(rowIndex(h, "docs/b.md"))

        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(b))), "The right-click was left to the system's menu")
        XCTAssertEqual(controller.openTitles, SidebarContextMenuTests.fileMenu)
        let panel = try XCTUnwrap(controller.openPanel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey, "The menu must not take focus from the window")
        XCTAssertTrue(h.window.isKeyWindow || !NSApp.isActive, "The window keeps its key status")
        XCTAssertNil(controller.openModel?.highlighted, "A menu opened by the pointer highlights nothing until it is used")

        XCTAssertTrue(controller.chooseForTesting("Copy Path"))
        XCTAssertFalse(controller.isOpen, "Choosing closes the menu")
        let copied = await wait(timeout: 2) { h.copiedPaths.last == root.appendingPathComponent("docs/b.md").standardizedFileURL }
        XCTAssertTrue(copied, "Copy Path acted on \(String(describing: h.copiedPaths.last)), not the right-clicked row")
    }

    /// Where the open menu's row titled `title` is, in the harness window's coordinates.
    private func rowPoint(_ title: String, in h: SidebarMenuHarness) throws -> NSPoint {
        let model = try XCTUnwrap(controller.openModel)
        let index = try XCTUnwrap(model.entries.firstIndex { $0.item?.title == title })
        let frame = MonknotContextMenuLayout(entries: model.entries, theme: .defaultDark, zoomScale: 1).frames[index]
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        return h.window.convertPoint(fromScreen: NSPoint(x: surface.minX + frame.midX, y: surface.maxY - frame.midY))
    }

    private func release(_ h: SidebarMenuHarness, over title: String) throws {
        let event = try XCTUnwrap(mouse(.rightMouseUp, h, at: try rowPoint(title, in: h)))
        XCTAssertTrue(controller.handleForTesting(event), "The release of the press that opened the menu is the menu's")
    }

    /// A right-click whose button comes up over a row at once (a click that drifted as the menu
    /// opened under it) only highlights that row: nothing runs.
    func testAQuickReleaseOverARowOnlyHighlightsIt() async throws {
        let (_, _, h) = try await makeFixture()
        let top = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))
        // Finding rows copies their paths; what counts is what follows.
        let copiedBefore = h.copiedPaths.count
        XCTAssertTrue(rightClick(h, at: top))

        try release(h, over: "Copy Path")
        XCTAssertTrue(controller.isOpen, "A click leaves the menu open")
        XCTAssertEqual(highlightedTitle, "Copy Path")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.copiedPaths.count, copiedBefore, "Nothing ran")
    }

    /// Held, the release chooses the row under it, as in a system menu; but Move to Trash never runs
    /// from the release that opened the menu, however long it was held. It takes a click of its own.
    func testReleasingOverMoveToTrashNeverTrashes() async throws {
        let (root, store, h) = try await makeFixture()
        let top = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))

        for _ in 0..<2 {
            XCTAssertTrue(rightClick(h, at: top))
            try await Task.sleep(nanoseconds: 300_000_000)
            try release(h, over: "Move to Trash")
            XCTAssertTrue(controller.isOpen)
            XCTAssertEqual(highlightedTitle, "Move to Trash")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("top.md").path))
            XCTAssertFalse(store.isBusy)
            controller.close(animated: false)
        }

        XCTAssertTrue(rightClick(h, at: top))
        try await Task.sleep(nanoseconds: 300_000_000)
        try release(h, over: "Copy Path")
        XCTAssertFalse(controller.isOpen, "A held release chooses a row that destroys nothing")
        let copied = await wait(timeout: 2) { h.copiedPaths.last == root.appendingPathComponent("top.md").standardizedFileURL }
        XCTAssertTrue(copied)
    }

    func testAControlClickOpensTheSameMenu() async throws {
        let (_, _, h) = try await makeFixture()
        let row = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))
        let event = try XCTUnwrap(mouse(.leftMouseDown, h, at: row, modifiers: .control))
        XCTAssertTrue(controller.handleForTesting(event))
        XCTAssertEqual(controller.openTitles, SidebarContextMenuTests.fileMenu)
    }

    func testEmptyTreeSpaceOpensTheRootMenu() async throws {
        let (_, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.emptyTreePoint())))
        XCTAssertEqual(controller.openTitles, SidebarContextMenuTests.emptyAreaMenu)
    }

    func testPasteIsDisabledWhileTheClipboardHoldsNothingAndTheKeysSkipIt() async throws {
        let (_, _, h) = try await makeFixture()
        h.pasteboard.clearContents()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.emptyTreePoint())))
        let model = try XCTUnwrap(controller.openModel)
        let paste = try XCTUnwrap(model.entries.firstIndex { $0.item?.title == "Paste" })
        XCTAssertFalse(model.isEnabled(paste))
        XCTAssertFalse(controller.chooseForTesting("Paste"), "A disabled row cannot be chosen")

        press(125, in: h)
        press(125, in: h)
        XCTAssertEqual(highlightedTitle, "New Folder")
        press(125, in: h)
        XCTAssertEqual(highlightedTitle, "Copy Path", "↓ skips the disabled Paste and the separators")
    }

    // MARK: - Keys

    func testTheKeyboardMovesOneHighlightAndChooses() async throws {
        let (root, _, h) = try await makeFixture()
        let b = try XCTUnwrap(rowIndex(h, "docs/b.md"))
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(b))))

        press(125, in: h)
        XCTAssertEqual(highlightedTitle, "New File", "↓ starts at the first row")
        press(126, in: h)
        XCTAssertEqual(highlightedTitle, "New File", "↑ at the first row stays: the highlight does not wrap")
        press(119, in: h)
        XCTAssertEqual(highlightedTitle, "Move to Trash", "End jumps to the last row")
        press(115, in: h)
        XCTAssertEqual(highlightedTitle, "New File", "Home jumps to the first")
        press(45, "n", modifiers: .control, in: h)
        XCTAssertEqual(highlightedTitle, "New Folder", "⌃N moves down, as in Preview's menus")
        press(35, "p", modifiers: .control, in: h)
        XCTAssertEqual(highlightedTitle, "New File", "⌃P moves up")

        press(2, "d", in: h)
        XCTAssertEqual(highlightedTitle, "Duplicate", "Typing highlights the first row that starts with it")

        press(36, "\r", in: h)
        XCTAssertFalse(controller.isOpen)
        let duplicated = await wait(timeout: 3) { self.names("docs", in: root).contains("b copy.md") }
        XCTAssertTrue(duplicated, "↩ chose Duplicate for the right-clicked row: \(names("docs", in: root))")
    }

    func testEscapeClosesWithoutActing() async throws {
        let (root, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))))
        press(119, in: h)
        press(53, in: h)
        XCTAssertFalse(controller.isOpen)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("top.md").path), "Esc must not choose the highlighted Move to Trash")
    }

    // MARK: - What closes it

    func testAClickElsewhereOnlyClosesTheMenu() async throws {
        let (_, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "docs/b.md"))))))
        let opened = h.openedDocumentIDs.count

        let elsewhere = try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "top.md"))))
        let click = try XCTUnwrap(mouse(.leftMouseDown, h, at: elsewhere))
        XCTAssertTrue(controller.handleForTesting(click), "The click that closes a menu does nothing else")
        XCTAssertFalse(controller.isOpen)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.openedDocumentIDs.count, opened, "Closing the menu must not open the file under the click")
    }

    func testARightClickElsewhereOpensThatPlacesMenu() async throws {
        let (_, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(try XCTUnwrap(rowIndex(h, "docs/b.md"))))))
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.emptyTreePoint())))
        XCTAssertEqual(controller.openTitles, SidebarContextMenuTests.emptyAreaMenu, "The second right-click opens the menu where it lands")
    }

    func testScrollingOutsideTheMenuClosesIt() async throws {
        let (_, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.emptyTreePoint())))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        let location = h.window.convertPoint(toScreen: try XCTUnwrap(h.rowCenter(0)))
        scroll.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
        _ = controller.handleForTesting(event)
        XCTAssertFalse(controller.isOpen)
    }

    func testTheWindowLosingKeyStatusClosesIt() async throws {
        let (_, _, h) = try await makeFixture()
        XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.emptyTreePoint())))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
        XCTAssertFalse(controller.isOpen)
    }

    // MARK: - What keeps the system's menu

    func testTextKeepsTheSystemMenu() async throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "Some text"
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        controller.setAppearance(theme: .defaultLight, zoomScale: 1, for: window)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 40, y: 150),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertFalse(controller.handleForTesting(event), "A text view's spelling, Look Up and Services menu must stay the system's")
        XCTAssertFalse(controller.isOpen)
    }

    func testAWindowThatHasNotReportedItsAppearanceKeepsTheSystemMenu() async throws {
        let root = try makeRoot()
        try write("# top\n", "top.md", in: root)
        let store = try await openStore(root)
        let h = await harness(store, root)
        defer { h.close() }
        let event = try XCTUnwrap(h.rightMouseDown(at: try XCTUnwrap(h.rowCenter(0))))
        XCTAssertFalse(controller.handleForTesting(event))
        XCTAssertNotNil(h.contextMenu(row: 0), "SwiftUI's own menu is still there for the system to show")
    }

    // MARK: - Layout and placement

    func testTheMenuIsTheMenuRowOnAFloatingSurface() {
        let entries = SidebarContextMenuTests.fileMenu.map { title -> MonknotContextMenuModel.Entry in
            title == "-" ? .separator : .item(.init(title: title, systemImage: nil, isEnabled: true, isDestructive: false, perform: {}))
        }
        for zoom in WorkspaceZoomPolicy.supportedLevels {
            let theme = AppTheme.defaultLight
            let layout = MonknotContextMenuLayout(entries: entries, theme: theme, zoomScale: zoom)
            let density = { MonknotMetrics.interfaceDensity($0, theme: theme, zoomScale: zoom) }
            XCTAssertEqual(layout.size.width, density(232), accuracy: 0.01, "zoom \(zoom): Preview's narrow menu width")
            let rows = zip(entries, layout.frames).filter { if case .item = $0.0 { return true } else { return false } }.map(\.1)
            for frame in rows {
                XCTAssertEqual(frame.height, density(30), "zoom \(zoom): the 30 menu row")
                XCTAssertEqual(frame.minX, density(6), "zoom \(zoom): inside the 6 list inset")
            }
            XCTAssertEqual(layout.frames[0].minY, density(6))
            XCTAssertEqual(layout.frames[1].minY, layout.frames[0].maxY + 1, "zoom \(zoom): rows 1 apart")
            XCTAssertEqual(layout.frames[2].height, 1 + 2 * density(6), "zoom \(zoom): a separator is the hairline with 6 each side")
            XCTAssertEqual(layout.size.height, (layout.frames.last?.maxY ?? 0) + density(6))
            XCTAssertEqual(layout.entry(at: CGPoint(x: layout.frames[3].midX, y: layout.frames[3].midY)), 3)
            XCTAssertNil(layout.entry(at: CGPoint(x: layout.frames[2].midX, y: layout.frames[2].midY)), "A separator chooses nothing")
        }

        let long = [MonknotContextMenuModel.Entry.item(.init(
            title: String(repeating: "A long command name ", count: 6),
            systemImage: nil,
            isEnabled: true,
            isDestructive: false,
            perform: {}
        ))]
        XCTAssertEqual(MonknotContextMenuLayout(entries: long, theme: .defaultLight, zoomScale: 1).size.width, 320, "A long label widens the menu up to 320")
    }

    func testTheMenuOpensAtThePointerAndFlipsAtTheScreensEdge() async throws {
        let (_, _, h) = try await makeFixture()
        let visible = try XCTUnwrap(h.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        let entries = SidebarContextMenuTests.fileMenu.map { title -> MonknotContextMenuModel.Entry in
            title == "-" ? .separator : .item(.init(title: title, systemImage: nil, isEnabled: true, isDestructive: false, perform: {}))
        }

        let middle = NSPoint(x: visible.midX, y: visible.midY)
        controller.present(entries: entries, at: middle, in: h.window, theme: .defaultLight, zoomScale: 1)
        var surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.minX, middle.x)
        XCTAssertEqual(surface.maxY, middle.y, "The top-left corner sits at the pointer")

        let corner = NSPoint(x: visible.maxX - 10, y: visible.minY + 10)
        controller.present(entries: entries, at: corner, in: h.window, theme: .defaultLight, zoomScale: 1)
        surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.maxX, corner.x, "Flipped left at the screen's right edge")
        XCTAssertGreaterThanOrEqual(surface.minY, visible.minY + 6, "Flipped up, 6 clear of the screen's bottom")
        XCTAssertLessThanOrEqual(surface.maxX, visible.maxX - 6)
        controller.close(animated: false)
        XCTAssertNil(controller.openPanel)
    }

    // MARK: - Commands

    func testEveryCommandHasOneGlyphThatExists() {
        for command in MonknotMenuCommand.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: command.systemImage, accessibilityDescription: nil), "\(command.title): \(command.systemImage)")
        }
        let glyphs = MonknotMenuCommand.allCases.filter { ![.killTerminal].contains($0) }.map(\.systemImage)
        let repeated = Dictionary(grouping: glyphs, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(repeated.isEmpty, "Two commands in one menu share a glyph: \(repeated.sorted())")
        let titles = SidebarContextMenuTests.fileMenu + SidebarContextMenuTests.emptyAreaMenu
        for title in Set(titles) where title != "-" {
            XCTAssertNotNil(MonknotMenuCommand(rawValue: title), "\(title) has no command, so its row would draw without a glyph")
        }
        XCTAssertEqual(MonknotMenuCommand.allCases.filter(\.isDestructive), [.moveToTrash, .killTerminal])
    }

    // MARK: - Snapshots

    /// With `MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR` set, captures the sidebar with a row's menu open, in
    /// light and dark, at zoom 1 and 2, with a row highlighted and with Move to Trash highlighted.
    func testCaptureTheContextMenu() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR to capture the context menu")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            for zoom in [1.0, 2.0] {
                let (_, _, h) = try await makeFixture(theme: theme, zoomScale: zoom)
                let b = try XCTUnwrap(rowIndex(h, "docs/b.md"))
                XCTAssertTrue(rightClick(h, at: try XCTUnwrap(h.rowCenter(b))))
                for (variant, keys) in [("duplicate", [UInt16(2)]), ("trash", [UInt16(119)])] {
                    for keyCode in keys {
                        press(keyCode, keyCode == 2 ? "d" : "", in: h)
                    }
                    try await Task.sleep(nanoseconds: 600_000_000)
                    try capture(h, controller.openPanel, name: "context-\(themeName)-\(Int(zoom))x-\(variant)", into: directory)
                }
                controller.close(animated: false)
                h.close()
            }
        }
    }

    /// With `MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR` set, renders the menu itself off screen (no window
    /// server, so it works with the screen locked): the file row's menu with Duplicate highlighted,
    /// Move to Trash highlighted, a pressed row and a disabled Paste, on the chrome, light and dark, at
    /// zoom 1 and 2.
    func testRenderTheMenuSurface() throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR to render the context menu")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark), ("latte", Self.theme("catppuccin-latte")), ("mocha", Self.theme("catppuccin-mocha"))] {
            for zoom in [1.0, 2.0] {
                for (variant, highlight, pressed) in [("duplicate", "Duplicate", nil as String?), ("trash", "Move to Trash", nil), ("pressed", "Copy", "Copy")] {
                    let entries = SidebarContextMenuTests.fileMenu.map { title -> MonknotContextMenuModel.Entry in
                        guard title != "-" else { return .separator }
                        let command = MonknotMenuCommand(rawValue: title)
                        return .item(.init(
                            title: title,
                            systemImage: command?.systemImage,
                            isEnabled: title != "Paste",
                            isDestructive: command?.isDestructive == true,
                            perform: {}
                        ))
                    }
                    let model = MonknotContextMenuModel(entries: entries)
                    model.isShown = true
                    model.highlighted = entries.firstIndex { $0.item?.title == highlight }
                    model.pressed = pressed.flatMap { title in entries.firstIndex { $0.item?.title == title } }
                    let layout = MonknotContextMenuLayout(entries: entries, theme: theme, zoomScale: zoom)
                    let view = MonknotContextMenuSurface(model: model, layout: layout, anchor: .topLeading, theme: theme, zoomScale: zoom)
                        .padding(MonknotContextMenuController.shadowMargin)
                        .background(theme.chromeSurfaceColor)
                        .environment(\.colorScheme, theme.isDark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.cgImage)
                    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("surface-\(themeName)-\(Int(zoom))x-\(variant).png"))
                }
            }
        }
    }

    private static func theme(_ id: String) -> AppTheme {
        (MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets).first { $0.theme.id == id }?.theme ?? .defaultLight
    }

    private func capture(_ h: SidebarMenuHarness, _ panel: NSPanel?, name: String, into directory: URL) throws {
        let panel = try XCTUnwrap(panel)
        let windowImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(h.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let panelImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let scale = CGFloat(windowImage.width) / h.window.frame.width
        let union = h.window.frame.union(panel.frame)
        let size = NSSize(width: union.width * scale, height: union.height * scale)
        let composite = NSImage(size: size)
        composite.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let context = try XCTUnwrap(NSGraphicsContext.current?.cgContext)
        func draw(_ image: CGImage, _ frame: NSRect) {
            context.draw(image, in: CGRect(
                x: (frame.minX - union.minX) * scale,
                y: (frame.minY - union.minY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            ))
        }
        draw(windowImage, h.window.frame)
        draw(panelImage, panel.frame)
        composite.unlockFocus()
        let tiff = try XCTUnwrap(composite.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
