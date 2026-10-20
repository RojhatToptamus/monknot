import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Monknot's popover surface (design.md §5.9), opened by real clicks on real controls: where it goes,
/// that it takes keyboard focus and gives it back, what closes it, that the controls inside it still
/// work and VoiceOver can reach them, and the real workspace switcher on it.
@MainActor
final class MonknotPopoverTests: FileOperationsTestCase {
    private var controller: MonknotPopoverController {
        .shared
    }

    override func tearDown() async throws {
        controller.close(animated: false, restoresFocus: false)
        try await super.tearDown()
    }

    // MARK: - A probe: a control, a popover with a button and a slider, and a second button

    @MainActor
    final class ProbeState: ObservableObject {
        @Published var isPresented = false
        @Published var showsControl = true
        @Published var actions = 0
        @Published var value: Double = 3
        @Published var otherActions = 0
        @Published var extraRows = 0
    }

    private struct Probe: View {
        @ObservedObject var state: ProbeState
        let contentKind: MonknotPopoverContentKind
        let theme: AppTheme
        let zoomScale: Double

        var body: some View {
            HStack(spacing: 20) {
                if state.showsControl {
                    MonknotIconButton(
                        systemImage: "textformat",
                        label: "Probe Control",
                        theme: theme,
                        zoomScale: zoomScale,
                        isOpen: state.isPresented
                    ) {
                        state.isPresented.toggle()
                    }
                    .monknotPopover(
                        isPresented: $state.isPresented,
                        label: "Probe",
                        contentKind: contentKind,
                        theme: theme,
                        zoomScale: zoomScale
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Act") { state.actions += 1 }
                            ForEach(0..<state.extraRows, id: \.self) { row in
                                Text("Row \(row)").frame(height: 20)
                            }
                            MonknotSlider(
                                title: "Probe Width",
                                value: $state.value,
                                range: 1...10,
                                step: 1,
                                valueDescription: "\(Int(state.value)) points",
                                theme: theme,
                                zoomScale: zoomScale
                            )
                        }
                        .padding(12)
                        .frame(width: 210)
                    }
                }
                Button("Other") { state.otherActions += 1 }
                Spacer(minLength: 0)
            }
            .padding(.leading, 40)
            .padding(.top, 40)
            .frame(width: 600, height: 400, alignment: .topLeading)
        }
    }

    private final class ProbeWindow {
        let window: NSWindow
        let state: ProbeState

        /// The control's frame in the window: 40 from the top and the leading edge, 28 square at 1×.
        var controlCenter: NSPoint {
            NSPoint(x: 40 + 14, y: window.contentView!.bounds.height - 40 - 14)
        }

        init(state: ProbeState, contentKind: MonknotPopoverContentKind, theme: AppTheme, zoomScale: Double, origin: NSPoint? = nil) {
            self.state = state
            let host = NSHostingView(rootView: Probe(state: state, contentKind: contentKind, theme: theme, zoomScale: zoomScale))
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_400, height: 900)
            let frame = NSRect(origin: origin ?? NSPoint(x: visible.minX + 120, y: visible.maxY - 520), size: NSSize(width: 600, height: 400))
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private func makeProbe(
        contentKind: MonknotPopoverContentKind = .form,
        theme: AppTheme = .defaultLight,
        zoomScale: Double = 1,
        origin: NSPoint? = nil
    ) async -> ProbeWindow {
        let probe = ProbeWindow(state: ProbeState(), contentKind: contentKind, theme: theme, zoomScale: zoomScale, origin: origin)
        addTeardownBlock { @MainActor in
            MonknotPopoverController.shared.close(animated: false, restoresFocus: false)
            probe.close()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return probe
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func key(_ keyCode: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
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

    /// A real click: the window's own event path, as AppKit delivers it.
    private func click(at point: NSPoint, in window: NSWindow) async {
        if let down = mouse(.leftMouseDown, at: point, in: window) {
            window.sendEvent(down)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        if let up = mouse(.leftMouseUp, at: point, in: window) {
            window.sendEvent(up)
        }
    }

    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) async {
        if let down = mouse(.leftMouseDown, at: start, in: window) {
            window.sendEvent(down)
        }
        for step in 1...8 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let fraction = CGFloat(step) / 8
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            if let dragged = mouse(.leftMouseDragged, at: point, in: window) {
                window.sendEvent(dragged)
            }
        }
        if let up = mouse(.leftMouseUp, at: end, in: window) {
            window.sendEvent(up)
        }
    }

    /// Clicks the probe's control and waits for its popover.
    private func open(_ probe: ProbeWindow) async throws {
        await click(at: probe.controlCenter, in: probe.window)
        let opened = await wait(timeout: 2) { self.controller.isOpen }
        XCTAssertTrue(opened, "Clicking the control did not open its popover")
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    // MARK: - One surface

    /// design.md §5.9: no control in the app opens the system's popover, whose arrow, material and
    /// spring read as another app beside Monknot's menus.
    func testNoViewOpensTheSystemsPopover() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources/Monknot"), includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            XCTAssertFalse(source.contains(".popover("), "\(url.lastPathComponent) opens SwiftUI's popover; attach `monknotPopover`")
            XCTAssertFalse(source.contains("NSPopover"), "\(url.lastPathComponent) uses NSPopover; attach `monknotPopover`")
        }
        XCTAssertGreaterThan(checked, 50)
    }

    // MARK: - Placement

    func testItSitsBelowItsControlAndMovesAboveOrInWhereTheScreenEnds() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = CGSize(width: 210, height: 80)
        let control = NSRect(x: 100, y: 500, width: 28, height: 28)

        let below = MonknotPopoverPlacement(size: size, control: control, gap: 4, leadingOutset: 0, visibleFrame: screen)
        XCTAssertEqual(below.surface.maxY, control.minY - 4, "4 below the control")
        XCTAssertEqual(below.surface.minX, control.minX, "Leading edges together")
        XCTAssertFalse(below.isAbove)
        XCTAssertEqual(below.growAnchor, .topLeading, "Grows from the corner facing the control")

        let list = MonknotPopoverPlacement(size: size, control: control, gap: 4, leadingOutset: 6, visibleFrame: screen)
        XCTAssertEqual(list.surface.minX, control.minX - 6, "A list sits 6 outside, so its rows share the control's edges")

        let nearBottom = NSRect(x: 100, y: 40, width: 28, height: 28)
        let above = MonknotPopoverPlacement(size: size, control: nearBottom, gap: 4, leadingOutset: 0, visibleFrame: screen)
        XCTAssertTrue(above.isAbove)
        XCTAssertEqual(above.surface.minY, nearBottom.maxY + 4, "4 above the control where the screen ends")
        XCTAssertEqual(above.growAnchor, .bottomLeading)

        let nearRight = NSRect(x: 900, y: 500, width: 28, height: 28)
        let trailing = MonknotPopoverPlacement(size: size, control: nearRight, gap: 4, leadingOutset: 6, visibleFrame: screen)
        XCTAssertEqual(trailing.surface.maxX, nearRight.maxX + 6, "Trailing edges together where the screen ends on the right")
        XCTAssertEqual(trailing.growAnchor, .topTrailing)

        let atWindowEnd = NSRect(x: 600, y: 500, width: 28, height: 28)
        let window = NSRect(x: 100, y: 0, width: 600, height: 800)
        let insideWindow = MonknotPopoverPlacement(size: size, control: atWindowEnd, gap: 4, leadingOutset: 0, visibleFrame: screen, window: window)
        XCTAssertEqual(insideWindow.surface.maxX, atWindowEnd.maxX, "Past the window's trailing edge it ends on the control's, as a control's menu does")
        XCTAssertEqual(insideWindow.growAnchor, .topTrailing)

        let narrow = NSRect(x: 100, y: 0, width: 150, height: 800)
        let nearLeading = NSRect(x: 110, y: 500, width: 100, height: 28)
        let keepsLeading = MonknotPopoverPlacement(size: size, control: nearLeading, gap: 4, leadingOutset: 6, visibleFrame: screen, window: narrow)
        XCTAssertEqual(keepsLeading.surface.minX, nearLeading.minX - 6, "In a window narrower than it, ending on the control's edge would only cross the window's other edge")

        let offScreen = NSRect(x: 2, y: 500, width: 28, height: 28)
        let movedIn = MonknotPopoverPlacement(size: size, control: offScreen, gap: 4, leadingOutset: 6, visibleFrame: screen)
        XCTAssertEqual(movedIn.surface.minX, 6, "Moved back onto the screen, 6 clear of its edge")

        let nearLeft = NSRect(x: 10, y: 500, width: 28, height: 28)
        let fits = MonknotPopoverPlacement(size: size, control: nearLeft, gap: 4, leadingOutset: 6, visibleFrame: screen)
        XCTAssertEqual(fits.surface.minX, 4, "A surface that fits on the screen keeps its rows on the control's edges")

        let tall = MonknotPopoverPlacement(size: CGSize(width: 210, height: 700), control: control, gap: 4, leadingOutset: 0, visibleFrame: screen)
        XCTAssertEqual(tall.surface.minY, 6, "Too tall for either side: kept on the screen, 6 clear")
        XCTAssertFalse(tall.isAbove)
    }

    func testItOpensBelowItsControlOnTheSharedSurfaceAtEveryZoom() async throws {
        for zoom in [0.8, 1.0, 2.0] {
            let probe = await makeProbe(zoomScale: zoom)
            try await open(probe)
            let panel = try XCTUnwrap(controller.openPanel)
            XCTAssertTrue(panel is MonknotPopoverPanel)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(panel.canBecomeKey, "Its controls take keyboard focus")
            XCTAssertFalse(panel.canBecomeMain, "The window stays main, so its chrome keeps its active look")
            XCTAssertTrue(panel.parent === probe.window, "It moves with its window")
            XCTAssertTrue(panel.isKeyWindow || !NSApp.isActive, "It takes keyboard focus")
            XCTAssertTrue(probe.window.isMainWindow || !NSApp.isActive, "The window stays main: its titlebar and chrome keep their active look")
            XCTAssertFalse(panel.isMainWindow)
            XCTAssertTrue(probe.state.isPresented)

            let theme = AppTheme.defaultLight
            let gap = MonknotMetrics.interfaceDensity(4, theme: theme, zoomScale: zoom)
            let control = try XCTUnwrap(controller.openControlFrame)
            let surface = try XCTUnwrap(controller.openSurfaceFrame)
            XCTAssertEqual(surface.maxY, control.minY - gap, accuracy: 0.5, "zoom \(zoom): \(gap) below the control")
            XCTAssertEqual(surface.minX, control.minX, accuracy: 0.5, "zoom \(zoom): leading edges together")
            XCTAssertEqual(surface.width, 210, accuracy: 1, "zoom \(zoom): the content's own width")
            XCTAssertEqual(panel.frame.width - surface.width, 2 * MonknotPopoverController.shadowMargin, accuracy: 0.5, "Room for the e2 shadow")

            controller.close(animated: false)
            probe.close()
        }
    }

    func testAListSitsOutsideItsControlSoItsRowsShareTheControlsEdges() async throws {
        for zoom in [0.8, 2.0] {
            let probe = await makeProbe(contentKind: .list, zoomScale: zoom)
            try await open(probe)
            let control = try XCTUnwrap(controller.openControlFrame)
            let surface = try XCTUnwrap(controller.openSurfaceFrame)
            let inset = MonknotMetrics.interfaceDensity(MonknotMetrics.menuListInsetBase, theme: .defaultLight, zoomScale: zoom)
            XCTAssertEqual(surface.minX, control.minX - inset, accuracy: 0.5, "zoom \(zoom): the list inset outside the control")
            controller.close(animated: false)
            probe.close()
        }
    }

    func testItOpensAboveItsControlWhereTheScreenEnds() async throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        // The window's top row sits 30 above the bottom of the screen's visible area.
        let probe = await makeProbe(origin: NSPoint(x: visible.minX + 120, y: visible.minY - 330))
        try await open(probe)
        let control = try XCTUnwrap(controller.openControlFrame)
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        if control.minY - 4 - surface.height < visible.minY + 6 {
            XCTAssertEqual(surface.minY, control.maxY + 4, accuracy: 0.5, "No room below: 4 above the control")
            XCTAssertEqual(controller.openModel?.growAnchor, .bottomLeading, "Grows from the corner facing the control")
        }
        XCTAssertGreaterThanOrEqual(surface.minY, visible.minY + 6 - 0.5, "6 clear of the screen's edge")
    }

    // MARK: - Motion

    func testThePointerGrowsItInAndTheKeyboardShowsItAtOnce() async throws {
        let probe = await makeProbe()
        let anchor = try XCTUnwrap(probe.window.contentView)
        controller.present(AnyView(Text("Probe").padding(12)), label: "Probe", from: anchor, contentKind: .form, theme: .defaultLight, zoomScale: 1)
        XCTAssertEqual(controller.openModel?.isShown, false, "Opened by the pointer, it starts small and clear, then grows in")
        let shown = await wait(timeout: 1) { self.controller.openModel?.isShown == true }
        XCTAssertTrue(shown)

        controller.present(AnyView(Text("Probe").padding(12)), label: "Probe", from: anchor, contentKind: .form, theme: .defaultLight, zoomScale: 1, opensFromKeyboard: true)
        XCTAssertEqual(controller.openModel?.isShown, true, "Opened from the keyboard, it appears at once")
    }

    // MARK: - The controls inside

    /// A point inside the open surface, `x` from its leading edge and `y` from its top, in the panel's
    /// window coordinates.
    private func surfacePoint(x: CGFloat, y: CGFloat, in panel: NSPanel) -> NSPoint {
        let margin = MonknotPopoverController.shadowMargin
        return NSPoint(x: margin + x, y: panel.frame.height - margin - y)
    }

    func testTheControlsInsideWorkAndVoiceOverReadsItAsAPopover() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)
        let container = try XCTUnwrap(panel.contentView)
        XCTAssertEqual(container.accessibilityRole(), .popover, "VoiceOver reads it as a popover")
        XCTAssertEqual(container.accessibilityLabel(), "Probe", "Named for its control")
        XCTAssertTrue(container.isAccessibilityElement())
        XCTAssertTrue((container.accessibilityChildren() ?? []).contains { ($0 as? NSView) is MonknotPopoverHostingView }, "Its controls are its accessibility children")
        XCTAssertEqual(panel.title, "Probe")

        // The button: 12 inside the surface, at its top.
        let button = surfacePoint(x: 12 + 12, y: 12 + 8, in: panel)
        XCTAssertFalse(controller.handleForTesting(try XCTUnwrap(mouse(.leftMouseDown, at: button, in: panel))), "A click inside belongs to the popover's controls")
        await click(at: button, in: panel)
        let pressed = await wait(timeout: 1) { probe.state.actions == 1 }
        XCTAssertTrue(pressed, "A click on the popover's button did nothing")
        XCTAssertTrue(controller.isOpen, "Using a control inside keeps the popover open")

        // Synthesized drags do not drive SwiftUI's drag gestures in a test, in a popover or a window
        // alike, so the slider is not dragged here; MonknotControlTests covers its value path.

        // The surface follows what it shows, its top staying 4 below the control.
        let before = try XCTUnwrap(controller.openSurfaceFrame)
        probe.state.extraRows = 3
        let grew = await wait(timeout: 1) { (self.controller.openSurfaceFrame?.height ?? 0) >= before.height + 3 * 30 - 1 }
        XCTAssertTrue(grew, "The surface did not follow its content: \(String(describing: controller.openSurfaceFrame)) from \(before)")
        let after = try XCTUnwrap(controller.openSurfaceFrame)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.5, "It grows down from its control")
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
        XCTAssertTrue(controller.isOpen)
    }

    // MARK: - Focus and keys

    func testEscapeClosesItAndGivesFocusBackToTheWindow() async throws {
        let probe = await makeProbe()
        let responder = probe.window.firstResponder
        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)

        XCTAssertTrue(controller.handleForTesting(try XCTUnwrap(key(53, "\u{1b}", in: panel))))
        XCTAssertFalse(controller.isOpen, "Esc closes it")
        let closed = await wait(timeout: 1) { !probe.state.isPresented }
        XCTAssertTrue(closed, "Its control still shows it open")
        XCTAssertTrue(probe.window.isKeyWindow || !NSApp.isActive, "The window gets keyboard focus back")
        XCTAssertTrue(probe.window.firstResponder === responder, "The control that had focus gets it back")
        XCTAssertNil(panel.parent, "The panel no longer moves with the window")
    }

    /// With the app active, as it is in use: the popover takes key while its window stays main, Esc gives
    /// key back with the same first responder, and another window taking key closes it.
    func testItTakesKeyFocusWhileItsWindowStaysMain() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        _ = app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        defer { _ = app.setActivationPolicy(previousPolicy) }
        let probe = await makeProbe()
        probe.window.makeKeyAndOrderFront(nil)
        let active = await wait(timeout: 2) { NSApp.isActive && probe.window.isKeyWindow }
        try XCTSkipUnless(active, "The test app could not become active")
        let responder = probe.window.firstResponder

        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)
        XCTAssertTrue(panel.isKeyWindow, "The popover takes keyboard focus")
        XCTAssertTrue(probe.window.isMainWindow, "Its window stays main, so the titlebar keeps its active look")
        XCTAssertTrue(NSApp.mainWindow === probe.window)
        XCTAssertTrue(controller.isOpen, "Taking key from its own window must not close it")

        XCTAssertTrue(controller.handleForTesting(try XCTUnwrap(key(53, "\u{1b}", in: panel))))
        XCTAssertFalse(controller.isOpen)
        XCTAssertTrue(probe.window.isKeyWindow, "Esc gives keyboard focus back to the window")
        XCTAssertTrue(probe.window.firstResponder === responder, "…and to what had it")

        try await open(probe)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.animationBehavior = .none
        defer { other.orderOut(nil) }
        other.makeKeyAndOrderFront(nil)
        let closed = await wait(timeout: 1) { !self.controller.isOpen }
        XCTAssertTrue(closed, "Another window taking focus closes it")
        XCTAssertTrue(other.isKeyWindow, "…and keeps the focus it took")
    }

    @MainActor
    final class FocusState: ObservableObject {
        @Published var isPresented = false
        @Published var focused: String?
    }

    /// Two controls that take focus whatever the system's Full Keyboard Access says, reporting which
    /// has it.
    private struct FocusProbe: View {
        @ObservedObject var state: FocusState
        @SwiftUI.FocusState private var focus: String?

        var body: some View {
            Color.clear
                .frame(width: 28, height: 28)
                .monknotPopover(isPresented: $state.isPresented, label: "Focus", theme: .defaultLight, zoomScale: 1) {
                    VStack(spacing: 10) {
                        ForEach(["first", "second"], id: \.self) { name in
                            Text(name)
                                .frame(width: 120, height: 28)
                                .focusable()
                                .focused($focus, equals: name)
                        }
                    }
                    .padding(12)
                    .onChange(of: focus) { _, value in state.focused = value }
                }
                .padding(40)
                .frame(width: 400, height: 300, alignment: .topLeading)
        }
    }

    func testWithFullKeyboardAccessFocusStartsOnTheFirstControlAndTabMovesOn() async throws {
        MonknotPopoverController.fullKeyboardAccessOverride = true
        defer { MonknotPopoverController.fullKeyboardAccessOverride = nil }
        let state = FocusState()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: FocusProbe(state: state))
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.close(animated: false, restoresFocus: false)
            window.orderOut(nil)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        state.isPresented = true
        _ = await wait(timeout: 2) { self.controller.isOpen }
        let panel = try XCTUnwrap(controller.openPanel)
        let hosting = try XCTUnwrap(panel.contentView?.subviews.first)
        let inContent = await wait(timeout: 1) { (panel.firstResponder as? NSView)?.isDescendant(of: hosting) == true }
        XCTAssertTrue(inContent, "Keyboard focus did not go into the popover: \(String(describing: panel.firstResponder))")
        let first = await wait(timeout: 1) { state.focused == "first" }
        try XCTSkipUnless(first || NSApp.isActive, "SwiftUI reports focus only in a key window, and the test app is not active")
        XCTAssertTrue(first, "Focus starts on the first control: \(String(describing: state.focused))")
        if let tab = key(48, "\t", in: panel) {
            panel.sendEvent(tab)
        }
        let second = await wait(timeout: 1) { state.focused == "second" }
        XCTAssertTrue(second, "Tab moves to the next control: \(String(describing: state.focused))")
    }

    func testCancelOperationClosesIt() async throws {
        let probe = await makeProbe()
        try await open(probe)
        controller.openPanel?.cancelOperation(nil)
        XCTAssertFalse(controller.isOpen, "⌘. and Esc reach the panel as cancelOperation")
    }

    func testACommandShortcutClosesItAndGoesToTheWindow() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)
        let typed = try XCTUnwrap(key(1, "s", modifiers: .command, in: panel))
        XCTAssertTrue(controller.handleForTesting(typed), "The shortcut is sent on to the window")
        XCTAssertFalse(controller.isOpen)
        XCTAssertTrue(probe.window.isKeyWindow || !NSApp.isActive)
    }

    func testPlainKeysStayWithThePopoversControls() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)
        for (code, characters) in [(UInt16(48), "\t"), (124, ""), (49, " ")] {
            XCTAssertFalse(controller.handleForTesting(try XCTUnwrap(key(code, characters, in: panel))), "Key \(code) belongs to the focused control")
        }
        XCTAssertTrue(controller.isOpen)
    }

    // MARK: - What closes it

    func testAClickOutsideClosesItAndDoesNothingElse() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let other = NSPoint(x: 40 + 28 + 20 + 20, y: probe.controlCenter.y)
        let click = try XCTUnwrap(mouse(.leftMouseDown, at: other, in: probe.window))
        XCTAssertTrue(controller.handleForTesting(click), "The click that closes a popover does nothing else")
        XCTAssertFalse(controller.isOpen)
        let closed = await wait(timeout: 1) { !probe.state.isPresented }
        XCTAssertTrue(closed)
    }

    func testAClickOnItsControlClosesItRatherThanOpeningItAgain() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let down = try XCTUnwrap(mouse(.leftMouseDown, at: probe.controlCenter, in: probe.window))
        XCTAssertTrue(controller.handleForTesting(down))
        XCTAssertFalse(controller.isOpen)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(probe.state.isPresented, "The click that closed it must not toggle it open again")
        XCTAssertFalse(controller.isOpen)
    }

    func testARightClickOutsideClosesItAndOpensNoMenu() async throws {
        let probe = await makeProbe()
        MonknotContextMenuController.shared.setAppearance(theme: .defaultLight, zoomScale: 1, for: probe.window)
        try await open(probe)
        let right = try XCTUnwrap(mouse(.rightMouseDown, at: probe.controlCenter, in: probe.window))
        XCTAssertFalse(MonknotContextMenuController.shared.handleForTesting(right), "The context menu steps aside while a popover is open")
        XCTAssertTrue(controller.handleForTesting(right))
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(MonknotContextMenuController.shared.isOpen)
    }

    func testScrollingOutsideClosesIt() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
        XCTAssertTrue(controller.handleForTesting(event))
        XCTAssertFalse(controller.isOpen)
    }

    /// The window really moving, resizing and closing: a notification posted for a window that never
    /// closed would leave AppKit's own bookkeeping wrong for later tests.
    func testTheWindowMovingResizingOrClosingClosesIt() async throws {
        let changes: [(String, (NSWindow) -> Void)] = [
            ("moving", { $0.setFrameOrigin(NSPoint(x: $0.frame.minX + 40, y: $0.frame.minY - 20)) }),
            ("resizing", { $0.setContentSize(NSSize(width: 640, height: 420)) }),
            ("closing", { $0.close() }),
        ]
        for (name, change) in changes {
            let probe = await makeProbe()
            try await open(probe)
            change(probe.window)
            XCTAssertFalse(controller.isOpen, "The window \(name) leaves the popover open")
            let closed = await wait(timeout: 1) { !probe.state.isPresented }
            XCTAssertTrue(closed, "The window \(name): its control still shows it open")
            probe.close()
        }
    }

    func testAnotherAppOrWindowTakingFocusClosesIt() async throws {
        let probe = await makeProbe()
        try await open(probe)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(controller.isOpen, "Another app closes it")

        try await open(probe)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.animationBehavior = .none
        defer { other.orderOut(nil) }
        other.makeKeyAndOrderFront(nil)
        if NSApp.keyWindow === other {
            let closed = await wait(timeout: 1) { !self.controller.isOpen }
            XCTAssertTrue(closed, "Another window taking focus closes it")
        }
    }

    func testTheColourPickerItOpensKeepsItOpen() async throws {
        let probe = await makeProbe()
        try await open(probe)
        let panel = try XCTUnwrap(controller.openPanel)
        // A window the popover opened, as the colour well's picker is.
        let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        defer { child.orderOut(nil) }
        panel.addChildWindow(child, ordered: .above)
        let click = try XCTUnwrap(mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: child))
        XCTAssertFalse(controller.handleForTesting(click), "A click in a window the popover opened belongs to it")
        XCTAssertTrue(controller.isOpen)
        panel.removeChildWindow(child)
    }

    func testItsControlGoingAwayClosesIt() async throws {
        let probe = await makeProbe()
        try await open(probe)
        probe.state.showsControl = false
        let closed = await wait(timeout: 1) { !self.controller.isOpen }
        XCTAssertTrue(closed, "A popover outlived its control")
    }

    func testAWindowHiddenWithoutClosingTakesItsPopoverAndHoldsUpNothing() async throws {
        let probe = await makeProbe()
        try await open(probe)
        probe.window.orderOut(nil)
        let elsewhere = await makeProbe(origin: NSPoint(x: (NSScreen.main?.visibleFrame.minX ?? 0) + 760, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 520))
        let click = try XCTUnwrap(mouse(.leftMouseDown, at: elsewhere.controlCenter, in: elsewhere.window))
        XCTAssertFalse(controller.handleForTesting(click), "A popover whose window is gone must not swallow a click in another window")
        XCTAssertFalse(controller.isOpen)
    }

    func testSettingItsBindingFalseClosesIt() async throws {
        let probe = await makeProbe()
        try await open(probe)
        probe.state.isPresented = false
        let closed = await wait(timeout: 1) { !self.controller.isOpen }
        XCTAssertTrue(closed)
    }

    func testOneShowsAtATime() async throws {
        let first = await makeProbe()
        let second = await makeProbe(origin: NSPoint(x: (NSScreen.main?.visibleFrame.minX ?? 0) + 760, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 520))
        try await open(first)
        try await open(second)
        let firstClosed = await wait(timeout: 1) { !first.state.isPresented }
        XCTAssertTrue(firstClosed, "Opening a second popover closes the first")
        XCTAssertTrue(second.state.isPresented)
        XCTAssertTrue(controller.openPanel?.parent === second.window)
    }

    // MARK: - The workspace switcher

    func testTheWorkspaceSwitcherOpensOnTheSharedSurfaceBelowItsHeader() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let h = await harness(store, root)
        addTeardownBlock { @MainActor in h.close() }
        if let visible = NSScreen.main?.visibleFrame {
            h.window.setFrameOrigin(NSPoint(x: visible.minX + 200, y: visible.minY + 120))
        }

        // The header row: the sidebar's first bar, 40 tall, its row 28 tall in the 10 list inset.
        let height = try XCTUnwrap(h.window.contentView).bounds.height
        await click(at: NSPoint(x: 60, y: height - 20), in: h.window)
        let opened = await wait(timeout: 2) { self.controller.isOpen }
        XCTAssertTrue(opened, "Clicking the sidebar header did not open the switcher")
        XCTAssertEqual(controller.openLabel, "Workspaces")

        let control = try XCTUnwrap(controller.openControlFrame)
        let surface = try XCTUnwrap(controller.openSurfaceFrame)
        let windowFrame = h.window.convertToScreen(try XCTUnwrap(h.window.contentView).frame)
        XCTAssertEqual(control.minX - windowFrame.minX, 10, accuracy: 0.5, "The header row sits in the 10 list inset")
        XCTAssertEqual(control.height, 28, accuracy: 0.5)
        XCTAssertEqual(surface.minX, control.minX - 6, accuracy: 0.5, "Its rows share the header row's edges")
        XCTAssertEqual(surface.maxY, control.minY - 4, accuracy: 0.5, "4 below the header row")
        XCTAssertEqual(surface.width, 340, accuracy: 1, "340 wide")

        let panel = try XCTUnwrap(controller.openPanel)
        XCTAssertEqual(panel.contentView?.accessibilityRole(), .popover)
        XCTAssertEqual(panel.contentView?.accessibilityLabel(), "Workspaces")
        try await Task.sleep(nanoseconds: 200_000_000)
        // Add Workspace…: the second of the two last rows, 30 tall, 1 apart, in the 6 inset.
        let add = surfacePoint(x: 60, y: surface.height - 6 - 30 - 1 - 15, in: panel)
        await click(at: add, in: panel)
        let closed = await wait(timeout: 1) { !self.controller.isOpen }
        XCTAssertTrue(closed, "Choosing a row closes the switcher")
    }

    func testAClickOnTheSidebarHeaderClosesAnOpenSwitcher() async throws {
        let root = try makeRoot()
        try write("# a\n", "a.md", in: root)
        let store = try await openStore(root, selecting: "a.md")
        let h = await harness(store, root)
        addTeardownBlock { @MainActor in h.close() }
        let height = try XCTUnwrap(h.window.contentView).bounds.height
        let header = NSPoint(x: 60, y: height - 20)
        await click(at: header, in: h.window)
        _ = await wait(timeout: 2) { self.controller.isOpen }

        let down = try XCTUnwrap(mouse(.leftMouseDown, at: header, in: h.window))
        XCTAssertTrue(controller.handleForTesting(down))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(controller.isOpen, "A click on the header closes the switcher instead of reopening it")
    }

    // MARK: - Snapshots

    /// With `MONKNOT_POPOVER_SNAPSHOT_DIR` set, renders every popover on its surface off screen (no
    /// window server, so it works with the screen locked) over the chrome, light and dark, at zoom 0.8,
    /// 1 and 2: Stroke Width, Text Style and the workspace switcher.
    func testRenderThePopoverSurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_POPOVER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_POPOVER_SNAPSHOT_DIR to render the popovers")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let themes = [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark), ("latte", Self.theme("catppuccin-latte")), ("mocha", Self.theme("catppuccin-mocha"))]
        for (themeName, theme) in themes {
            for zoom in [0.8, 1.0, 2.0] {
                let formatting = PDFFreeTextFormatting(
                    fontFamily: "Helvetica Neue",
                    fontSize: 12,
                    fontColor: .systemBlue,
                    isBold: true,
                    isItalic: false,
                    alignment: .left
                )
                let contents: [(String, AnyView)] = [
                    ("stroke-width", AnyView(PDFStrokeWidthPopover(strokeWidth: .constant(3), theme: theme, zoomScale: zoom))),
                    ("text-style", AnyView(PDFFreeTextFormattingPopover(
                        formatting: formatting,
                        fontFamilies: ["Helvetica Neue", "Menlo", "New York"],
                        theme: theme,
                        zoomScale: zoom,
                        update: { _ in }
                    ))),
                ]
                for (name, content) in contents {
                    let model = MonknotPopoverModel(content: content, theme: theme, zoomScale: zoom)
                    model.isShown = true
                    let view = MonknotPopoverSurface(model: model)
                        .background(theme.chromeSurfaceColor)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.cgImage)
                    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("popover-\(name)-\(themeName)-\(zoom)x.png"))
                }
            }
        }
    }

    /// With `MONKNOT_POPOVER_SNAPSHOT_DIR` set, captures the real switcher open in the sidebar, light
    /// and dark: the window with the popover's panel drawn where it opens. Needs an unlocked screen.
    func testCaptureTheSwitcher() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_POPOVER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_POPOVER_SNAPSHOT_DIR to capture the switcher")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark)] {
            let root = try makeRoot()
            try write("# a\n", "a.md", in: root)
            let store = try await openStore(root, selecting: "a.md")
            let h = SidebarMenuHarness(store: store, root: root, theme: theme)
            try await Task.sleep(nanoseconds: 500_000_000)
            let height = try XCTUnwrap(h.window.contentView).bounds.height
            await click(at: NSPoint(x: 60, y: height - 20), in: h.window)
            _ = await wait(timeout: 2) { self.controller.isOpen }
            try await Task.sleep(nanoseconds: 600_000_000)
            try capture(h.window, controller.openPanel, name: "switcher-\(themeName)", into: directory)
            controller.close(animated: false)
            h.close()
        }
    }

    @MainActor
    final class StageState: ObservableObject {
        @Published var showsStrokeWidth = false
        @Published var showsTextStyle = false
        @Published var strokeWidth: Double = 3
    }

    /// A PDF bar's style controls on the card's surface: the Draw style pop-up with Stroke Width, and
    /// Text Style, each opening its real popover.
    private struct PDFPopoverStage: View {
        @ObservedObject var state: StageState
        let theme: AppTheme
        let zoomScale: Double

        var body: some View {
            VStack(spacing: 0) {
                MonknotBar(theme: theme, zoomScale: zoomScale) {
                    MonknotIconButton(systemImage: "pencil.tip", label: "Draw", theme: theme, zoomScale: zoomScale) {}
                    MonknotBarGroupGap(theme: theme, zoomScale: zoomScale)
                    MonknotPopUpButton(
                        label: "Annotation Style",
                        selection: .constant("red"),
                        items: [MonknotPopUpItem(id: "red", title: "Red")],
                        theme: theme,
                        zoomScale: zoomScale,
                        leadingPaddingBase: 8,
                        isOpen: state.showsStrokeWidth
                    ) { _ in
                        Circle()
                            .fill(Color(nsColor: .systemRed))
                            .frame(
                                width: MonknotMetrics.interfaceGlyph(14, theme: theme, zoomScale: zoomScale),
                                height: MonknotMetrics.interfaceGlyph(14, theme: theme, zoomScale: zoomScale)
                            )
                    }
                    .monknotPopover(isPresented: $state.showsStrokeWidth, label: "Stroke Width", theme: theme, zoomScale: zoomScale) {
                        PDFStrokeWidthPopover(strokeWidth: $state.strokeWidth, theme: theme, zoomScale: zoomScale)
                    }
                    MonknotBarGroupGap(theme: theme, zoomScale: zoomScale)
                    MonknotIconButton(
                        systemImage: "textformat",
                        label: "Text Style",
                        theme: theme,
                        zoomScale: zoomScale,
                        isOpen: state.showsTextStyle
                    ) {}
                    .monknotPopover(isPresented: $state.showsTextStyle, label: "Text Style", theme: theme, zoomScale: zoomScale) {
                        PDFFreeTextFormattingPopover(
                            formatting: PDFFreeTextFormatting(
                                fontFamily: "Helvetica Neue",
                                fontSize: 12,
                                fontColor: .systemBlue,
                                isBold: true,
                                isItalic: false,
                                alignment: .left
                            ),
                            fontFamilies: ["Helvetica Neue", "Menlo", "New York"],
                            theme: theme,
                            zoomScale: zoomScale,
                            update: { _ in }
                        )
                    }
                    Spacer(minLength: 0)
                }
                theme.controlTrackFillColor
            }
            .background(theme.surfaceColor)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
    }

    /// With `MONKNOT_POPOVER_SNAPSHOT_DIR` set, captures Stroke Width and Text Style opened from their
    /// controls in a PDF bar, light and dark, at zoom 0.8, 1 and 2. Needs an unlocked screen.
    func testCaptureThePDFPopovers() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_POPOVER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_POPOVER_SNAPSHOT_DIR to capture the PDF popovers")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_400, height: 900)
        for (themeName, theme) in [("latte", Self.theme("catppuccin-latte")), ("mocha", Self.theme("catppuccin-mocha"))] {
            for zoom in [0.8, 1.0, 2.0] {
                let state = StageState()
                let host = NSHostingView(rootView: PDFPopoverStage(state: state, theme: theme, zoomScale: zoom))
                let window = NSWindow(
                    contentRect: NSRect(x: visible.minX + 120, y: visible.maxY - 560, width: 760, height: 380),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 300_000_000)
                for (name, open) in [("stroke-width", { state.showsStrokeWidth = true }), ("text-style", { state.showsTextStyle = true })] {
                    open()
                    _ = await wait(timeout: 2) { self.controller.isOpen }
                    try await Task.sleep(nanoseconds: 600_000_000)
                    try capture(window, controller.openPanel, name: "pdf-\(name)-\(themeName)-\(zoom)x", into: directory)
                    controller.close(animated: false, restoresFocus: false)
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }

    private static func theme(_ id: String) -> AppTheme {
        (MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets).first { $0.theme.id == id }?.theme ?? .defaultLight
    }

    private func capture(_ window: NSWindow, _ panel: NSPanel?, name: String, into directory: URL) throws {
        let panel = try XCTUnwrap(panel)
        let windowImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let panelImage = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let scale = CGFloat(windowImage.width) / window.frame.width
        let union = window.frame.union(panel.frame)
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
        draw(windowImage, window.frame)
        draw(panelImage, panel.frame)
        composite.unlockFocus()
        let tiff = try XCTUnwrap(composite.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
