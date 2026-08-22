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

        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
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
            WindowBackgroundDragEnabler(surfaceColor: .black)
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

        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
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
        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
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

    func testDisabledWindowNavigationAvoidsDoubleAttenuation() {
        let size = MonknotIconButton.IconButtonSize.windowNavigation

        XCTAssertEqual(size.disabledControlOpacity, 0.24, accuracy: 0.001)
    }

    func testWindowNavigationUsesReferenceSegmentGeometryAcrossSupportedZooms() {
        let theme = AppTheme.defaultDark
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {

            XCTAssertEqual(
                navigationSize.dimension(theme: theme, zoomScale: zoomScale),
                chromeSize.dimension(theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
            XCTAssertLessThan(
                navigationSize.height(theme: theme, zoomScale: zoomScale),
                chromeSize.height(theme: theme, zoomScale: zoomScale)
            )
            XCTAssertEqual(
                navigationSize.iconSize(theme: theme, zoomScale: zoomScale),
                MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                accuracy: 0.001,
                "Navigation chevrons use their specified optical size"
            )
        }
    }

    func testWindowNavigationUsesTheSharedReferenceHoverFill() {
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertEqual(
                navigationSize.hoverBackgroundOpacity(isDark: isDark),
                chromeSize.hoverBackgroundOpacity(isDark: isDark)
            )
        }
    }

    func testOpenPanelButtonsUseTheSharedReferenceHoverSurface() {
        let size = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertEqual(size.activeBackgroundOpacity(isDark: isDark), isDark ? 0.18 : 0.14)
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
            emptyStateTitle: "Monknot",
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

    func testWindowNavigationReserveContainsControlsAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let buttonWidth = MonknotMetrics.windowNavigationButtonDimension(
                theme: theme,
                zoomScale: zoomScale
            )
            let controlsTrailingEdge = MonknotMetrics.trafficLightReserveBase
                + MonknotMetrics.windowNavigationLeadingGap(theme: theme, zoomScale: zoomScale)
                + buttonWidth * 2
                + MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale)

            XCTAssertGreaterThan(
                MonknotMetrics.windowChromeLeadingReservedWidth(theme: theme, zoomScale: zoomScale),
                controlsTrailingEdge,
                "Window chrome reserve overlapped navigation controls at zoom \(zoomScale)"
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
