import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class DocumentTabBarLayoutTests: XCTestCase {
    func testNativeTrafficLightsStayCenteredAndHitTestableInTheAdaptiveWorkspaceChromeBand() {
        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let chromeHeight = MonknotMetrics.chromeHeight(
                theme: .defaultLight,
                zoomScale: zoomScale
            )
            let leadingInset = MonknotMetrics.chromeHorizontalPadding(
                theme: .defaultLight,
                zoomScale: zoomScale
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            let originalButtonOrigins = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0?.frame.minX }

            let coordinator = WindowBackgroundDragEnabler.Coordinator(
                suppressToolbarButton: true,
                trafficLightRowHeight: chromeHeight,
                trafficLightLeadingInset: leadingInset
            )
            window.layoutIfNeeded()
            coordinator.configureWindowChrome(in: window)

            XCTAssertNil(
                window.toolbar,
                "A second native toolbar would cover the custom workspace row"
            )

            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview,
                  let titlebarContainer = titlebarView.superview,
                  let themeFrame = titlebarContainer.superview
            else {
                XCTFail("Missing AppKit-owned native close button")
                continue
            }

            XCTAssertEqual(titlebarView.bounds.height, chromeHeight, accuracy: 0.001)
            XCTAssertEqual(titlebarContainer.bounds.height, chromeHeight, accuracy: 0.001)

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0 }

            let closeOpticalLeadingEdge = closeButton.frame.minX
                + (closeButton.frame.width - NativeWindowChromeGeometry.trafficLightDiameter) / 2
            XCTAssertEqual(
                closeOpticalLeadingEdge,
                leadingInset,
                accuracy: 0.001,
                "The native traffic lights and trailing chrome control must share one edge inset"
            )
            let shiftedButtonOrigins = buttons.map(\.frame.minX)
            XCTAssertEqual(shiftedButtonOrigins.count, originalButtonOrigins.count)
            for index in 1..<min(shiftedButtonOrigins.count, originalButtonOrigins.count) {
                XCTAssertEqual(
                    shiftedButtonOrigins[index] - shiftedButtonOrigins[index - 1],
                    originalButtonOrigins[index] - originalButtonOrigins[index - 1],
                    accuracy: 0.001,
                    "Horizontal balancing must retain AppKit's native inter-button spacing"
                )
            }

            for button in buttons {
                XCTAssertTrue(button.superview === titlebarView)
                let centerFromTop = titlebarView.isFlipped
                    ? button.frame.midY - titlebarView.bounds.minY
                    : titlebarView.bounds.maxY - button.frame.midY
                XCTAssertEqual(
                    centerFromTop,
                    chromeHeight / 2,
                    accuracy: 0.001,
                    "Every native traffic light must share Monknot's primary chrome centerline"
                )

                let centerInThemeFrame = button.convert(
                    NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                    to: themeFrame
                )
                XCTAssertTrue(
                    themeFrame.hitTest(centerInThemeFrame) === button,
                    "The visible native traffic light must receive its own pointer events"
                )
            }
            XCTAssertFalse(
                titlebarView.clipsToBounds,
                "AppKit's native controls must remain visible throughout the adaptive chrome row"
            )
        }
    }

    func testLongTabTitlesUseAStableCappedWidth() {
        let metrics = DocumentTabMetrics(theme: .defaultDark, zoomScale: 1)
        let shortWidth = width(of: "README.md", metrics: metrics)
        let longWidth = width(of: String(repeating: "Remote_Objects_", count: 40) + ".pdf", metrics: metrics)

        XCTAssertGreaterThan(longWidth, shortWidth)
        XCTAssertLessThanOrEqual(longWidth, metrics.maximumWidth)
    }

    func testDocumentTabsSizeToTheirMeasuredTitles() {
        let metrics = DocumentTabMetrics(theme: .defaultDark, zoomScale: 1)
        let short = width(of: "a.json", metrics: metrics)
        let long = width(of: "02-sockets-claude.md", metrics: metrics)

        XCTAssertGreaterThan(long, short + 40)
        XCTAssertGreaterThanOrEqual(short, MonknotMetrics.tabMinWidthBase)
        XCTAssertLessThanOrEqual(long, MonknotMetrics.tabMaxWidthBase)
    }

    func testLabelsThatFitAreNeverElidedAtAnyZoom() {
        // F14: `data.csv` (pinned) and `README.md` (at 1.25×) used to render as `da…sv` and `READ…E.m`.
        for zoomScale in [0.85, 1, 1.25, 1.5] {
            let metrics = DocumentTabMetrics(theme: .defaultDark, zoomScale: zoomScale)
            for name in ["data.csv", "README.md", "Untitled 4.md"] {
                for isPinned in [false, true] {
                    XCTAssertEqual(metrics.fittedLabel(name, isPinned: isPinned, isMissing: true), name)
                }
            }
        }
    }

    func testOverlongLabelsAreMiddleElidedKeepingTheExtension() {
        let metrics = DocumentTabMetrics(theme: .defaultDark, zoomScale: 1)
        let name = String(repeating: "improving-onboarding-", count: 6) + "conversion-rate.md"

        let fitted = metrics.fittedLabel(name, isPinned: false, isMissing: false)

        XCTAssertTrue(fitted.hasPrefix("improving-onb"), fitted)
        XCTAssertTrue(fitted.hasSuffix(".md"))
        XCTAssertEqual(fitted.filter { $0 == "\u{2026}" }.count, 1)
        XCTAssertLessThanOrEqual(
            metrics.width(fittedLabel: fitted, isPinned: false, isMissing: false),
            metrics.maximumWidth
        )
    }

    private func width(of name: String, metrics: DocumentTabMetrics) -> CGFloat {
        let fitted = metrics.fittedLabel(name, isPinned: false, isMissing: false)
        return metrics.width(fittedLabel: fitted, isPinned: false, isMissing: false)
    }

    func testPinnedTabsRetainTheirTitleAndPinAffordanceWidth() {
        let metrics = DocumentTabMetrics(theme: .defaultDark, zoomScale: 1)
        let short = metrics.width(fittedLabel: "a.md", isPinned: true, isMissing: false)
        let readme = metrics.width(fittedLabel: "README.md", isPinned: true, isMissing: false)

        XCTAssertGreaterThan(readme, short)
        XCTAssertGreaterThanOrEqual(short, MonknotMetrics.tabMinWidthBase)
        XCTAssertLessThanOrEqual(readme, MonknotMetrics.tabMaxWidthBase)
    }

    func testTabCloseButtonsScaleWithTheSixteenPointTrailingSlot() {
        let theme = AppTheme.defaultDark
        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            XCTAssertEqual(
                MonknotTabCloseButton.dimension(theme: theme, zoomScale: zoomScale),
                MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
        }
    }

    func testConstrainedMaximumZoomKeepsTheTabViewportInsideTheTopBarAllocation() throws {
        let theme = AppTheme.defaultDark
        let zoomScale = WorkspaceZoomPolicy.maximum
        let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
        let allocationWidth: CGFloat = 1_230
        let tab = WorkspaceTabItem(
            documentID: "/README.md",
            displayName: "README.md",
            relativePath: "README.md",
            kind: .markdown
        )
        let topBar = TopNavigationBar(
            editorMode: .constant(.source),
            isSplitViewEnabled: .constant(false),
            emptyStateTitle: "Monknot",
            selectedDocument: nil,
            isBusy: false,
            isDocumentLoading: false,
            isSaving: false,
            theme: theme,
            zoomScale: zoomScale,
            isTerminalPresented: true,
            isSidebarVisible: true,
            toggleTerminal: {},
            toggleSidebar: {},
            toggleSplitView: {},
            documentSearch: .constant(DocumentSearchState()),
            searchOptions: .constant(MonknotSearchOptions()),
            dismissDocumentSearch: {},
            documentSearchFocusChanged: { _ in },
            tabs: [tab],
            activeTabID: tab.documentID,
            missingTabIDs: [],
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePinTab: { _ in },
            reorderTab: { _, _ in }
        )
        let host = NSHostingView(
            rootView: topBar.frame(width: allocationWidth, height: chromeHeight)
        )
        host.frame = NSRect(x: 0, y: 0, width: allocationWidth, height: chromeHeight)
        host.layoutSubtreeIfNeeded()

        let tabScroller = try XCTUnwrap(
            host.allDescendantsForTesting().compactMap { $0 as? NSScrollView }.first
        )
        let viewportFrame = tabScroller.convert(tabScroller.bounds, to: host)
        XCTAssertGreaterThan(viewportFrame.width, 0)
        XCTAssertGreaterThan(viewportFrame.height, 0)
        XCTAssertGreaterThanOrEqual(viewportFrame.minX, host.bounds.minX - 1)
        XCTAssertLessThanOrEqual(viewportFrame.maxX, host.bounds.maxX + 1)
        XCTAssertGreaterThanOrEqual(viewportFrame.minY, host.bounds.minY - 1)
        XCTAssertLessThanOrEqual(viewportFrame.maxY, host.bounds.maxY + 1)
        XCTAssertEqual(host.fittingSize.height, chromeHeight, accuracy: 0.01)
    }

    func testDocumentSearchIsFindOnlyAndKeepsScrollableFileTabsMountedInThePrimaryRow() {
        let theme = AppTheme.defaultDark
        var search = DocumentSearchState()
        search.present()
        let tab = WorkspaceTabItem(
            documentID: "/README.md",
            displayName: "README.md",
            relativePath: "README.md",
            kind: .markdown
        )
        let topBar = TopNavigationBar(
            editorMode: .constant(.source),
            isSplitViewEnabled: .constant(false),
            emptyStateTitle: "Monknot",
            selectedDocument: nil,
            isBusy: false,
            isDocumentLoading: false,
            isSaving: false,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            isTerminalPresented: false,
            isSidebarVisible: true,
            toggleTerminal: {},
            toggleSidebar: {},
            toggleSplitView: {},
            documentSearch: .constant(search),
            searchOptions: .constant(MonknotSearchOptions()),
            dismissDocumentSearch: {},
            documentSearchFocusChanged: { _ in },
            tabs: [tab],
            activeTabID: tab.documentID,
            missingTabIDs: [],
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePinTab: { _ in },
            reorderTab: { _, _ in }
        )
        let host = NSHostingView(rootView: topBar.frame(width: 920))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.allDescendantsForTesting().contains { $0 is NSScrollView },
            "File tabs must retain horizontal scrolling while document search is visible"
        )
        XCTAssertEqual(
            host.allDescendantsForTesting().filter { $0 is NSTextField }.count,
            1,
            "The in-document search bar must expose only its find field"
        )
        XCTAssertEqual(
            host.fittingSize.height,
            MonknotMetrics.chromeHeight(theme: theme, zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.01
        )
    }

    func testDocumentTabsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let tabBar = DocumentTabBar(
                tabs: [
                    WorkspaceTabItem(
                        documentID: "/README.md",
                        displayName: "README.md",
                        relativePath: "README.md",
                        kind: .markdown
                    )
                ],
                selectedDocumentID: "/README.md",
                missingDocumentIDs: [],
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: false,
                saveState: { _ in .clean },
                selectTab: { _ in },
                closeTab: { _ in },
                togglePin: { _ in },
                reorderTab: { _, _ in }
            )
            let host = NSHostingView(rootView: tabBar.frame(width: 600))

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Tab chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    func testHorizontalTabOverflowStateReportsOnlyClippedTabsAndCorrectEdges() {
        let state = HorizontalTabOverflowState(
            frames: [
                "left": CGRect(x: -36, y: 0, width: 100, height: 44),
                "middle": CGRect(x: 64, y: 0, width: 100, height: 44),
                "right": CGRect(x: 164, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 220
        )

        XCTAssertEqual(state.hiddenIDs, ["left", "right"])
        XCTAssertTrue(state.hasLeadingOverflow)
        XCTAssertTrue(state.hasTrailingOverflow)
        XCTAssertEqual(state.revealEdge(for: "left"), .leading)
        XCTAssertNil(state.revealEdge(for: "middle"))
        XCTAssertEqual(state.revealEdge(for: "right"), .trailing)
    }

    func testHorizontalTabOverflowStateStaysQuietWhenEveryTabFits() {
        let state = HorizontalTabOverflowState(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 44),
                "b": CGRect(x: 100, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 200
        )

        XCTAssertTrue(state.hiddenIDs.isEmpty)
        XCTAssertFalse(state.hasLeadingOverflow)
        XCTAssertFalse(state.hasTrailingOverflow)
        XCTAssertNil(state.revealEdge(for: "a"))
        XCTAssertNil(state.revealEdge(for: "b"))
    }

    func testHorizontalTabRevealRequestIsOneShotSoManualScrollingRemainsAuthoritative() {
        var request = HorizontalTabRevealRequest()
        let frames = [
            "left": CGRect(x: -80, y: 0, width: 70, height: 28),
            "active": CGRect(x: 140, y: 0, width: 70, height: 28)
        ]

        request.request("active")
        let action = request.consume(frames: frames, viewportWidth: 180)

        XCTAssertEqual(action?.id, "active")
        XCTAssertEqual(action?.edge, .trailing)
        XCTAssertNil(request.pendingID)
        XCTAssertNil(request.consume(frames: frames, viewportWidth: 180))
    }

    func testHorizontalTabRevealRequestWaitsForMeasurementAndConsumesVisibleTabs() {
        var request = HorizontalTabRevealRequest()
        request.request("active")

        XCTAssertNil(request.consume(frames: [:], viewportWidth: 180))
        XCTAssertEqual(request.pendingID, "active")

        XCTAssertNil(request.consume(
            frames: ["active": CGRect(x: 40, y: 0, width: 70, height: 28)],
            viewportWidth: 180
        ))
        XCTAssertNil(request.pendingID)
    }

    func testMouseWheelNotchBecomesHorizontalButTrackpadAndModifiedWheelsPassThrough() throws {
        let notch = try XCTUnwrap(Self.wheelEvent(units: .line, vertical: -3))
        let horizontal = try XCTUnwrap(HorizontalTabWheelScrolling.horizontalEvent(for: notch))
        XCTAssertEqual(horizontal.scrollingDeltaY, 0)
        XCTAssertEqual(horizontal.scrollingDeltaX, notch.scrollingDeltaY, accuracy: 0.001)
        XCTAssertNotEqual(horizontal.scrollingDeltaX, 0)

        let trackpad = try XCTUnwrap(Self.wheelEvent(units: .pixel, vertical: -12))
        XCTAssertTrue(trackpad.hasPreciseScrollingDeltas)
        XCTAssertNil(HorizontalTabWheelScrolling.horizontalEvent(for: trackpad))

        let shiftWheel = try XCTUnwrap(Self.wheelEvent(units: .line, vertical: -3, flags: .maskShift))
        XCTAssertNil(
            HorizontalTabWheelScrolling.horizontalEvent(for: shiftWheel),
            "AppKit already turns ⇧-wheel into a horizontal scroll"
        )
        let commandWheel = try XCTUnwrap(Self.wheelEvent(units: .line, vertical: -3, flags: .maskCommand))
        XCTAssertNil(HorizontalTabWheelScrolling.horizontalEvent(for: commandWheel))
    }

    func testMouseWheelOverOverflowingTabStripScrollsItSideways() async throws {
        let theme = AppTheme.defaultDark
        let tabs = (0..<12).map { index in
            WorkspaceTabItem(
                documentID: "tab-\(index)",
                displayName: "Long production document \(index).md",
                relativePath: "Long production document \(index).md",
                kind: .markdown
            )
        }
        let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: 1)
        let host = NSHostingView(rootView: DocumentTabBar(
            tabs: tabs,
            selectedDocumentID: tabs[0].documentID,
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: 1,
            isDisabled: false,
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePin: { _ in },
            reorderTab: { _, _ in }
        ).frame(width: 400, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: chromeHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let bridge = try XCTUnwrap(
            host.allDescendantsForTesting().compactMap { $0 as? HorizontalTabWheelScrolling.MonitorView }.first
        )
        let scrollView = try XCTUnwrap(bridge.enclosingScrollView)
        let start = scrollView.contentView.bounds.origin.x

        let inside = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        let notch = try XCTUnwrap(Self.wheelEvent(units: .line, vertical: -3))
        XCTAssertTrue(bridge.scrollStrip(for: notch, at: inside))
        // AppKit animates line scrolls, as it does for any mouse wheel.
        for _ in 0..<20 where scrollView.contentView.bounds.origin.x <= start {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, start, "Wheel down reveals later tabs")

        let trackpad = try XCTUnwrap(Self.wheelEvent(units: .pixel, vertical: -12))
        XCTAssertFalse(
            bridge.scrollStrip(for: trackpad, at: inside),
            "A trackpad's vertical swipe over the strip stays inert"
        )
        let outside = NSPoint(x: inside.x, y: inside.y + 200)
        XCTAssertFalse(bridge.scrollStrip(for: notch, at: outside), "Only a wheel over the strip moves it")
        withExtendedLifetime(window) {}
    }

    private static func wheelEvent(
        units: CGScrollEventUnit,
        vertical: Int32,
        flags: CGEventFlags = []
    ) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 1,
            wheel1: vertical,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        cgEvent.flags = flags
        return NSEvent(cgEvent: cgEvent)
    }

    func testMountedDocumentTabBarSupportsHorizontalScrolling() async {
        let theme = AppTheme.defaultDark
        let tabs = (0..<10).map { index in
            WorkspaceTabItem(
                documentID: "tab-\(index)",
                displayName: "Long production document \(index).md",
                relativePath: "Long production document \(index).md",
                kind: .markdown
            )
        }
        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: DocumentTabBar(
            tabs: tabs,
            selectedDocumentID: tabs[0].documentID,
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            isDisabled: false,
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePin: { _ in },
            reorderTab: { _, _ in }
        ).frame(width: 320, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Overflowing file tabs must remain available in a horizontal scroll strip")
        }
        XCTAssertGreaterThan(
            documentView.frame.width - horizontalScrollView.contentView.bounds.width,
            500,
            "The tab strip should retain its full content width instead of hiding excess tabs"
        )
    }
}
