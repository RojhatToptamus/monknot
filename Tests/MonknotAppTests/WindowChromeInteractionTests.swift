import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class WindowChromeInteractionTests: XCTestCase {
    func testWorkspaceWindowChromePreservesNativeWindowControlsAndToolbarOwnership() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "MonknotChromeRegressionToolbar")
        window.toolbar = toolbar
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.closeButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        let coordinator = WindowChromeConfigurator.Coordinator(
            enablesStandardWindowControls: true
        )
        coordinator.configureWindowChrome(in: window)

        XCTAssertTrue(
            window.toolbar === toolbar,
            "Window chrome support must not dismantle AppKit-owned title-bar infrastructure"
        )
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
    }

    func testWindowBackgroundDoesNotTurnTopBarControlsIntoDragOrZoomTargets() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: Color.clear.background(
            WindowChromeConfigurator(surfaceColor: .black, isDark: true)
        ))
        window.contentView = host

        let didConfigureWindow = await waitForHostedWindowCondition(
            window: window,
            host: host,
            until: { !window.isMovableByWindowBackground }
        )

        XCTAssertTrue(
            didConfigureWindow,
            "Only explicit unused title-bar gaps may move or zoom the window"
        )
    }

    func testSettingsChromeEnablesEveryNativeWindowControl() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let coordinator = WindowChromeConfigurator.Coordinator(
            enablesStandardWindowControls: true
        )
        coordinator.configureWindowChrome(in: window)

        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
    }

    func testNativeTrafficLightAlignmentReappliesAfterWindowLayoutChange() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: .defaultLight,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let coordinator = WindowChromeConfigurator.Coordinator(
            trafficLightRowHeight: chromeHeight
        )
        coordinator.observeWindow(window)
        coordinator.configureWindowChrome(in: window)

        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarContainer = closeButton.superview
        else {
            return XCTFail("Missing AppKit-owned native close button")
        }

        closeButton.setFrameOrigin(NSPoint(x: closeButton.frame.minX, y: 9))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)

        let centerFromTop = titlebarContainer.isFlipped
            ? closeButton.frame.midY - titlebarContainer.bounds.minY
            : titlebarContainer.bounds.maxY - closeButton.frame.midY
        XCTAssertEqual(
            centerFromTop,
            chromeHeight / 2,
            accuracy: 0.001,
            "Resize and state transitions must restore the native controls to Monknot's centerline"
        )
    }

    func testDisabledIconButtonsDrawInk4WithNoFill() {
        // design.md §5.1: a disabled button is an `ink4` glyph and nothing else, whatever its state.
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for active in [false, true] {
                XCTAssertEqual(
                    MonknotIconButton.iconColor(theme: theme, isActive: active, isHovered: true, isDisabled: true),
                    theme.disabledForegroundColor
                )
                XCTAssertNil(MonknotIconButton.fill(
                    isActive: active,
                    drawsActiveBackground: true,
                    isHovered: true,
                    isPressed: true,
                    isDisabled: true
                ))
            }
            XCTAssertEqual(
                MonknotIconButton.iconColor(theme: theme, isActive: false, isHovered: false, isDisabled: false),
                theme.tertiaryForegroundColor,
                "A glyph rests at ink3"
            )
        }
    }

    /// An enclosing `.disabled` (a PDF bar while its document loads) reaches every button in it.
    func testIconButtonsTakeTheirDisabledLookFromAnEnclosingDisabledContainer() {
        let theme = AppTheme.defaultLight
        let enabled = NSHostingView(rootView: MonknotIconButton(
            systemImage: "plus", label: "Add", theme: theme, zoomScale: 1, action: {}
        ))
        let disabled = NSHostingView(rootView: MonknotIconButton(
            systemImage: "plus", label: "Add", theme: theme, zoomScale: 1, action: {}
        ).disabled(true))
        XCTAssertEqual(enabled.fittingSize, disabled.fittingSize, "Disabling never changes the box")
    }

    func testChromeListsKeepTheSlimOverlayThumbWhenTheSystemSwitchesToLegacyScrollBars() async {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 248, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 248, height: 1200))
        let behavior = MonknotChromeScrollerBehavior()
        behavior.attach(to: scrollView)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.verticalScroller is MonknotScroller)
        XCTAssertEqual(scrollView.contentView.bounds.width, 248, "An overlay thumb takes no width from the list")

        // What AppKit does when "Show scroll bars" changes or a mouse is plugged in.
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        for _ in 0..<10 where scrollView.scrollerStyle != .overlay {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        behavior.detach()
    }

    func testChromeScrollViewTakesTheOverlayThumbWithoutWaitingForTheRunLoop() throws {
        let theme = AppTheme.defaultDark
        let hostingView = NSHostingView(
            rootView: MonknotScrollView(theme: theme) {
                Color.clear.frame(height: 1200)
            }
            .frame(width: 248, height: 300)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 248, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(Self.firstDescendant(of: NSScrollView.self, in: hostingView))
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        let scroller = try XCTUnwrap(scrollView.verticalScroller as? MonknotScroller)
        XCTAssertEqual(scroller.thumbColor, NSColor(hex: theme.foreground), "The thumb takes the theme's ink")
        XCTAssertEqual(scrollView.contentView.bounds.width, 248, "An overlay thumb takes no width from the list")
    }

    func testPDFPageThumbnailsUseTheChromeThumb() throws {
        let navigator = PDFNavigatorView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let scrollView = try XCTUnwrap(Self.firstDescendant(of: NSScrollView.self, in: navigator.thumbnailView))
        XCTAssertTrue(scrollView.verticalScroller is MonknotScroller)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    }

    /// design.md §5.7: documents take the same slim thumb as the chrome, and follow the system's
    /// "Show scroll bars" setting — fading when overlay, staying in a reserved lane when always.
    func testDocumentsTakeTheMonknotThumbAndFollowTheSystemScrollerStyle() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasVerticalScroller = true
        let ink = NSColor(hex: AppTheme.defaultDark.foreground)
        MonknotScrollbarStyle.applyDocument(to: scrollView, thumbColor: ink)
        let scroller = scrollView.verticalScroller as? MonknotScroller
        XCTAssertNotNil(scroller)
        XCTAssertEqual(scroller?.thumbColor, ink)
        XCTAssertEqual(scrollView.scrollerStyle, NSScroller.preferredScrollerStyle)
        XCTAssertEqual(scrollView.autohidesScrollers, NSScroller.preferredScrollerStyle == .overlay)
        XCTAssertEqual(scrollView.scrollerInsets.top, MonknotScrollbarStyle.endInset, "Clear of a card's rounded corners")
        XCTAssertEqual(MonknotScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), MonknotScrollbarStyle.trackWidth)
    }

    /// design.md §5.7: with "Show scroll bars: Always", Preview draws Monknot's thumb in its 11 lane from
    /// the shell's first paint, not WebKit's 17 legacy bar until the setting next changes.
    func testPreviewShellDrawsTheMonknotLaneWhenTheSystemShowsScrollBars() async throws {
        for legacy in [true, false] {
            let html = try MarkdownRenderService().htmlDocument(
                markdown: String(repeating: "A paragraph long enough to scroll.\n\n", count: 120),
                appTheme: .defaultLight,
                zoomScale: 1,
                baseFontSize: AppTheme.defaultLight.codeFontSize,
                legacyScrollbars: legacy,
                baseURL: nil
            )
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = webView
            defer { window.contentView = nil }
            webView.loadHTMLString(html, baseURL: nil)

            var probe: [Any] = []
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 50_000_000)
                // The shell's own document, not the blank page WebKit starts with.
                if let result = try? await webView.evaluateJavaScript(
                    "[document.documentElement.classList.contains('mk-legacy-scrollbars'), window.innerWidth - document.documentElement.clientWidth, document.readyState === 'complete' && document.getElementById('content') !== null]"
                ) as? [Any], (result.last as? Bool) == true {
                    probe = result
                    break
                }
            }
            XCTAssertEqual(probe.first as? Bool, legacy, "The shell carries the scroll bar style")
            if legacy {
                XCTAssertEqual(
                    (probe.dropFirst().first as? NSNumber)?.doubleValue,
                    Double(MonknotScrollbarStyle.trackWidth),
                    "Monknot's lane, not WebKit's legacy bar"
                )
            }
        }
    }

    private static func firstDescendant<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        for subview in view.subviews {
            if let match = subview as? View ?? firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    /// design.md §5.7: a slim capsule centred in its 9 lane, 2.5 from the edge at rest, wider and
    /// darker under the pointer, never touching the ends of its lane.
    func testScrollThumbIsASlimCapsuleInsetFromItsEdge() {
        XCTAssertLessThan(MonknotScrollbarStyle.restingThumbWidth, MonknotScrollbarStyle.hoveredThumbWidth)
        XCTAssertLessThan(MonknotScrollbarStyle.restingOpacity, MonknotScrollbarStyle.hoveredOpacity)
        let bounds = NSRect(x: 0, y: 0, width: MonknotScrollbarStyle.trackWidth, height: 300)
        let knob = NSRect(x: 0, y: 40, width: MonknotScrollbarStyle.trackWidth, height: 80)
        let resting = MonknotScroller.thumbRect(knob: knob, bounds: bounds, isVertical: true, isHovered: false)
        XCTAssertEqual(resting.width, MonknotScrollbarStyle.restingThumbWidth)
        XCTAssertEqual(bounds.maxX - resting.maxX, 2.5, accuracy: 0.001, "Rests 2.5 from the container's edge")
        let hovered = MonknotScroller.thumbRect(knob: knob, bounds: bounds, isVertical: true, isHovered: true)
        XCTAssertEqual(hovered.midX, resting.midX, accuracy: 0.001, "Grows from its centre")
        XCTAssertGreaterThan(resting.minY, knob.minY)
    }

    /// A document's lane sits flush with the card's trailing edge: only the thumb's ends are inset,
    /// clear of the card's rounded corners. An inset across the lane would move it off the edge and
    /// leave an unpainted strip between the thumb and the card's edge.
    func testADocumentScrollLaneIsFlushWithTheTrailingEdge() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2_000))
        MonknotScrollbarStyle.applyDocument(to: scrollView)
        scrollView.scrollerStyle = .legacy
        scrollView.tile()

        XCTAssertEqual(scrollView.scrollerInsets.left, 0)
        XCTAssertEqual(scrollView.scrollerInsets.right, 0)
        XCTAssertEqual(scrollView.scrollerInsets.top, MonknotScrollbarStyle.endInset)
        XCTAssertEqual(scrollView.scrollerInsets.bottom, MonknotScrollbarStyle.endInset)
        let scroller = try XCTUnwrap(scrollView.verticalScroller)
        XCTAssertEqual(scroller.frame.maxX, scrollView.bounds.maxX, accuracy: 0.5, "The lane touches the edge")
        XCTAssertEqual(scroller.frame.width, MonknotScrollbarStyle.trackWidth, accuracy: 0.5)

        // With both scrollers, each lane ends where the other begins; only far ends are inset.
        let both = MonknotScrollbarStyle.endInsets(hasVertical: true, hasHorizontal: true)
        XCTAssertEqual(both.right, 0)
        XCTAssertEqual(both.bottom, 0)
        XCTAssertEqual(both.top, MonknotScrollbarStyle.endInset)
        XCTAssertEqual(both.left, MonknotScrollbarStyle.endInset)
    }

    func testDisabledRowsDrawNoHoverOrPressFillButKeepTheirSelection() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            func fill(selected: Bool = false, hovered: Bool = false, pressed: Bool = false, enabled: Bool) -> Color {
                MonknotRowButtonStyle.fill(
                    theme: theme,
                    isSelected: selected,
                    isActive: false,
                    isHovered: hovered,
                    isPressed: pressed,
                    isEnabled: enabled
                )
            }

            XCTAssertEqual(fill(hovered: true, enabled: true), theme.hoverFillColor)
            XCTAssertEqual(fill(hovered: true, pressed: true, enabled: true), theme.pressedFillColor)
            XCTAssertEqual(fill(hovered: true, enabled: false), .clear)
            XCTAssertEqual(fill(hovered: true, pressed: true, enabled: false), .clear)
            // Selection is the neutral fill, never an accent tint (design.md §1.4).
            XCTAssertEqual(fill(selected: true, hovered: true, enabled: false), theme.chromeSelectedFillColor)
        }
    }

    /// Back and forward are two ordinary bar buttons side by side, 2 apart, with no shell (design.md §5.1).
    func testWindowNavigationIsTwoRegularButtonsTwoApartAtEveryZoom() {
        let theme = AppTheme.defaultDark
        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let host = NSHostingView(rootView: WindowNavigationControls(
                navigateBack: {},
                navigateForward: {},
                canNavigateBack: true,
                canNavigateForward: false,
                theme: theme,
                zoomScale: zoomScale
            ))
            let button = MonknotIconButton.IconButtonSize.regular.dimension(theme: theme, zoomScale: zoomScale)
            let gap = MonknotMetrics.interfaceDensity(MonknotMetrics.barItemGapBase, theme: theme, zoomScale: zoomScale)
            XCTAssertEqual(host.fittingSize.width, button * 2 + gap, accuracy: 0.01, "zoom \(zoomScale)")
        }
    }

    func testCloseGuardPreservesExistingWindowDelegateCallbacks() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalDelegate = StandardFrameWindowDelegate()
        window.delegate = originalDelegate
        let coordinator = WindowCloseGuard.Coordinator(
            terminationCoordinator: ApplicationTerminationCoordinator(),
            shouldClose: { true }
        )
        coordinator.install(on: window)

        let proposedFrame = NSRect(x: 20, y: 30, width: 800, height: 600)
        let resolvedFrame = window.delegate?.windowWillUseStandardFrame?(
            window,
            defaultFrame: proposedFrame
        )

        XCTAssertEqual(originalDelegate.standardFrameCallCount, 1)
        XCTAssertEqual(resolvedFrame, proposedFrame.insetBy(dx: 12, dy: 12))
    }

    func testExplicitTitleBarGapDragsAndDoubleClickZoomsThroughAppKit() {
        let window = WindowInteractionRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let dragView = WindowTitleBarDragArea.NativeTitleBarDragView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 44)
        )
        window.contentView = dragView

        let firstClick = titleBarMouseEvent(clickCount: 1, windowNumber: window.windowNumber)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(dragView.acceptsFirstMouse(for: firstClick))

        dragView.mouseDown(with: firstClick)
        XCTAssertEqual(window.dragCallCount, 1)
        XCTAssertEqual(window.zoomCallCount, 0)

        dragView.mouseDown(with: titleBarMouseEvent(clickCount: 2, windowNumber: window.windowNumber))
        XCTAssertEqual(window.dragCallCount, 1)
        XCTAssertEqual(window.zoomCallCount, 1)
    }

    func testTopNavigationControlsRemainOutsideTheExplicitTitleBarDragGap() throws {
        let theme = AppTheme.defaultDark
        let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: 1)
        let actions = TopBarActionRecorder()
        let topBar = TopNavigationBar(
            editorMode: .constant(.source),
            isSplitViewEnabled: .constant(false),
            selectedDocument: nil,
            isBusy: false,
            isDocumentLoading: false,
            isSaving: false,
            theme: theme,
            zoomScale: 1,
            isTerminalPresented: false,
            isSidebarVisible: true,
            toggleTerminal: { actions.terminalToggleCount += 1 },
            toggleSidebar: {},
            toggleSplitView: {},
            documentSearch: .constant(DocumentSearchState()),
            searchOptions: .constant(MonknotSearchOptions()),
            dismissDocumentSearch: {},
            documentSearchFocusChanged: { _ in },
            tabs: [],
            activeTabID: nil,
            missingTabIDs: [],
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePinTab: { _ in },
            reorderTab: { _, _ in }
        )
        let host = NSHostingView(rootView: topBar.frame(width: 1_200, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: chromeHeight)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let dragView = try XCTUnwrap(
            host.allDescendantsForTesting()
                .compactMap { $0 as? WindowTitleBarDragArea.NativeTitleBarDragView }
                .first
        )
        let dragFrame = dragView.convert(dragView.bounds, to: host)
        XCTAssertGreaterThan(dragFrame.minX, host.bounds.minX)
        XCTAssertLessThan(dragFrame.maxX, host.bounds.maxX)

        let otherWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let previousActivationPolicy = NSApp.activationPolicy()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let terminalControlPoint = NSPoint(
            x: host.bounds.maxX - 20,
            y: host.bounds.midY
        )
        let locationInWindow = host.convert(terminalControlPoint, to: nil)
        let controlHitView = try XCTUnwrap(
            host.hitTest(terminalControlPoint)
        )
        XCTAssertFalse(controlHitView.isDescendantForTesting(of: dragView))

        otherWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        defer {
            otherWindow.orderOut(nil)
            window.orderOut(nil)
            _ = NSApp.setActivationPolicy(previousActivationPolicy)
        }
        XCTAssertFalse(window.isKeyWindow)

        let down = try XCTUnwrap(mouseEventForChromeTesting(
            type: .leftMouseDown,
            location: locationInWindow,
            windowNumber: window.windowNumber
        ))
        let up = try XCTUnwrap(mouseEventForChromeTesting(
            type: .leftMouseUp,
            location: locationInWindow,
            windowNumber: window.windowNumber
        ))
        NSApp.sendEvent(down)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        NSApp.sendEvent(up)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            actions.terminalToggleCount,
            1,
            "A top-bar control should handle the first click while activating an inactive window"
        )
    }

    func testWindowNavigationControlsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let controls = WindowNavigationControls(
                navigateBack: {},
                navigateForward: {},
                canNavigateBack: true,
                canNavigateForward: true,
                theme: theme,
                zoomScale: zoomScale
            )
            let host = NSHostingView(rootView: controls)

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Window navigation chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    private func waitForHostedWindowCondition<Content: View>(
        window: NSWindow,
        host: NSHostingView<Content>,
        timeout: TimeInterval = 2,
        until condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            if condition() {
                return true
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
        return condition()
    }

}
