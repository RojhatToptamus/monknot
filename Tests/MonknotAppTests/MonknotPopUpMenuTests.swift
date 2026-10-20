import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// A pop-up's menu (design.md §5.3) clicked open on a real `MonknotPopUpButton`: Monknot's own menu
/// below the button, the current value checked, highlighted and in view, the keys moving and choosing,
/// a long list scrolling under the chrome thumb, previews restored on Esc, and the menu flipping above
/// the button where the screen ends.
@MainActor
final class MonknotPopUpMenuTests: XCTestCase {
    private var controller: MonknotContextMenuController {
        .shared
    }

    private static let zoomItems = [100, 120, 140, 160, 180, 200].map { MonknotPopUpItem(id: String($0), title: "\($0)%") }

    func testAPopUpOpensMonknotsMenuBelowItWithItsValueChecked() async throws {
        let fixture = try makeFixture(items: Self.zoomItems, selection: "140")
        try await fixture.open()

        XCTAssertEqual(controller.openTitles, Self.zoomItems.map(\.title), "The values, as Monknot's menu rather than the system's")
        let model = try XCTUnwrap(controller.openModel)
        XCTAssertEqual(model.entries.map { $0.item?.isChecked == true }, [false, false, true, false, false, false])
        XCTAssertEqual(highlightedTitle, "140%", "The current value opens highlighted")

        let button = fixture.buttonFrameOnScreen
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.minX, button.minX, accuracy: 0.5, "The menu's leading edge is on the button's")
        XCTAssertEqual(surface.maxY, button.minY - 4, accuracy: 0.5, "4 below the button")
        XCTAssertGreaterThanOrEqual(surface.width, max(232, button.width))
        XCTAssertFalse(try XCTUnwrap(controller.openPanel).canBecomeKey, "The menu leaves the window its focus")

        press(125)
        XCTAssertEqual(highlightedTitle, "160%")
        press(36)
        XCTAssertFalse(controller.isOpen)
        let chosen = await waitUntil { fixture.recorder.selection == "160" }
        XCTAssertTrue(chosen, "Return chooses the highlighted value")

        try await fixture.open()
        XCTAssertEqual(controller.openModel?.entries.map { $0.item?.isChecked == true }, [false, false, false, true, false, false], "The new value is checked")
        press(53)
        XCTAssertFalse(controller.isOpen)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.recorder.selection, "160", "Esc chooses nothing")
    }

    func testAValueMissingFromTheListLeavesNothingChecked() async throws {
        let fixture = try makeFixture(items: Self.zoomItems, selection: "")
        try await fixture.open()
        XCTAssertEqual(controller.openModel?.entries.filter { $0.item?.isChecked == true }.count, 0)
        XCTAssertNil(highlightedTitle, "Nothing is highlighted until the pointer or the keys reach a row")
        press(125)
        XCTAssertEqual(highlightedTitle, "100%", "↓ starts at the first value")
        press(53)
    }

    func testALongListScrollsAndKeepsTheRowTheKeysReachInView() async throws {
        let items = (0..<300).map { MonknotPopUpItem(id: "f\($0)", title: String(format: "Family %03d", $0)) }
        let fixture = try makeFixture(items: items, selection: "f250")
        try await fixture.open()

        let model = try XCTUnwrap(controller.openModel)
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.height, 380, accuracy: 0.5, "A pop-up's values scroll past 380, as Preview's menus do")
        XCTAssertEqual(highlightedTitle, "Family 250")
        try assertHighlightInView(model, height: surface.height)
        XCTAssertGreaterThan(model.scrollOffset, 0, "Opened scrolled to its value")
        XCTAssertFalse(model.showsThumb, "The thumb shows only while the rows scroll")

        press(115)
        XCTAssertEqual(highlightedTitle, "Family 000")
        XCTAssertEqual(model.scrollOffset, 0, "Home scrolls to the top")
        XCTAssertTrue(model.showsThumb, "Scrolling shows the thumb")

        press(119)
        XCTAssertEqual(highlightedTitle, "Family 299")
        try assertHighlightInView(model, height: surface.height)
        let layout = MonknotContextMenuLayout(
            entries: model.entries,
            theme: .defaultLight,
            zoomScale: 1,
            minimumWidth: fixture.buttonFrameOnScreen.width,
            maximumHeight: 380
        )
        XCTAssertEqual(model.scrollOffset, layout.maximumScrollOffset, accuracy: 0.5, "End scrolls to the bottom")
        let thumb = try XCTUnwrap(layout.thumbFrame(offset: model.scrollOffset, isHovered: false))
        XCTAssertEqual(thumb.maxY, surface.height - 6, accuracy: 0.5, "At the bottom the thumb's end is 6 clear of the surface's")
        XCTAssertEqual(thumb.width, 4)
        XCTAssertEqual(thumb.midX, surface.width - 4.5, accuracy: 0.01, "Centred in the 9 lane flush with the edge")

        for character in "family 12" {
            press(Self.keyCode(for: character), String(character))
        }
        XCTAssertEqual(highlightedTitle, "Family 120", "Typing reaches a row")
        try assertHighlightInView(model, height: surface.height)

        let hidden = await waitUntil(timeout: 2) { !model.showsThumb }
        XCTAssertTrue(hidden, "The thumb fades once the rows stop")

        press(36)
        let chosen = await waitUntil { fixture.recorder.selection == "f120" }
        XCTAssertTrue(chosen)
    }

    func testPreviewingAPopUpPreviewsWhatTheKeysReachAndRestoresOnEscape() async throws {
        let items = ["harbor", "forge", "meadow"].map { MonknotPopUpItem(id: $0, title: $0.capitalized) }
        let fixture = try makeFixture(items: items, selection: "harbor", previews: true)
        try await fixture.open()
        XCTAssertEqual(fixture.recorder.previews, [], "Opening on the current value previews nothing")
        press(125)
        press(125)
        XCTAssertEqual(fixture.recorder.previews, ["forge", "meadow"])
        press(53)
        XCTAssertEqual(fixture.recorder.cancels, 1, "Esc restores the value the menu opened with")
        XCTAssertEqual(fixture.recorder.selection, "harbor")

        try await fixture.open()
        press(125)
        press(36)
        let chosen = await waitUntil { fixture.recorder.selection == "forge" }
        XCTAssertTrue(chosen)
        XCTAssertEqual(fixture.recorder.cancels, 1, "A chosen value is kept, not cancelled")
    }

    func testTheMenuFlipsAboveTheButtonWhereTheScreenEnds() async throws {
        let fixture = try makeFixture(items: Self.zoomItems, selection: "100", nearScreenBottom: true)
        try await fixture.open()
        let button = fixture.buttonFrameOnScreen
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.minY, button.maxY + 4, accuracy: 0.5, "Above the button, 4 clear")
        XCTAssertEqual(surface.minX, button.minX, accuracy: 0.5)
        press(53)
    }

    func testAMenuThatWouldCrossTheWindowsEdgeEndsOnTheButtonsTrailingEdge() async throws {
        let fixture = try makeFixture(items: Self.zoomItems, selection: "100", windowWidth: 120)
        try await fixture.open()
        let button = fixture.buttonFrameOnScreen
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertLessThan(fixture.window.frame.maxX, button.minX + 232, "The fixture's button sits near the window's edge")
        XCTAssertEqual(surface.maxX, button.maxX, accuracy: 0.5, "Its trailing edge is on the button's")
        XCTAssertEqual(surface.maxY, button.minY - 4, accuracy: 0.5, "Still 4 below the button")
        press(53)
    }

    func testAMenuButtonOpensItsCommandsBelowIt() async throws {
        var undone = 0
        let fixture = try makeFixture(menuCommands: [
            [MonknotPopUpAction(title: "Undo", systemImage: "arrow.uturn.backward") { undone += 1 }],
            [MonknotPopUpAction(title: "Highlight Selection", systemImage: "highlighter") {}],
        ])
        try await fixture.open()
        XCTAssertEqual(controller.openTitles, ["Undo", "-", "Highlight Selection"])
        XCTAssertNil(highlightedTitle, "A command menu opens with nothing highlighted")
        XCTAssertFalse(controller.openModel?.entries.contains { $0.item?.isValue == true } ?? true)
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(surface.maxY, fixture.buttonFrameOnScreen.minY - 4, accuracy: 0.5)
        XCTAssertTrue(controller.chooseForTesting("Undo"))
        let ran = await waitUntil { undone == 1 }
        XCTAssertTrue(ran)
    }

    /// The Text Style popover holds the font pop-up: pressing in the pop-up's menu, which floats in a
    /// window of its own over Monknot's popover, must leave the popover open, the chosen font lands
    /// in it, and Esc closes the menu alone.
    func testAPopUpInsideAPopoverKeepsThePopoverOpenWhileItsMenuIsUsed() async throws {
        let recorder = Recorder(selection: "Helvetica")
        let host = NSHostingView(rootView: PopoverHostView(recorder: recorder))
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let window = PopUpTestWindow(
            contentRect: NSRect(x: visible.midX - 150, y: visible.midY, width: 300, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in
            MonknotContextMenuController.shared.close(animated: false)
            window.orderOut(nil)
            window.contentView = nil
        }

        var popoverWindow: NSWindow?
        let shown = await waitUntil {
            popoverWindow = NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            return popoverWindow != nil
        }
        XCTAssertTrue(shown, "The popover shows")
        let popover = try XCTUnwrap(popoverWindow)
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try XCTUnwrap(popover.contentView)
        let center = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouseEvent(type, at: center, in: popover) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let opened = await waitUntil { self.controller.isOpen }
        XCTAssertTrue(opened, "The font pop-up opens its menu from inside the popover")
        let panel = try XCTUnwrap(controller.openPanel)

        // A press and release inside the menu, delivered as the app delivers it.
        let inside = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouseEvent(type, at: inside, in: panel) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(popover.isVisible, "Using the menu leaves the popover open")

        if !controller.isOpen {
            try await reopen(in: popover, at: center)
        }
        // The press moved the highlight to wherever the real pointer is; End reaches the last font.
        press(119)
        press(36)
        let chosen = await waitUntil { recorder.selection == "Menlo" }
        XCTAssertTrue(chosen, "End and Return choose the last font")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(popover.isVisible, "Choosing a font leaves the popover open")

        // The menu is the topmost surface: Esc, delivered as the app delivers it, closes the menu
        // and leaves the popover open.
        try await reopen(in: popover, at: center)
        XCTAssertTrue(controller.isOpen)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: popover.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(escape)
        let menuClosed = await waitUntil { !self.controller.isOpen }
        XCTAssertTrue(menuClosed, "Esc closes the menu")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(popover.isVisible, "and only the menu")
        XCTAssertEqual(recorder.selection, "Menlo", "Esc chose nothing")
    }

    private func reopen(in window: NSWindow, at point: NSPoint) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouseEvent(type, at: point, in: window) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        _ = await waitUntil { self.controller.isOpen }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private struct PopoverHostView: View {
        @ObservedObject var recorder: Recorder
        @State private var isShown = true

        var body: some View {
            Color.clear
                .frame(width: 300, height: 80)
                .monknotPopover(isPresented: $isShown, label: "Text Style", theme: .defaultLight, zoomScale: 1) {
                    MonknotPopUpButton(
                        label: "Font Family",
                        selection: $recorder.selection,
                        items: ["Avenir", "Helvetica", "Menlo"].map { MonknotPopUpItem(id: $0, title: $0) },
                        theme: .defaultLight,
                        zoomScale: 1
                    )
                    .padding(12)
                }
        }
    }

    // MARK: - Snapshots

    /// With `MONKNOT_POPUP_MENU_SNAPSHOT_DIR` set, renders pop-up menus off screen (no window server, so
    /// it works with the screen locked): the PDF zoom's values, the markup colours with Stroke Width…,
    /// the tools with Add Text Box, and a long font list scrolled with its thumb showing, light and
    /// dark, at zoom 1 and 2.
    func testRenderPopUpMenus() throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_POPUP_MENU_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_POPUP_MENU_SNAPSHOT_DIR to render the pop-up menus")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colours: [(String, String, Color)] = [
            ("yellow", "Yellow", Color(red: 1, green: 0.85, blue: 0.24)),
            ("green", "Green", Color(red: 0.4, green: 0.8, blue: 0.4)),
            ("blue", "Blue", Color(red: 0.35, green: 0.6, blue: 1)),
            ("pink", "Pink", Color(red: 1, green: 0.44, blue: 0.68)),
            ("red", "Red", Color(red: 0.94, green: 0.33, blue: 0.31)),
            ("graphite", "Graphite", Color(red: 0.85, green: 0.87, blue: 0.91)),
        ]
        let menus: [(String, MonknotMenuPresenter, highlight: String?, scrolled: Bool)] = [
            ("zoom", presenter(items: Self.zoomItems, selection: "140"), "160%", false),
            ("colour", presenter(
                items: colours.map { MonknotPopUpItem(id: $0.0, title: $0.1, swatch: $0.2) },
                selection: "blue",
                actions: [MonknotPopUpAction(title: "Stroke Width…") {}]
            ), nil, false),
            ("tool", presenter(
                items: [("select", "Select", "cursorarrow"), ("pen", "Draw", "pencil.tip"), ("eraser", "Erase", "eraser")]
                    .map { MonknotPopUpItem(id: $0.0, title: $0.1, systemImage: $0.2) },
                selection: "pen",
                actions: [MonknotPopUpAction(title: "Add Text Box") {}]
            ), "Erase", false),
            ("fonts", presenter(
                items: NSFontManager.shared.availableFontFamilies.prefix(120).map { MonknotPopUpItem(id: $0, title: $0) },
                selection: NSFontManager.shared.availableFontFamilies.prefix(120).dropFirst(60).first ?? ""
            ), nil, true),
        ]
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            for zoom in [1.0, 2.0] {
                for (name, presenter, highlight, scrolled) in menus {
                    let entries = presenter.makeCoordinator().makeEntries()
                    let model = MonknotContextMenuModel(entries: entries)
                    model.isShown = true
                    let layout = MonknotContextMenuLayout(
                        entries: entries,
                        theme: theme,
                        zoomScale: zoom,
                        minimumWidth: 0,
                        maximumHeight: MonknotMetrics.interfaceDensity(MonknotContextMenuLayout.valueMenuMaximumHeightBase, theme: theme, zoomScale: zoom)
                    )
                    let checked = entries.firstIndex { $0.item?.isChecked == true }
                    model.highlighted = highlight.flatMap { title in entries.firstIndex { $0.item?.title == title } } ?? checked
                    if scrolled, let checked {
                        model.scrollOffset = layout.offset(centering: checked)
                        model.showsThumb = true
                    }
                    let view = MonknotContextMenuSurface(model: model, layout: layout, anchor: .topLeading, theme: theme, zoomScale: zoom)
                        .padding(MonknotContextMenuController.shadowMargin)
                        .background(theme.chromeSurfaceColor)
                        .environment(\.colorScheme, theme.isDark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.cgImage)
                    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("popup-\(name)-\(themeName)-\(Int(zoom))x.png"))
                }
            }
        }
    }

    /// With `MONKNOT_POPUP_MENU_SNAPSHOT_DIR` set, captures on screen a PDF bar's More and zoom (the
    /// real `PDFZoomToolbarGroup` at 270 %, between presets) with each menu open, light and dark, at
    /// zoom 1 and 2, so the two lists can be compared side by side. Needs an awake, unlocked screen.
    func testCaptureThePDFBarsMenus() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_POPUP_MENU_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_POPUP_MENU_SNAPSHOT_DIR to capture the PDF bar's menus")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            for zoom in [1.0, 2.0] {
                for (variant, status) in [("zoom-270", 2.7), ("zoom-140", 1.4)] {
                    let bar = MonknotBar(theme: theme, zoomScale: zoom) {
                        Spacer()
                        MonknotMenuButton(
                            systemImage: "ellipsis",
                            label: "More",
                            theme: theme,
                            zoomScale: zoom,
                            commands: [
                                [
                                    MonknotPopUpAction(title: "Undo", systemImage: "arrow.uturn.backward") {},
                                    MonknotPopUpAction(title: "Redo", systemImage: "arrow.uturn.forward", isEnabled: false) {},
                                ],
                                [MonknotPopUpAction(title: "Highlight Selection", systemImage: "highlighter") {}],
                            ]
                        )
                        PDFZoomToolbarGroup(
                            status: PDFZoomStatus(mode: .fixed(scaleFactor: status), scaleFactor: status, isAvailable: true),
                            theme: theme,
                            zoomScale: zoom,
                            runZoom: { _ in }
                        )
                    }
                    .frame(width: 420 * zoom)
                    .background(theme.surfaceColor)
                    .environment(\.colorScheme, theme.isDark ? .dark : .light)
                    let host = NSHostingView(rootView: bar)
                    host.frame.size = host.fittingSize
                    let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
                    let window = PopUpTestWindow(
                        contentRect: NSRect(x: visible.midX - host.frame.width / 2, y: visible.midY + 200, width: host.frame.width, height: host.frame.height),
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    window.isReleasedWhenClosed = false
                    window.animationBehavior = .none
                    window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    // The zoom pop-up ends the bar, its More button before it.
                    let inset = MonknotMetrics.interfaceDensity(6, theme: theme, zoomScale: zoom)
                    let zoomPoint = NSPoint(x: host.bounds.maxX - inset - MonknotMetrics.interfaceDensity(20, theme: theme, zoomScale: zoom), y: host.bounds.midY)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = mouseEvent(type, at: zoomPoint, in: window) {
                            window.sendEvent(event)
                        }
                        try await Task.sleep(nanoseconds: 30_000_000)
                    }
                    _ = await waitUntil { self.controller.isOpen }
                    try await Task.sleep(nanoseconds: 400_000_000)
                    try capture(window, controller.openPanel, name: "pdfbar-\(variant)-\(themeName)-\(Int(zoom))x", into: directory)
                    controller.close(animated: false)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    window.orderOut(nil)
                    window.contentView = nil
                }
            }
        }
    }

    private func capture(_ window: NSWindow, _ panel: NSPanel?, name: String, into directory: URL) throws {
        let panel = try XCTUnwrap(panel, "\(name): the menu opened")
        let windowImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let panelImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let scale = CGFloat(windowImage.width) / window.frame.width
        let union = window.frame.union(panel.frame).insetBy(dx: -20, dy: -20)
        let size = NSSize(width: union.width * scale, height: union.height * scale)
        let composite = NSImage(size: size)
        composite.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let context = try XCTUnwrap(NSGraphicsContext.current?.cgContext)
        for (image, frame) in [(windowImage, window.frame), (panelImage, panel.frame)] {
            context.draw(image, in: CGRect(
                x: (frame.minX - union.minX) * scale,
                y: (frame.minY - union.minY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            ))
        }
        composite.unlockFocus()
        let tiff = try XCTUnwrap(composite.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Fixture

    @MainActor
    private final class Recorder: ObservableObject {
        @Published var selection: String
        var previews: [String] = []
        var cancels = 0

        init(selection: String) {
            self.selection = selection
        }
    }

    private struct PopUpView: View {
        @ObservedObject var recorder: Recorder
        let items: [MonknotPopUpItem]
        let previews: Bool

        var body: some View {
            MonknotPopUpButton(
                label: "Value",
                selection: $recorder.selection,
                items: items,
                theme: .defaultLight,
                zoomScale: 1,
                previewsSelection: previews,
                onPreviewSelection: { recorder.previews.append($0) },
                onCancelPreview: { recorder.cancels += 1 }
            )
        }
    }

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let host: NSView
        let recorder: Recorder
        let controller: MonknotContextMenuController

        /// The button: the hosting view, which hugs it.
        var buttonFrameOnScreen: NSRect {
            window.convertToScreen(host.convert(host.bounds, to: nil))
        }

        func open() async throws {
            let center = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
            var timestamp = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                timestamp += 0.02
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: center,
                    modifierFlags: [],
                    timestamp: timestamp,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { continue }
                window.sendEvent(event)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let deadline = Date().addingTimeInterval(3)
            while !controller.isOpen, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(controller.isOpen, "Clicking the button opens its menu")
        }
    }

    private func makeFixture(
        items: [MonknotPopUpItem] = [],
        selection: String = "",
        previews: Bool = false,
        menuCommands: [[MonknotPopUpAction]]? = nil,
        nearScreenBottom: Bool = false,
        windowWidth: CGFloat = 400
    ) throws -> Fixture {
        let recorder = Recorder(selection: selection)
        let host: NSView
        if let menuCommands {
            host = NSHostingView(rootView: MonknotMenuButton(
                systemImage: "ellipsis",
                label: "More",
                theme: .defaultLight,
                zoomScale: 1,
                commands: menuCommands
            ))
        } else {
            host = NSHostingView(rootView: PopUpView(recorder: recorder, items: items, previews: previews))
        }
        host.frame.size = host.fittingSize
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let origin = NSPoint(
            x: visible.midX - 100,
            y: nearScreenBottom ? visible.minY + 20 : visible.midY + 100
        )
        let window = PopUpTestWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: windowWidth, height: 80)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let content = NSView(frame: NSRect(origin: .zero, size: CGSize(width: windowWidth, height: 80)))
        host.frame.origin = NSPoint(x: 20, y: 80 - 20 - host.frame.height)
        content.addSubview(host)
        window.contentView = content
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in
            MonknotContextMenuController.shared.close(animated: false)
            window.orderOut(nil)
            window.contentView = nil
        }
        return Fixture(window: window, host: host, recorder: recorder, controller: controller)
    }

    private func presenter(items: [MonknotPopUpItem], selection: String, actions: [MonknotPopUpAction] = []) -> MonknotMenuPresenter {
        MonknotMenuPresenter(
            isPresented: .constant(true),
            selection: .constant(selection),
            items: items,
            actionGroups: [actions],
            theme: .defaultLight,
            zoomScale: 1
        )
    }

    private var highlightedTitle: String? {
        guard let model = controller.openModel, let index = model.highlighted else { return nil }
        return model.entries[index].item?.title
    }

    private func assertHighlightInView(_ model: MonknotContextMenuModel, height: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let index = try XCTUnwrap(model.highlighted, file: file, line: line)
        let layout = MonknotContextMenuLayout(entries: model.entries, theme: .defaultLight, zoomScale: 1, maximumHeight: height)
        let frame = layout.frames[index]
        XCTAssertGreaterThanOrEqual(frame.minY, model.scrollOffset, "The highlighted row is in view", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, model.scrollOffset + height, "The highlighted row is in view", file: file, line: line)
    }

    private func press(_ keyCode: UInt16, _ characters: String = "") {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return XCTFail("Could not make a key event")
        }
        XCTAssertTrue(controller.handleForTesting(event), "An open menu takes every key")
    }

    private static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "f": 3, "i": 34, "l": 37, "m": 46, "y": 16, " ": 49, "1": 18, "2": 19,
        ]
        return codes[character] ?? 0
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

/// A borderless window that answers as the key window, so the button takes its click without the
/// test process becoming the active app.
private final class PopUpTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
