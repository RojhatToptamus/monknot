import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitSwiftUIBridgeTests: WorkspaceSplitViewTestCase {
    func testNativePaneHostsDoNotPublishIntrinsicConstraintsIntoTheSplitOwner() {
        let controller = makeController()

        XCTAssertTrue(controller.sidebarHostingController.sizingOptions.isEmpty)
        XCTAssertTrue(controller.detailHostingController.sizingOptions.isEmpty)
        XCTAssertTrue(controller.terminalHostingController.sizingOptions.isEmpty)
    }

    func testNativePaneHostsExposeStableResponderRegions() {
        let controller = makeController()

        XCTAssertEqual(
            controller.sidebarHostingController.view.identifier,
            .monknotSidebarFocusRegion
        )
        XCTAssertEqual(
            controller.terminalHostingController.view.identifier,
            .monknotTerminalFocusRegion
        )
    }

    func testOpeningSettingsWindowLetsMountedWorkspaceLayoutBecomeQuiescent() throws {
        let defaultsName = "WorkspaceSplitViewTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themeStore = ThemeSettingsStore(defaults: defaults)
        let workspaceStore = WorkspaceStore(userDefaults: defaults)
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        defer { withExtendedLifetime(updaterController) {} }
        let workspaceHost = LayoutCountingHostingView(
            rootView: ContentView(
                store: workspaceStore,
                themeStore: themeStore,
                terminationCoordinator: ApplicationTerminationCoordinator()
            )
                .frame(minWidth: 920, minHeight: 620)
        )
        let workspaceWindow = UnconstrainedSplitTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_300, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            workspaceWindow.orderOut(nil)
            workspaceWindow.contentView = nil
        }
        workspaceWindow.contentView = workspaceHost
        workspaceWindow.setContentSize(NSSize(width: 1_300, height: 720))
        workspaceWindow.makeKeyAndOrderFront(nil)
        workspaceWindow.layoutIfNeeded()
        workspaceHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: workspaceHost)
        )
        let initialSplitFrame = splitView.frame
        let initialPaneViews = splitView.arrangedSubviews
        XCTAssertEqual(initialPaneViews.count, 3)
        XCTAssertGreaterThan(initialSplitFrame.width, 0)
        XCTAssertGreaterThan(initialSplitFrame.height, 0)

        let settingsHost = LayoutCountingHostingView(
            rootView: PreferencesView(
                themeStore: themeStore,
                updater: updaterController.updater
            )
        )
        let settingsSize = settingsHost.fittingSize
        let settingsWindow = UnconstrainedSplitTestWindow(
            contentRect: NSRect(origin: .zero, size: settingsSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            settingsWindow.orderOut(nil)
            settingsWindow.contentView = nil
        }
        settingsWindow.contentView = settingsHost
        settingsWindow.contentMinSize = settingsSize
        settingsWindow.contentMaxSize = settingsSize

        let splitResizeActivity = WorkspaceSizingActivity()
        let splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { _ in
            splitResizeActivity.recordSplitResize()
        }
        defer { NotificationCenter.default.removeObserver(splitResizeObserver) }

        workspaceHost.resetLayoutCounts()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.layoutIfNeeded()
        settingsHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let settledSplitFrame = splitView.frame

        // Ignore the finite initial settings transaction. With no input or
        // state change, another run-loop interval must not keep measuring the
        // workspace or resizing its native split panes.
        splitResizeActivity.reset()
        workspaceHost.resetLayoutCounts()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertLessThanOrEqual(workspaceHost.layoutCallCount, 2)
        XCTAssertLessThanOrEqual(workspaceHost.updateConstraintsCallCount, 2)
        XCTAssertLessThanOrEqual(splitResizeActivity.splitResizeCount, 1)
        XCTAssertEqual(splitView.frame, settledSplitFrame)
        XCTAssertTrue(
            zip(splitView.arrangedSubviews, initialPaneViews).allSatisfy { $0 === $1 }
        )
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
    }

    func testSwiftUIBridgeHonorsWideHostProposalInsteadOfIntrinsicSplitWidth() throws {
        let rootView = WorkspaceSplitView(
            isSidebarPresented: true,
            isTerminalPresented: true,
            layoutScale: 1,
            separatorColor: .separatorColor,
            accentColor: .controlAccentColor,
            onSidebarPresentationChange: { _, _ in },
            onTerminalPresentationChange: { _, _ in },
            sidebar: { Color.red },
            detail: { Color.blue },
            terminal: { Color.black }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        let window = UnconstrainedSplitTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(NSSize(width: 1_600, height: 620))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let nativeSplitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        XCTAssertEqual(host.bounds.width, 1_600, accuracy: 1)
        XCTAssertEqual(nativeSplitView.bounds.width, host.bounds.width, accuracy: 1)
    }

    func testMountedBridgeKeepsVisiblePaneSubtreeAfterResettingZoomWithTerminalHidden() throws {
        for width in [CGFloat(1_300), 1_600] {
            let model = MountedSplitZoomModel()
            let host = NSHostingView(rootView: MountedSplitZoomFixture(model: model))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
            let window = UnconstrainedSplitTestWindow(
                contentRect: host.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            window.setContentSize(host.frame.size)
            layoutMountedSplitHost(window: window, host: host)

            let splitView = try XCTUnwrap(
                firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
            )
            let arrangedSubviews = splitView.arrangedSubviews
            let initialSplitHeight = splitView.bounds.height
            let geometryObservation = MountedSplitGeometryObservation()
            splitView.postsFrameChangedNotifications = true
            let frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: splitView,
                queue: .main
            ) { [weak splitView] _ in
                MainActor.assumeIsolated {
                    guard let splitView else { return }
                    if splitView.frame.width <= 0 || splitView.frame.height <= 0 {
                        geometryObservation.sawZeroFrame = true
                    }
                }
            }
            XCTAssertEqual(arrangedSubviews.count, 3)
            XCTAssertFalse(splitView.isHidden)
            XCTAssertFalse(arrangedSubviews[0].isHidden)
            XCTAssertFalse(arrangedSubviews[1].isHidden)
            XCTAssertTrue(arrangedSubviews[2].isHidden)
            XCTAssertEqual(splitView.bounds.width, host.bounds.width, accuracy: 1)
            XCTAssertGreaterThan(initialSplitHeight, 0)
            XCTAssertGreaterThan(arrangedSubviews[0].frame.width, 0)
            XCTAssertGreaterThan(arrangedSubviews[1].frame.width, 0)

            model.layoutScale = 1
            layoutMountedSplitHost(window: window, host: host)

            let resetSplitView = try XCTUnwrap(
                firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
            )
            XCTAssertTrue(resetSplitView === splitView)
            XCTAssertEqual(resetSplitView.arrangedSubviews.count, 3)
            XCTAssertTrue(
                zip(resetSplitView.arrangedSubviews, arrangedSubviews).allSatisfy { $0 === $1 }
            )
            XCTAssertFalse(resetSplitView.isHidden)
            XCTAssertEqual(resetSplitView.bounds.width, host.bounds.width, accuracy: 1)
            XCTAssertEqual(resetSplitView.bounds.height, initialSplitHeight, accuracy: 1)
            XCTAssertFalse(resetSplitView.arrangedSubviews[0].isHidden)
            XCTAssertFalse(resetSplitView.arrangedSubviews[1].isHidden)
            XCTAssertTrue(resetSplitView.arrangedSubviews[2].isHidden)
            XCTAssertGreaterThan(resetSplitView.arrangedSubviews[0].frame.width, 0)
            XCTAssertGreaterThan(resetSplitView.arrangedSubviews[1].frame.width, 0)
            XCTAssertFalse(
                geometryObservation.sawZeroFrame,
                "A partially unspecified SwiftUI proposal must not become a zero representable frame during zoom reset"
            )
            NotificationCenter.default.removeObserver(frameObserver)
            window.contentView = nil
        }
    }

    func testSwiftUIFeedbackDuringAnOutwardDragDoesNotRecollapseTheSidebar() throws {
        let model = LiveSplitFeedbackModel()
        let host = NSHostingView(rootView: LiveSplitFeedbackFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1_600, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        XCTAssertTrue(splitView.arrangedSubviews[0].isHidden)
        model.sidebarEvents.removeAll()

        try dragDivider(0, to: 360, in: splitView, window: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertTrue(model.sidebarEffective)
        XCTAssertFalse(
            model.sidebarEvents.contains(
                PresentationEvent(isPresented: true, userInitiated: false)
            ),
            "Mouse-up's final user event must subsume an undelivered automatic intermediate event"
        )
        XCTAssertEqual(
            model.sidebarEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
    }

    func testNarrowSwiftUIFeedbackKeepsTheOppositePanePressureCollapsedAfterReveal() throws {
        let model = LiveSplitFeedbackModel()
        let host = NSHostingView(rootView: LiveSplitFeedbackFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 940, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        XCTAssertTrue(splitView.arrangedSubviews[0].isHidden)
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)
        model.sidebarEvents.removeAll()
        model.terminalEvents.removeAll()
        let terminalCollapseThreshold = splitView.bounds.width
            - 2 * splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
                * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 20,
            in: splitView,
            window: window
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(
            splitView.arrangedSubviews[2].isHidden,
            "SwiftUI feedback during the outward drag must not clear the opposite divider-pressure collapse"
        )
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[0].frame.width,
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertTrue(model.sidebarEffective)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertEqual(
            model.sidebarEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
        XCTAssertTrue(model.terminalEvents.contains(
            PresentationEvent(isPresented: false, userInitiated: false)
        ))
    }

    func testMountedScaleIncreaseKeepsTheSplitInsideItsHostWhileTerminalPressureCollapses() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: true
        )
        let allocationWidth: CGFloat = 1_230
        let host = NSHostingView(rootView: MountedConstrainedScaleFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: allocationWidth, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(host.frame.size)
        defer { window.contentView = nil }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let initialPaneViews = splitView.arrangedSubviews
        let initialTerminalWidth = initialPaneViews[2].frame.width
        let geometry = MountedSplitWidthObservation()
        let observers = observeSplitWidthChanges(splitView, recording: geometry)
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        XCTAssertEqual(host.bounds.width, allocationWidth, accuracy: 1)
        XCTAssertEqual(splitView.bounds.width, allocationWidth, accuracy: 1)
        XCTAssertFalse(initialPaneViews[0].isHidden)
        XCTAssertFalse(initialPaneViews[2].isHidden)

        model.layoutScale = 2
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertTrue(splitView === firstDescendant(of: WorkspaceNativeSplitView.self, in: host))
        XCTAssertTrue(
            zip(splitView.arrangedSubviews, initialPaneViews).allSatisfy { $0 === $1 },
            "Zoom must update the existing native split items instead of replacing the layout owner"
        )
        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertTrue(model.sidebarEffective)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[0].frame.width,
            WorkspaceSplitMetrics.sidebarMinimumWidth * 2 - 1
        )
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[1].frame.width,
            WorkspaceSplitMetrics.detailMinimumWidth * 2 - 1
        )

        model.layoutScale = 1
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.terminalEffective)
        XCTAssertEqual(
            splitView.arrangedSubviews[2].frame.width,
            initialTerminalWidth,
            accuracy: 2,
            "Zooming down must reveal the pressure-hidden terminal at its retained useful width"
        )
    }

    func testPreferredTerminalSubtreeStaysMountedAcrossPressureCollapseAndRestore() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: true
        )
        let lifecycle = MountedTerminalLifecycleObservation()
        let host = NSHostingView(
            rootView: MountedConstrainedScaleFixture(
                model: model,
                terminalLifecycle: lifecycle
            )
        )
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1_600, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(host.frame.size)
        defer { window.contentView = nil }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let mountedTerminalView = try XCTUnwrap(lifecycle.view)
        XCTAssertEqual(lifecycle.mountCount, 1)
        XCTAssertEqual(lifecycle.dismantleCount, 0)
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)

        window.setContentSize(NSSize(width: 850, height: 620))
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertTrue(model.terminalPreferred)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(lifecycle.view === mountedTerminalView)
        XCTAssertEqual(lifecycle.mountCount, 1)
        XCTAssertEqual(lifecycle.dismantleCount, 0)

        window.setContentSize(NSSize(width: 1_600, height: 620))
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertTrue(model.terminalEffective)
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(lifecycle.view === mountedTerminalView)
        XCTAssertEqual(lifecycle.mountCount, 1)
        XCTAssertEqual(lifecycle.dismantleCount, 0)
    }

    func testMountedScaleIncreasePreservesAUserHiddenTerminalWhileSidebarPressureCollapses() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: false
        )
        let allocationWidth: CGFloat = 1_100
        let host = NSHostingView(rootView: MountedConstrainedScaleFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: allocationWidth, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(host.frame.size)
        defer { window.contentView = nil }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let usefulSidebarWidth: CGFloat = 360
        splitView.setPosition(usefulSidebarWidth, ofDividerAt: 0)
        layoutMountedSplitHost(window: window, host: host)
        let initialSidebarWidth = splitView.arrangedSubviews[0].frame.width
        XCTAssertEqual(initialSidebarWidth, usefulSidebarWidth, accuracy: 2)
        let geometry = MountedSplitWidthObservation()
        let observers = observeSplitWidthChanges(splitView, recording: geometry)
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)

        model.layoutScale = 2
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertTrue(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertFalse(model.terminalPreferred)
        XCTAssertFalse(model.sidebarEffective)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[1].frame.width,
            WorkspaceSplitMetrics.detailMinimumWidth * 2 - 1
        )

        model.layoutScale = 1
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.sidebarEffective)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertEqual(
            splitView.arrangedSubviews[0].frame.width,
            initialSidebarWidth,
            accuracy: 2,
            "Zooming down must restore the sidebar without reopening a user-hidden terminal"
        )
    }

    func testMountedScaledOutwardTerminalDragCannotInflateTheSplitPastItsHost() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: true
        )
        let allocationWidth: CGFloat = 1_800
        let host = NSHostingView(rootView: MountedConstrainedScaleFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: allocationWidth, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMaxSize = NSSize(width: allocationWidth, height: 10_000)
        window.maxSize = NSSize(width: allocationWidth, height: 10_000)
        window.contentView = host
        window.setContentSize(host.frame.size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let initialTerminalWidth = splitView.arrangedSubviews[2].frame.width
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)

        model.layoutScale = 2
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertEqual(splitView.bounds.width, allocationWidth, accuracy: 1)
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)

        let geometry = MountedSplitWidthObservation()
        let observers = observeSplitWidthChanges(splitView, recording: geometry)
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let attemptedTerminalWidth: CGFloat = 576
        try dragDivider(
            1,
            to: splitView.bounds.width
                - attemptedTerminalWidth
                - splitView.dividerThickness,
            in: splitView,
            window: window
        )
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        let scaledSidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * 2
        let scaledDetailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * 2
        let scaledTerminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * 2
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[1].frame.width,
            scaledDetailMinimum - 1
        )
        if !splitView.arrangedSubviews[0].isHidden {
            XCTAssertGreaterThanOrEqual(
                splitView.arrangedSubviews[0].frame.width,
                scaledSidebarMinimum - 1
            )
        }
        if !splitView.arrangedSubviews[2].isHidden {
            XCTAssertGreaterThanOrEqual(
                splitView.arrangedSubviews[2].frame.width,
                scaledTerminalMinimum - 1
            )
        }
        XCTAssertTrue(
            splitView.arrangedSubviews[2].isHidden,
            "The lowest-priority terminal must stay pressure-collapsed when its scaled minimum cannot fit"
        )
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertFalse(model.terminalEffective)

        model.layoutScale = 1
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertFalse(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertTrue(model.terminalEffective)
        XCTAssertEqual(
            splitView.arrangedSubviews[2].frame.width,
            initialTerminalWidth,
            accuracy: 2,
            "Zooming down must restore the pressure-hidden terminal at its retained useful width"
        )
    }

    func testMountedScaledOutwardSidebarDragPreservesShowIntentUntilItCanFit() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: false
        )
        let allocationWidth: CGFloat = 1_100
        let host = NSHostingView(rootView: MountedConstrainedScaleFixture(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: allocationWidth, height: 620)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMaxSize = NSSize(width: allocationWidth, height: 10_000)
        window.maxSize = NSSize(width: allocationWidth, height: 10_000)
        window.contentView = host
        window.setContentSize(host.frame.size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let usefulSidebarWidth: CGFloat = 360
        splitView.setPosition(usefulSidebarWidth, ofDividerAt: 0)
        layoutMountedSplitHost(window: window, host: host)
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, usefulSidebarWidth, accuracy: 2)
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)

        model.layoutScale = 2
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertEqual(splitView.bounds.width, allocationWidth, accuracy: 1)
        XCTAssertTrue(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        let geometry = MountedSplitWidthObservation()
        let observers = observeSplitWidthChanges(splitView, recording: geometry)
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        try dragDivider(
            0,
            to: 440,
            in: splitView,
            window: window
        )
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertTrue(
            splitView.arrangedSubviews[0].isHidden,
            "An infeasible outward show drag must return the sidebar to pressure-collapsed state"
        )
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertGreaterThanOrEqual(
            splitView.arrangedSubviews[1].frame.width,
            WorkspaceSplitMetrics.detailMinimumWidth * 2 - 1
        )
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertFalse(model.sidebarEffective)
        XCTAssertFalse(model.terminalPreferred)
        XCTAssertFalse(model.terminalEffective)

        model.layoutScale = 1
        layoutMountedSplitHost(window: window, host: host)

        assertMountedSplitFitsAllocation(
            splitView,
            host: host,
            allocationWidth: allocationWidth,
            observation: geometry
        )
        XCTAssertFalse(splitView.arrangedSubviews[0].isHidden)
        XCTAssertTrue(splitView.arrangedSubviews[2].isHidden)
        XCTAssertTrue(model.sidebarPreferred)
        XCTAssertTrue(model.sidebarEffective)
        XCTAssertFalse(model.terminalPreferred)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertEqual(
            splitView.arrangedSubviews[0].frame.width,
            usefulSidebarWidth,
            accuracy: 2,
            "Zooming down must restore the pressure-hidden sidebar at its retained useful width"
        )
    }

    func testMountedWindowResizeRestoresBothUserPaneWidthsAfterTerminalPressureCollapse() throws {
        let model = MountedConstrainedScaleModel(
            sidebarPreferred: true,
            terminalPreferred: true
        )
        let host = NSHostingView(
            rootView: MountedConstrainedScaleFixture(model: model)
                .frame(minWidth: 920, minHeight: 620)
        )
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1_600, height: 720)
        let window = UnconstrainedSplitTestWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(host.frame.size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        layoutMountedSplitHost(window: window, host: host)

        let splitView = try XCTUnwrap(
            firstDescendant(of: WorkspaceNativeSplitView.self, in: host)
        )
        let splitController = try XCTUnwrap(splitView.delegate as? NSSplitViewController)
        XCTAssertEqual(splitController.splitViewItems.count, 3)
        let paneViews = splitView.arrangedSubviews
        let requestedSidebarWidth: CGFloat = 330
        let requestedTerminalWidth: CGFloat = 430

        // Seed two legal user widths through the authoritative native divider
        // API. The temporary setup priority makes detail absorb the coupled
        // writes instead of letting one setup write alter the other peripheral.
        let detailHoldingPriority = splitController.splitViewItems[1].holdingPriority
        splitController.splitViewItems[1].holdingPriority = .defaultLow
        splitView.setPosition(
            splitView.bounds.width - requestedTerminalWidth - splitView.dividerThickness,
            ofDividerAt: 1
        )
        layoutMountedSplitHost(window: window, host: host)
        splitView.setPosition(requestedSidebarWidth, ofDividerAt: 0)
        layoutMountedSplitHost(window: window, host: host)
        splitController.splitViewItems[1].holdingPriority = detailHoldingPriority

        let usefulSidebarWidth = paneViews[0].frame.width
        let usefulTerminalWidth = paneViews[2].frame.width
        XCTAssertEqual(usefulSidebarWidth, requestedSidebarWidth, accuracy: 2)
        XCTAssertEqual(usefulTerminalWidth, requestedTerminalWidth, accuracy: 2)
        XCTAssertFalse(paneViews[0].isHidden)
        XCTAssertFalse(paneViews[2].isHidden)

        window.setContentSize(NSSize(width: 920, height: 720))
        layoutMountedSplitHost(window: window, host: host)

        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 920, accuracy: 1)
        XCTAssertEqual(host.bounds.width, 920, accuracy: 1)
        XCTAssertEqual(splitView.bounds.width, 920, accuracy: 1)
        XCTAssertFalse(paneViews[0].isHidden)
        XCTAssertTrue(paneViews[2].isHidden)
        XCTAssertTrue(model.terminalPreferred)
        XCTAssertFalse(model.terminalEffective)
        XCTAssertEqual(paneViews[0].frame.width, usefulSidebarWidth, accuracy: 2)
        normalizeHiddenPaneToMinimum(splitController.splitViewItems[2], in: splitController)

        let widthsBeforeRetainedPanesFit: [CGFloat] = [940, 1_000, 1_100]
        for width in widthsBeforeRetainedPanesFit {
            window.setContentSize(NSSize(width: width, height: 720))
            layoutMountedSplitHost(window: window, host: host)

            XCTAssertEqual(window.contentView?.bounds.width ?? 0, width, accuracy: 1)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            XCTAssertEqual(splitView.bounds.width, width, accuracy: 1)
            XCTAssertFalse(paneViews[0].isHidden)
            XCTAssertTrue(
                paneViews[2].isHidden,
                "The terminal must stay pressure-collapsed until both retained peripheral widths and the detail minimum fit"
            )
            XCTAssertEqual(
                paneViews[0].frame.width,
                usefulSidebarWidth,
                accuracy: 2,
                "Incremental window growth must not replace the user's sidebar width"
            )
        }

        let widthsAfterRetainedPanesFit: [CGFloat] = [1_160, 1_300, 1_500, 1_800]
        for width in widthsAfterRetainedPanesFit {
            window.setContentSize(NSSize(width: width, height: 720))
            layoutMountedSplitHost(window: window, host: host)

            XCTAssertEqual(window.contentView?.bounds.width ?? 0, width, accuracy: 1)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            XCTAssertEqual(splitView.bounds.width, width, accuracy: 1)
            XCTAssertFalse(paneViews[0].isHidden)
            XCTAssertFalse(
                paneViews[2].isHidden,
                "The terminal must restore once both retained peripheral widths and the detail minimum fit"
            )
            XCTAssertTrue(model.terminalEffective)
            XCTAssertEqual(
                paneViews[0].frame.width,
                usefulSidebarWidth,
                accuracy: 2,
                "Expanding a real window must not replace the user's sidebar width with its maximum"
            )
            XCTAssertEqual(
                paneViews[2].frame.width,
                usefulTerminalWidth,
                accuracy: 2,
                "Expanding a real window must restore the terminal's retained native width"
            )
        }
    }
}
