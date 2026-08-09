import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitViewTests: XCTestCase {
    func testNativePaneHostsDoNotPublishIntrinsicConstraintsIntoTheSplitOwner() {
        let controller = makeController()

        XCTAssertTrue(controller.sidebarHostingController.sizingOptions.isEmpty)
        XCTAssertTrue(controller.detailHostingController.sizingOptions.isEmpty)
        XCTAssertTrue(controller.terminalHostingController.sizingOptions.isEmpty)
    }

    func testOpeningSettingsWindowLetsMountedWorkspaceLayoutBecomeQuiescent() throws {
        let defaultsName = "WorkspaceSplitViewTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themeStore = ThemeSettingsStore(defaults: defaults)
        let workspaceStore = WorkspaceStore()
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

    func testNativeThreePaneOwnerDefinesLegalCollisionPriorities() {
        let controller = makeController()
        _ = controller.view

        XCTAssertTrue(controller.splitView is WorkspaceNativeSplitView)
        XCTAssertTrue(controller.splitView.isVertical)
        XCTAssertEqual(controller.splitView.dividerStyle, .thin)
        XCTAssertEqual(controller.splitViewItems.count, 3)
        XCTAssertEqual(controller.splitView.arrangedSubviews.count, 3)

        let priorities = [
            controller.sidebarItem.holdingPriority,
            controller.detailItem.holdingPriority,
            controller.terminalItem.holdingPriority,
        ]
        XCTAssertTrue(priorities.allSatisfy { $0.rawValue < 490 })
        XCTAssertLessThan(
            controller.detailItem.holdingPriority.rawValue,
            controller.sidebarItem.holdingPriority.rawValue,
            "The center must absorb container growth before AppKit replaces the user's sidebar width"
        )
        XCTAssertLessThan(
            controller.detailItem.holdingPriority.rawValue,
            controller.terminalItem.holdingPriority.rawValue,
            "The center must absorb container growth before AppKit replaces the terminal width"
        )
        XCTAssertGreaterThan(
            controller.sidebarItem.holdingPriority.rawValue,
            controller.terminalItem.holdingPriority.rawValue,
            "The terminal must yield before the sidebar when both peripheral panes compete"
        )

        XCTAssertTrue(controller.sidebarItem.canCollapse)
        XCTAssertFalse(controller.detailItem.canCollapse)
        XCTAssertTrue(controller.terminalItem.canCollapse)
        XCTAssertEqual(controller.sidebarItem.minimumThickness, WorkspaceSplitMetrics.sidebarMinimumWidth)
        XCTAssertEqual(controller.detailItem.minimumThickness, WorkspaceSplitMetrics.detailMinimumWidth)
        XCTAssertEqual(controller.terminalItem.minimumThickness, WorkspaceSplitMetrics.terminalMinimumWidth)
        XCTAssertEqual(controller.sidebarItem.preferredThicknessFraction, NSSplitViewItem.unspecifiedDimension)
        XCTAssertEqual(controller.terminalItem.preferredThicknessFraction, NSSplitViewItem.unspecifiedDimension)
    }

    func testSplitLayoutScaleNormalizationUsesWorkspaceZoomPolicyForAllNumericInputs() {
        let inputs: [CGFloat] = [0.25, 1.35, 4, .infinity, -.infinity, .nan]

        for input in inputs {
            XCTAssertEqual(
                WorkspaceSplitMetrics.normalizedScale(input),
                CGFloat(WorkspaceZoomPolicy.clamp(Double(input))),
                accuracy: 0.000_1,
                "Split layout normalization must share the authoritative workspace zoom policy for \(input)"
            )
        }
    }

    func testNativeDividerHitRectsAreWiderThanTheirDividersAndGrowIntoTheCenter() throws {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)

        let leftBoundary = splitView.arrangedSubviews[0].frame.maxX
        let rightBoundary = splitView.arrangedSubviews[1].frame.maxX
        let leftHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        let rightHitRect = splitView.centerBiasedHitRect(forDividerAt: 1)
        let leftEffectiveRect = controller.splitView(
            splitView,
            effectiveRect: .zero,
            forDrawnRect: NSRect(
                x: leftBoundary,
                y: splitView.bounds.minY,
                width: splitView.dividerThickness,
                height: splitView.bounds.height
            ),
            ofDividerAt: 0
        )
        let rightEffectiveRect = controller.splitView(
            splitView,
            effectiveRect: .zero,
            forDrawnRect: NSRect(
                x: rightBoundary,
                y: splitView.bounds.minY,
                width: splitView.dividerThickness,
                height: splitView.bounds.height
            ),
            ofDividerAt: 1
        )

        XCTAssertGreaterThan(leftHitRect.width, splitView.dividerThickness)
        XCTAssertEqual(leftEffectiveRect, leftHitRect.intersection(splitView.bounds))
        XCTAssertEqual(leftHitRect.minX, leftBoundary, accuracy: 0.001)
        XCTAssertGreaterThan(leftHitRect.maxX, leftBoundary + splitView.dividerThickness)
        XCTAssertTrue(splitView.acceptsFirstMouse(for: nil))
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: leftHitRect.midX, y: leftHitRect.midY)) === splitView
        )

        XCTAssertGreaterThan(rightHitRect.width, splitView.dividerThickness)
        XCTAssertEqual(rightEffectiveRect, rightHitRect.intersection(splitView.bounds))
        XCTAssertLessThan(rightHitRect.minX, rightBoundary)
        XCTAssertEqual(
            rightHitRect.maxX,
            rightBoundary + splitView.dividerThickness,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            rightHitRect.maxX,
            splitView.arrangedSubviews[2].frame.minX,
            "The terminal-side hit target must grow into the center, not over the terminal scrollbar"
        )
        _ = window
    }

    func testNativeDividerHoverAndActiveStatesFollowPointerTracking() throws {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)
        splitView.updateTrackingAreas()

        XCTAssertTrue(splitView.trackingAreas.contains { trackingArea in
            trackingArea.options.contains(.activeInActiveApp)
                && trackingArea.options.contains(.inVisibleRect)
                && trackingArea.options.contains(.mouseMoved)
        })

        let leftHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        let hoverEvent = try XCTUnwrap(mouseEvent(
            type: .mouseMoved,
            location: splitView.convert(
                NSPoint(x: leftHitRect.midX, y: leftHitRect.midY),
                to: nil
            ),
            windowNumber: window.windowNumber
        ))
        splitView.mouseMoved(with: hoverEvent)
        XCTAssertEqual(splitView.hoveredDividerIndex, 0)

        let leaveEvent = try XCTUnwrap(mouseEvent(
            type: .mouseMoved,
            location: splitView.convert(
                NSPoint(x: splitView.bounds.midX, y: splitView.bounds.midY),
                to: nil
            ),
            windowNumber: window.windowNumber
        ))
        splitView.mouseMoved(with: leaveEvent)
        XCTAssertNil(splitView.hoveredDividerIndex)

        let observation = DividerTrackingObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak splitView] _ in
            MainActor.assumeIsolated {
                if splitView?.activeDividerIndex == 0,
                   splitView?.hoveredDividerIndex == 0 {
                    observation.sawActiveAndHoveredDivider = true
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try dragDivider(
            0,
            to: splitView.arrangedSubviews[0].frame.maxX + 24,
            in: splitView,
            window: window
        )

        XCTAssertTrue(observation.sawActiveAndHoveredDivider)
        XCTAssertNil(splitView.activeDividerIndex)
    }

    func testNativeSetPositionChangesBothPeripheralWidths() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)

        let initialSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let sidebarTarget: CGFloat = initialSidebarWidth > 350 ? 300 : 380
        controller.splitView.setPosition(sidebarTarget, ofDividerAt: 0)
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), sidebarTarget, accuracy: 1)
        XCTAssertNotEqual(paneWidth(controller.sidebarItem, in: controller), initialSidebarWidth, accuracy: 1)

        let initialTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        let terminalTarget: CGFloat = initialTerminalWidth > 440 ? 380 : 460
        controller.splitView.setPosition(
            controller.splitView.bounds.width - terminalTarget,
            ofDividerAt: 1
        )
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), terminalTarget, accuracy: 4)
        XCTAssertNotEqual(paneWidth(controller.terminalItem, in: controller), initialTerminalWidth, accuracy: 1)
    }

    func testSidebarCollapseReleasesItsSpaceAndRevealRestoresUsefulWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(360, ofDividerAt: 0)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.sidebarItem, in: controller)
        let detailWidthBeforeCollapse = paneWidth(controller.detailItem, in: controller)

        update(controller, sidebarPresented: false, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.splitView(controller.splitView, shouldHideDividerAt: 0)
        )
        XCTAssertTrue(paneView(controller.sidebarItem, in: controller).isHidden)
        let splitView = controller.splitView as! WorkspaceNativeSplitView
        let collapsedHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        XCTAssertEqual(collapsedHitRect.minX, splitView.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(collapsedHitRect.width, splitView.dividerHitWidth, accuracy: 0.001)
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: collapsedHitRect.midX, y: collapsedHitRect.midY)) === splitView
        )
        XCTAssertEqual(paneFrame(controller.detailItem, in: controller).minX, controller.splitView.bounds.minX, accuracy: 1)
        XCTAssertGreaterThan(paneWidth(controller.detailItem, in: controller), detailWidthBeforeCollapse)

        normalizeHiddenPaneToMinimum(controller.sidebarItem, in: controller)
        XCTAssertEqual(
            paneView(controller.sidebarItem, in: controller).bounds.width,
            controller.sidebarItem.minimumThickness,
            accuracy: 0.001,
            "The fixture must emulate macOS 15 discarding the hidden arranged view's useful width"
        )

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulWidth, accuracy: 1)
        let restoredHitRect = splitView.centerBiasedHitRect(forDividerAt: 0)
        XCTAssertEqual(restoredHitRect.minX, paneFrame(controller.sidebarItem, in: controller).maxX, accuracy: 1)
        XCTAssertGreaterThan(restoredHitRect.minX, splitView.bounds.minX)
    }

    func testTerminalCollapseReleasesItsSpaceAndRevealRestoresUsefulWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.terminalItem, in: controller)
        let detailWidthBeforeCollapse = paneWidth(controller.detailItem, in: controller)

        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)
        layout(window, controller)

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(
            controller.splitView(controller.splitView, shouldHideDividerAt: 1)
        )
        XCTAssertTrue(paneView(controller.terminalItem, in: controller).isHidden)
        let splitView = controller.splitView as! WorkspaceNativeSplitView
        let collapsedHitRect = splitView.centerBiasedHitRect(forDividerAt: 1)
        XCTAssertEqual(collapsedHitRect.maxX, splitView.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(collapsedHitRect.width, splitView.dividerHitWidth, accuracy: 0.001)
        XCTAssertTrue(
            splitView.hitTest(NSPoint(x: collapsedHitRect.midX, y: collapsedHitRect.midY)) === splitView
        )
        XCTAssertEqual(paneFrame(controller.detailItem, in: controller).maxX, controller.splitView.bounds.maxX, accuracy: 1)
        XCTAssertGreaterThan(paneWidth(controller.detailItem, in: controller), detailWidthBeforeCollapse)

        normalizeHiddenPaneToMinimum(controller.terminalItem, in: controller)
        XCTAssertEqual(
            paneView(controller.terminalItem, in: controller).bounds.width,
            controller.terminalItem.minimumThickness,
            accuracy: 0.001,
            "The fixture must emulate macOS 15 discarding the hidden arranged view's useful width"
        )

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulWidth, accuracy: 1)
        let restoredHitRect = splitView.centerBiasedHitRect(forDividerAt: 1)
        XCTAssertEqual(restoredHitRect.maxX, paneFrame(controller.terminalItem, in: controller).minX, accuracy: 1)
        XCTAssertLessThan(restoredHitRect.maxX, splitView.bounds.maxX)
    }

    func testLeftPressureCannotShrinkTheDocumentBelowItsMinimum() {
        let controller = makeController()
        let window = mount(controller, width: 1_000)

        controller.splitView.setPosition(WorkspaceSplitMetrics.sidebarMaximumWidth, ofDividerAt: 0)
        layout(window, controller)

        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1
        )
    }

    func testRightPressureCannotShrinkTheDocumentBelowItsMinimum() {
        let controller = makeController()
        let window = mount(controller, width: 1_000)

        controller.splitView.setPosition(
            WorkspaceSplitMetrics.sidebarMinimumWidth + WorkspaceSplitMetrics.detailMinimumWidth,
            ofDividerAt: 1
        )
        layout(window, controller)

        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.sidebarItem, in: controller),
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
    }

    func testNativeSidebarDragCollapsesAndRestoresTheOppositePeripheralPane() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(0, to: terminalCollapseThreshold + 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: false)
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )

        try dragDivider(0, to: terminalCollapseThreshold - snapEpsilon / 2, in: controller, window: window)
        layout(window, controller)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A small reverse drag must not oscillate the opposite pane around its snap coordinate"
        )

        try dragDivider(0, to: terminalCollapseThreshold - 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
    }

    func testSamePreferenceUpdateAndResizeDoNotCancelOppositeTerminalPressureCollapse() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            recorder: recorder
        )
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification,
            object: controller.splitView
        )
        controller.viewDidLayout()
        layout(window, controller)

        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A same-preference SwiftUI update and unchanged-bounds layout must preserve opposite-pane drag hysteresis"
        )
        XCTAssertTrue(controller.preferredTerminalPresentation)
    }

    func testOnePointContainerGrowthPreservesOppositeDividerPressureAndSourceWidth() throws {
        let controller = makeController()
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
                * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let expandedSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let splitWidthBeforeGrowth = controller.splitView.bounds.width

        window.contentViewController = nil
        layoutController(controller, width: splitWidthBeforeGrowth + 1)

        XCTAssertEqual(
            controller.splitView.bounds.width,
            splitWidthBeforeGrowth + 1,
            accuracy: 0.001
        )
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A one-point container resize must not reclassify divider pressure as a restorable container collapse"
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            expandedSidebarWidth,
            accuracy: 1
        )
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
    }

    func testTerminalRevealRequestShowsAnEffectivelyHiddenPreferredPane() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            terminalRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testHidingSidebarRestoresTheOppositePressureHiddenTerminal() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let terminalCollapseThreshold = controller.splitView.bounds.width
            - 2 * controller.splitView.dividerThickness
            - WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.terminalMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            0,
            to: terminalCollapseThreshold + 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: false,
            terminalPresented: true,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(
            controller.terminalItem.isCollapsed,
            "Hiding the dragged source pane must release its pressure collapse on the opposite pane"
        )
        XCTAssertFalse(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
    }

    func testNativeSidebarSnapCollapseReportsUserIntentAndOutwardDragRestoresWidth() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(360, ofDividerAt: 0)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.sidebarItem, in: controller)
        recorder.sidebarEvents.removeAll()

        try dragDivider(
            0,
            to: WorkspaceSplitMetrics.sidebarMinimumWidth * 0.4,
            in: controller,
            window: window
        )
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true),
            "A completed native divider gesture must report user intent synchronously at mouse-up"
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(paneView(controller.sidebarItem, in: controller).isHidden)
        XCTAssertFalse(controller.preferredSidebarPresentation)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true)
        )
        normalizeHiddenPaneToMinimum(controller.sidebarItem, in: controller)

        // Mirror SwiftUI feeding the user-visible collapsed preference back
        // into the representable before the next pointer gesture.
        update(controller, sidebarPresented: false, terminalPresented: true, recorder: recorder)

        try dragDivider(0, to: usefulWidth, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            usefulWidth,
            accuracy: controller.splitView.dividerThickness + 1
        )
    }

    func testNativeTerminalSnapCollapseReportsUserIntentAndOutwardDragRestoresWidth() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)

        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulWidth = paneWidth(controller.terminalItem, in: controller)
        recorder.terminalEvents.removeAll()

        try dragDivider(
            1,
            to: controller.splitView.bounds.width - WorkspaceSplitMetrics.terminalMinimumWidth * 0.4,
            in: controller,
            window: window
        )
        layout(window, controller)

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(paneView(controller.terminalItem, in: controller).isHidden)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: true)
        )
        normalizeHiddenPaneToMinimum(controller.terminalItem, in: controller)

        // Mirror SwiftUI feeding the user-visible collapsed preference back
        // into the representable before the next pointer gesture.
        update(controller, sidebarPresented: true, terminalPresented: false, recorder: recorder)

        try dragDivider(
            1,
            to: controller.splitView.bounds.width - usefulWidth,
            in: controller,
            window: window
        )
        layout(window, controller)

        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: true)
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulWidth,
            accuracy: controller.splitView.dividerThickness + 1
        )
    }

    func testNativeTerminalDragSymmetricallyCollapsesAndRestoresTheSidebar() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(1, to: sidebarCollapseThreshold - 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: false, userInitiated: false)
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )

        try dragDivider(1, to: sidebarCollapseThreshold + snapEpsilon / 2, in: controller, window: window)
        layout(window, controller)
        XCTAssertTrue(
            controller.sidebarItem.isCollapsed,
            "A small reverse drag must not oscillate the opposite pane around its snap coordinate"
        )

        try dragDivider(1, to: sidebarCollapseThreshold + 2 * snapEpsilon, in: controller, window: window)
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertEqual(
            recorder.sidebarEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
    }

    func testHidingTerminalRestoresTheOppositePressureHiddenSidebar() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            1,
            to: sidebarCollapseThreshold - 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(
            controller.sidebarItem.isCollapsed,
            "Hiding the dragged source pane must release its pressure collapse on the opposite pane"
        )
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertFalse(controller.preferredTerminalPresentation)
    }

    func testSidebarRevealRequestShowsAnEffectivelyHiddenPreferredPane() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 940)
        let snapEpsilon = max(1, controller.layoutScale)
        let sidebarCollapseThreshold = WorkspaceSplitMetrics.sidebarMinimumWidth
            + controller.splitView.dividerThickness
            + WorkspaceSplitMetrics.detailMinimumWidth
            - WorkspaceSplitMetrics.sidebarMinimumWidth * WorkspaceSplitMetrics.snapThresholdFraction

        try dragDivider(
            1,
            to: sidebarCollapseThreshold - 2 * snapEpsilon,
            in: controller,
            window: window
        )
        layout(window, controller)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            sidebarRevealRequest: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testZoomUpdatesNativeConstraintsWithoutReplacingSplitItemsOrVisibilityPreferences() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 2_200)
        let sidebarItem = controller.sidebarItem
        let detailItem = controller.detailItem
        let terminalItem = controller.terminalItem
        controller.splitView.setPosition(
            controller.splitView.bounds.width - 360 - controller.splitView.dividerThickness,
            ofDividerAt: 1
        )
        layout(window, controller)
        controller.splitView.setPosition(300, ofDividerAt: 0)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertEqual(usefulSidebarWidth, 300, accuracy: 2)
        XCTAssertGreaterThan(usefulTerminalWidth, WorkspaceSplitMetrics.terminalMinimumWidth)
        let scaledSidebarWidth = min(
            WorkspaceSplitMetrics.sidebarMaximumWidth * 1.5,
            usefulSidebarWidth * 1.5
        )
        let scaledTerminalWidth = min(
            WorkspaceSplitMetrics.terminalMaximumWidth * 1.5,
            usefulTerminalWidth * 1.5
        )

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertTrue(controller.sidebarItem === sidebarItem)
        XCTAssertTrue(controller.detailItem === detailItem)
        XCTAssertTrue(controller.terminalItem === terminalItem)
        XCTAssertEqual(controller.sidebarItem.minimumThickness, WorkspaceSplitMetrics.sidebarMinimumWidth * 1.5)
        XCTAssertEqual(controller.detailItem.minimumThickness, WorkspaceSplitMetrics.detailMinimumWidth * 1.5)
        XCTAssertEqual(controller.terminalItem.minimumThickness, WorkspaceSplitMetrics.terminalMinimumWidth * 1.5)
        XCTAssertEqual(controller.layoutScale, 1.5)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            scaledSidebarWidth,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            scaledTerminalWidth,
            accuracy: 2
        )

        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)
        XCTAssertEqual(splitView.dividerHitWidth, WorkspaceSplitMetrics.dividerHitWidth * 1.5)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulSidebarWidth, accuracy: 2)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulTerminalWidth, accuracy: 2)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1.5,
            recorder: recorder
        )
        layout(window, controller)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            scaledTerminalWidth,
            accuracy: 2
        )
    }

    func testZoomIncreaseCollapsesTheLowestPriorityPaneBeforeViolatingMinimums() {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 1_230)
        let initialSplitWidth = controller.splitView.bounds.width
        let initialTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "terminal stayed visible at split width \(controller.splitView.bounds.width), "
                + "active divider \(String(describing: (controller.splitView as? WorkspaceNativeSplitView)?.activeDividerIndex))"
        )
        assertAllVisiblePanesMeetMinimums(controller)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            initialTerminalWidth,
            accuracy: 2,
            "Zooming back to 100% must restore the terminal's retained native width"
        )
    }

    func testScaledOutwardTerminalDragCannotRevealAnUnderMinimumThreePaneLayout() throws {
        let recorder = PresentationRecorder()
        let controller = makeController(layoutScale: 1, recorder: recorder)
        let window = mount(controller, width: 1_800)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, 1_800, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let allocatedWidth = controller.splitView.bounds.width

        let attemptedTerminalWidth: CGFloat = 576
        try dragDivider(
            1,
            to: controller.splitView.bounds.width
                - attemptedTerminalWidth
                - controller.splitView.dividerThickness,
            in: controller,
            window: window
        )
        layout(window, controller)

        XCTAssertLessThanOrEqual(
            controller.splitView.bounds.width,
            allocatedWidth + 1,
            "A constrained native drag must never expand the split beyond its controller allocation"
        )
        let scaledSidebarMinimum = WorkspaceSplitMetrics.sidebarMinimumWidth * 2
        let scaledDetailMinimum = WorkspaceSplitMetrics.detailMinimumWidth * 2
        let scaledTerminalMinimum = WorkspaceSplitMetrics.terminalMinimumWidth * 2
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            scaledDetailMinimum - 1
        )
        if !controller.sidebarItem.isCollapsed {
            XCTAssertGreaterThanOrEqual(
                paneWidth(controller.sidebarItem, in: controller),
                scaledSidebarMinimum - 1
            )
        }
        if !controller.terminalItem.isCollapsed {
            XCTAssertGreaterThanOrEqual(
                paneWidth(controller.terminalItem, in: controller),
                scaledTerminalMinimum - 1,
                "An outward drag may reveal the terminal only at its scaled native minimum"
            )
        }
        XCTAssertTrue(
            controller.sidebarItem.isCollapsed || controller.terminalItem.isCollapsed,
            "A 1,800-point split cannot legally show all three panes at their 200% minimums"
        )
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "The lowest-priority terminal must return to its pressure-collapsed state when the reveal cannot fit"
        )
    }

    func testZoomIncreaseWithPreferredHiddenTerminalCollapsesAndRestoresSidebar() {
        let recorder = PresentationRecorder()
        let controller = makeController(
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        let window = mount(controller, width: 1_100)
        let usefulSidebarWidth: CGFloat = 360
        controller.splitView.setPosition(usefulSidebarWidth, ofDividerAt: 0)
        layout(window, controller)
        let initialSplitWidth = controller.splitView.bounds.width
        let initialSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        XCTAssertEqual(initialSidebarWidth, usefulSidebarWidth, accuracy: 2)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 2,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertFalse(controller.preferredTerminalPresentation)
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth * 2 - 1
        )

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: false,
            layoutScale: 1,
            recorder: recorder
        )
        layout(window, controller)

        XCTAssertEqual(controller.splitView.bounds.width, initialSplitWidth, accuracy: 1)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            initialSidebarWidth,
            accuracy: 2,
            "Zooming back to 100% must restore the sidebar while preserving a user-hidden terminal"
        )
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

    func testInitiallyHiddenNativePanesMountAndRevealWithoutReplacingContainers() {
        let recorder = PresentationRecorder()
        let controller = makeController(
            sidebarPresented: false,
            terminalPresented: false,
            recorder: recorder
        )
        let window = mount(controller, width: 1_600)
        let arrangedSubviews = controller.splitView.arrangedSubviews

        XCTAssertEqual(arrangedSubviews.count, 3)
        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)

        XCTAssertEqual(controller.splitView.arrangedSubviews.count, 3)
        XCTAssertTrue(
            zip(controller.splitView.arrangedSubviews, arrangedSubviews).allSatisfy {
                $0.0 === $0.1
            }
        )
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.sidebarItem, in: controller),
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1
        )
    }

    func testContainerBoundsPressureCollapsesTerminalFirstAndRestoresItsNativeWidth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(360, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        // Offscreen NSWindow fitting-size enforcement prevents simulating a
        // below-minimum live resize. Drive the controller's real AppKit frames
        // through the same viewDidLayout seam used by window state changes.
        window.contentViewController = nil
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "Expected terminal pressure collapse at split width \(controller.splitView.bounds.width); pane widths are \(controller.splitView.arrangedSubviews.map { $0.frame.width })"
        )
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: false, userInitiated: false)
        )

        controller.view.frame = NSRect(x: 0, y: 0, width: 1_600, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(controller.preferredSidebarPresentation)
        XCTAssertTrue(controller.preferredTerminalPresentation)
        XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), usefulSidebarWidth, accuracy: 2)
        XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), usefulTerminalWidth, accuracy: 2)
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
    }

    func testContainerGrowthWaitsForRetainedTerminalWidthWithoutExpandingTheSidebar() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(440, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 430, ofDividerAt: 1)
        layout(window, controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertGreaterThan(
            usefulTerminalWidth,
            WorkspaceSplitMetrics.terminalMinimumWidth
        )
        window.contentViewController = nil
        layoutController(controller, width: 900)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        let sidebarWidthBeforeRestore = paneWidth(controller.sidebarItem, in: controller)
        XCTAssertGreaterThan(
            sidebarWidthBeforeRestore,
            WorkspaceSplitMetrics.sidebarMinimumWidth
        )

        let minimumOnlyWidth = WorkspaceSplitMetrics.sidebarMinimumWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
            + 2 * controller.splitView.dividerThickness
        layoutController(controller, width: minimumOnlyWidth)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(
            controller.terminalItem.isCollapsed,
            "A container resize must not reveal the terminal by discarding its retained useful width"
        )
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidthBeforeRestore,
            accuracy: 2
        )

        let retainedWidthFit = sidebarWidthBeforeRestore
            + WorkspaceSplitMetrics.detailMinimumWidth
            + usefulTerminalWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: retainedWidthFit)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidthBeforeRestore,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulTerminalWidth,
            accuracy: 2
        )
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testContainerGrowthWaitsForBothRetainedWidthsBeforeRestoringBothHiddenPanes() {
        let controller = makeController()
        let window = mount(controller, width: 1_600)
        controller.splitView.setPosition(360, ofDividerAt: 0)
        controller.splitView.setPosition(controller.splitView.bounds.width - 500, ofDividerAt: 1)
        layout(window, controller)
        let usefulSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let usefulTerminalWidth = paneWidth(controller.terminalItem, in: controller)
        XCTAssertGreaterThan(
            usefulSidebarWidth,
            WorkspaceSplitMetrics.sidebarMinimumWidth
        )
        XCTAssertGreaterThan(
            usefulTerminalWidth,
            WorkspaceSplitMetrics.terminalMinimumWidth
        )
        window.contentViewController = nil
        layoutController(controller, width: 550)

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)

        let minimumOnlyWidth = WorkspaceSplitMetrics.sidebarMinimumWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + WorkspaceSplitMetrics.terminalMinimumWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: minimumOnlyWidth)

        XCTAssertTrue(
            controller.sidebarItem.isCollapsed || controller.terminalItem.isCollapsed,
            "Minimum-only capacity must not discard a retained peripheral width"
        )

        let retainedWidthFit = usefulSidebarWidth
            + WorkspaceSplitMetrics.detailMinimumWidth
            + usefulTerminalWidth
            + 2 * controller.splitView.dividerThickness
            + 2
        layoutController(controller, width: retainedWidthFit)

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            usefulSidebarWidth,
            accuracy: 2
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            usefulTerminalWidth,
            accuracy: 2
        )
        assertAllVisiblePanesMeetMinimums(controller)
    }

    func testProgrammaticVisibilityChangesAreReportedWithoutBeingMarkedAsUserDrags() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        let window = mount(controller, width: 2_000)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(controller, sidebarPresented: false, terminalPresented: false, recorder: recorder)
        layout(window, controller)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(controller.sidebarItem.isCollapsed)
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(recorder.sidebarEvents.last, PresentationEvent(isPresented: false, userInitiated: false))
        XCTAssertEqual(recorder.terminalEvents.last, PresentationEvent(isPresented: false, userInitiated: false))
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(controller, sidebarPresented: true, terminalPresented: true, recorder: recorder)
        layout(window, controller)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertEqual(recorder.sidebarEvents.last, PresentationEvent(isPresented: true, userInitiated: false))
        XCTAssertEqual(recorder.terminalEvents.last, PresentationEvent(isPresented: true, userInitiated: false))
    }

    func testProgrammaticPressureCallbackArrivesAfterUpdateWithCurrentNativeTruth() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        _ = mount(controller, width: 1_230)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )

        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertTrue(
            recorder.terminalEvents.isEmpty,
            "A representable update must return before its non-user callback mutates SwiftUI state"
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            recorder.terminalEvents,
            [PresentationEvent(isPresented: false, userInitiated: false)]
        )
    }

    func testDeferredPressureCallbackCoalescesToNativeTruthBeforeDelivery() {
        let recorder = PresentationRecorder()
        let controller = makeController(recorder: recorder)
        _ = mount(controller, width: 1_230)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            recorder.terminalEvents.last,
            PresentationEvent(isPresented: true, userInitiated: false)
        )
        recorder.sidebarEvents.removeAll()
        recorder.terminalEvents.removeAll()

        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 2,
            recorder: recorder
        )
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        update(
            controller,
            sidebarPresented: true,
            terminalPresented: true,
            layoutScale: 1,
            recorder: recorder
        )
        XCTAssertFalse(controller.terminalItem.isCollapsed)
        XCTAssertTrue(recorder.terminalEvents.isEmpty)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            recorder.terminalEvents,
            [],
            "A queued pressure callback must read current native state instead of delivering stale collapse"
        )
    }

    func testAutosaveRestoresPeripheralWidthsAcrossControllerRecreation() {
        let autosaveName = "Monknot.WorkspaceSplitTests.\(UUID().uuidString)"
        defer { removeSplitAutosaveDefaults(named: autosaveName) }
        var expectedSidebarWidth: CGFloat = 0
        var expectedTerminalWidth: CGFloat = 0

        do {
            let controller = makeController(autosaveName: autosaveName)
            let window = mount(controller, width: 1_600)
            controller.splitView.setPosition(365, ofDividerAt: 0)
            controller.splitView.setPosition(controller.splitView.bounds.width - 435, ofDividerAt: 1)
            layout(window, controller)
            expectedSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
            expectedTerminalWidth = paneWidth(controller.terminalItem, in: controller)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            window.contentViewController = nil
        }

        let restoredController = makeController(autosaveName: autosaveName)
        let restoredWindow = mount(restoredController, width: 1_600)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        layout(restoredWindow, restoredController)

        XCTAssertEqual(paneWidth(restoredController.sidebarItem, in: restoredController), expectedSidebarWidth, accuracy: 2)
        XCTAssertEqual(paneWidth(restoredController.terminalItem, in: restoredController), expectedTerminalWidth, accuracy: 2)
    }

    func testLegacyTerminalWidthMigratesOnceIntoTheNativeTerminalItem() {
        let legacyTerminalWidth: CGFloat = 470
        withIsolatedLegacyMigrationDefaults(terminalWidth: legacyTerminalWidth) { defaults in
            let controller = makeController(migratesLegacyLayout: true)
            let window = mount(controller, width: 1_600)
            controller.viewDidLayout()
            layout(window, controller)

            XCTAssertEqual(
                paneWidth(controller.terminalItem, in: controller),
                legacyTerminalWidth,
                accuracy: 1
            )
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))
            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))
        }
    }

    func testNarrowMigrationRetainsBothLegacyPeripheralWidthsIndependently() {
        let legacySidebarWidth: CGFloat = 390
        let legacyTerminalWidth: CGFloat = 470
        let previousLegacySidebarWidth = readLegacySidebarWidth()
        defer { storeLegacySidebarWidth(previousLegacySidebarWidth) }
        storeLegacySidebarWidth(legacySidebarWidth)

        XCTAssertEqual(readLegacySidebarWidth(), legacySidebarWidth, accuracy: 2)
        withIsolatedLegacyMigrationDefaults(terminalWidth: legacyTerminalWidth) { defaults in
            let controller = makeController(migratesLegacyLayout: true)
            setControllerSize(controller, width: 920)
            controller.viewDidLayout()
            controller.splitView.layoutSubtreeIfNeeded()

            XCTAssertEqual(controller.layoutScale, 1)
            XCTAssertFalse(controller.sidebarItem.isCollapsed)
            XCTAssertTrue(controller.terminalItem.isCollapsed)
            XCTAssertEqual(
                paneWidth(controller.sidebarItem, in: controller),
                legacySidebarWidth,
                accuracy: 2
            )
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))
            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))

            layoutController(controller, width: 1_600)

            XCTAssertFalse(controller.sidebarItem.isCollapsed)
            XCTAssertFalse(controller.terminalItem.isCollapsed)
            XCTAssertEqual(
                paneWidth(controller.sidebarItem, in: controller),
                legacySidebarWidth,
                accuracy: 2
            )
            XCTAssertEqual(
                paneWidth(controller.terminalItem, in: controller),
                legacyTerminalWidth,
                accuracy: 2
            )
        }
    }

    func testScaleTwoNarrowMigrationStagesAndRestoresScaledNativeWidths() {
        let previousLegacySidebarWidth = readLegacySidebarWidth()
        defer { storeLegacySidebarWidth(previousLegacySidebarWidth) }
        let legacySidebarWidth: CGFloat = 360
        let legacyTerminalWidth: CGFloat = 520
        storeLegacySidebarWidth(legacySidebarWidth)

        withIsolatedLegacyMigrationDefaults(terminalWidth: legacyTerminalWidth) { defaults in
            let controller = makeController(
                layoutScale: 2,
                migratesLegacyLayout: true
            )
            setControllerSize(controller, width: 920)
            controller.viewDidLayout()
            controller.splitView.layoutSubtreeIfNeeded()

            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))
            XCTAssertTrue(controller.sidebarItem.isCollapsed)
            XCTAssertTrue(controller.terminalItem.isCollapsed)

            let expectedSidebarWidth = min(
                WorkspaceSplitMetrics.sidebarMaximumWidth * controller.layoutScale,
                max(
                    WorkspaceSplitMetrics.sidebarMinimumWidth * controller.layoutScale,
                    legacySidebarWidth
                )
            )
            let expectedTerminalWidth = min(
                WorkspaceSplitMetrics.terminalMaximumWidth * controller.layoutScale,
                max(
                    WorkspaceSplitMetrics.terminalMinimumWidth * controller.layoutScale,
                    legacyTerminalWidth
                )
            )

            layoutController(controller, width: 2_200)

            XCTAssertFalse(controller.sidebarItem.isCollapsed)
            XCTAssertFalse(controller.terminalItem.isCollapsed)
            XCTAssertEqual(
                paneWidth(controller.sidebarItem, in: controller),
                expectedSidebarWidth,
                accuracy: 2 * controller.splitView.dividerThickness + 2,
                "The semantic sidebar container may add its fixed native edge decoration"
            )
            XCTAssertEqual(
                paneWidth(controller.terminalItem, in: controller),
                expectedTerminalWidth,
                accuracy: 2
            )
            XCTAssertGreaterThanOrEqual(
                paneWidth(controller.detailItem, in: controller),
                WorkspaceSplitMetrics.detailMinimumWidth * controller.layoutScale - 1
            )
        }
    }

    func testFirstNonzeroNarrowLayoutFinishesMigrationBeforeLaterWideLayout() {
        withIsolatedLegacyMigrationDefaults(terminalWidth: 470) { defaults in
            let controller = makeController(migratesLegacyLayout: true)

            setControllerSize(controller, width: 800)
            controller.viewDidLayout()
            controller.splitView.layoutSubtreeIfNeeded()

            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))

            let migrationProbeWidth: CGFloat = 520
            defaults.set(migrationProbeWidth, forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)
            setControllerSize(controller, width: 1_600)
            controller.sidebarItem.isCollapsed = false
            controller.terminalItem.isCollapsed = false
            controller.splitView.layoutSubtreeIfNeeded()
            controller.splitView.setPosition(330, ofDividerAt: 0)
            controller.splitView.setPosition(controller.splitView.bounds.width - 380, ofDividerAt: 1)
            controller.splitView.layoutSubtreeIfNeeded()
            let userSidebarWidth = paneWidth(controller.sidebarItem, in: controller)
            let userTerminalWidth = paneWidth(controller.terminalItem, in: controller)

            controller.viewDidLayout()
            controller.splitView.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                (defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey) as? NSNumber)?.doubleValue,
                Double(migrationProbeWidth)
            )
            XCTAssertEqual(paneWidth(controller.sidebarItem, in: controller), userSidebarWidth, accuracy: 1)
            XCTAssertEqual(paneWidth(controller.terminalItem, in: controller), userTerminalWidth, accuracy: 1)
        }
    }

    func testOnlyOneControllerCreatedBeforeLayoutCanClaimLegacyMigration() {
        withIsolatedLegacyMigrationDefaults(terminalWidth: 470) { defaults in
            let firstController = makeController(migratesLegacyLayout: true)
            let secondController = makeController(migratesLegacyLayout: true)

            let firstWindow = mount(firstController, width: 1_600)
            firstController.viewDidLayout()
            layout(firstWindow, firstController)

            XCTAssertTrue(defaults.bool(forKey: WorkspaceSplitMetrics.migrationMarkerKey))
            XCTAssertNil(defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey))

            let secondMigrationProbeWidth: CGFloat = 530
            defaults.set(
                secondMigrationProbeWidth,
                forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey
            )
            let secondWindow = mount(secondController, width: 1_600)
            secondController.viewDidLayout()
            layout(secondWindow, secondController)

            XCTAssertEqual(
                (defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey) as? NSNumber)?.doubleValue,
                Double(secondMigrationProbeWidth)
            )
            XCTAssertNotEqual(
                paneWidth(secondController.terminalItem, in: secondController),
                secondMigrationProbeWidth,
                accuracy: 1,
                "A second pre-created controller must not replay legacy migration"
            )
        }
    }

    private func makeController(
        sidebarPresented: Bool = true,
        terminalPresented: Bool = true,
        layoutScale: CGFloat = 1,
        autosaveName: String? = nil,
        migratesLegacyLayout: Bool = false,
        recorder: PresentationRecorder = PresentationRecorder()
    ) -> TestWorkspaceSplitViewController {
        let resolvedAutosaveName = autosaveName
            ?? "Monknot.WorkspaceSplitTests.Transient.\(UUID().uuidString)"
        let controller = TestWorkspaceSplitViewController(
            sidebar: Color.red,
            detail: Color.blue,
            terminal: Color.black,
            isSidebarPresented: sidebarPresented,
            isTerminalPresented: terminalPresented,
            layoutScale: layoutScale,
            separatorColor: .separatorColor,
            accentColor: .controlAccentColor,
            onSidebarPresentationChange: { isPresented, userInitiated in
                recorder.sidebarEvents.append(PresentationEvent(
                    isPresented: isPresented,
                    userInitiated: userInitiated
                ))
            },
            onTerminalPresentationChange: { isPresented, userInitiated in
                recorder.terminalEvents.append(PresentationEvent(
                    isPresented: isPresented,
                    userInitiated: userInitiated
                ))
            },
            autosaveName: resolvedAutosaveName,
            migratesLegacyLayout: migratesLegacyLayout
        )
        if autosaveName == nil {
            controller.splitView.autosaveName = nil
        }
        return controller
    }

    private func removeSplitAutosaveDefaults(named autosaveName: String) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.contains(autosaveName) {
            defaults.removeObject(forKey: key)
        }
    }

    private func update(
        _ controller: TestWorkspaceSplitViewController,
        sidebarPresented: Bool,
        terminalPresented: Bool,
        layoutScale: CGFloat? = nil,
        sidebarRevealRequest: UInt = 0,
        terminalRevealRequest: UInt = 0,
        recorder: PresentationRecorder
    ) {
        controller.update(
            sidebar: Color.red,
            detail: Color.blue,
            terminal: Color.black,
            isSidebarPresented: sidebarPresented,
            isTerminalPresented: terminalPresented,
            layoutScale: layoutScale ?? controller.layoutScale,
            separatorColor: .separatorColor,
            accentColor: .controlAccentColor,
            sidebarRevealRequest: sidebarRevealRequest,
            terminalRevealRequest: terminalRevealRequest,
            onSidebarPresentationChange: { isPresented, userInitiated in
                recorder.sidebarEvents.append(PresentationEvent(
                    isPresented: isPresented,
                    userInitiated: userInitiated
                ))
            },
            onTerminalPresentationChange: { isPresented, userInitiated in
                recorder.terminalEvents.append(PresentationEvent(
                    isPresented: isPresented,
                    userInitiated: userInitiated
                ))
            }
        )
    }

    private func mount(
        _ controller: TestWorkspaceSplitViewController,
        width: CGFloat
    ) -> NSWindow {
        let window = UnconstrainedSplitTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 620))
        layout(window, controller)
        return window
    }

    private func layoutMountedSplitHost<Content: View>(
        window: NSWindow,
        host: NSHostingView<Content>
    ) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    private func observeSplitWidthChanges(
        _ splitView: WorkspaceNativeSplitView,
        recording observation: MountedSplitWidthObservation
    ) -> [NSObjectProtocol] {
        observation.record(splitView)
        splitView.postsFrameChangedNotifications = true
        splitView.postsBoundsChangedNotifications = true
        return [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: splitView,
                queue: .main
            ) { [weak splitView] _ in
                MainActor.assumeIsolated {
                    guard let splitView else { return }
                    observation.record(splitView)
                }
            }
        }
    }

    private func assertMountedSplitFitsAllocation(
        _ splitView: WorkspaceNativeSplitView,
        host: NSView,
        allocationWidth: CGFloat,
        observation: MountedSplitWidthObservation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(host.bounds.width, allocationWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(splitView.frame.width, allocationWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(splitView.bounds.width, allocationWidth, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(
            observation.maximumFrameWidth,
            allocationWidth + 1,
            "The native split frame exceeded its SwiftUI host allocation during zoom",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            observation.maximumBoundsWidth,
            allocationWidth + 1,
            "The native split bounds exceeded its SwiftUI host allocation during zoom",
            file: file,
            line: line
        )
    }

    private func layout(_ window: NSWindow, _ controller: TestWorkspaceSplitViewController) {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    private func setControllerSize(
        _ controller: TestWorkspaceSplitViewController,
        width: CGFloat
    ) {
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    private func layoutController(
        _ controller: TestWorkspaceSplitViewController,
        width: CGFloat
    ) {
        setControllerSize(controller, width: width)
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    private func assertAllVisiblePanesMeetMinimums(
        _ controller: TestWorkspaceSplitViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.sidebarItem, in: controller),
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.detailItem, in: controller),
            WorkspaceSplitMetrics.detailMinimumWidth - 1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            paneWidth(controller.terminalItem, in: controller),
            WorkspaceSplitMetrics.terminalMinimumWidth - 1,
            file: file,
            line: line
        )
    }

    private func readLegacySidebarWidth() -> CGFloat {
        let controller = makeLegacySidebarController()
        controller.splitView.setPosition(
            WorkspaceSplitMetrics.sidebarMinimumWidth,
            ofDividerAt: 0
        )
        controller.splitView.autosaveName = WorkspaceSplitMetrics.legacyAutosaveName
        defer { controller.splitView.autosaveName = nil }
        controller.splitView.layoutSubtreeIfNeeded()
        return controller.splitView.arrangedSubviews[0].frame.width
    }

    private func storeLegacySidebarWidth(_ width: CGFloat) {
        let controller = makeLegacySidebarController()
        controller.splitView.autosaveName = WorkspaceSplitMetrics.legacyAutosaveName
        controller.splitView.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(width, ofDividerAt: 0)
        controller.splitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.splitView.autosaveName = nil
    }

    private func makeLegacySidebarController() -> NSSplitViewController {
        let controller = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(viewController: NSViewController())
        let detailItem = NSSplitViewItem(viewController: NSViewController())
        controller.splitView.isVertical = true
        controller.splitView.frame = NSRect(x: 0, y: 0, width: 1_600, height: 620)
        sidebarItem.minimumThickness = WorkspaceSplitMetrics.sidebarMinimumWidth
        sidebarItem.maximumThickness = WorkspaceSplitMetrics.sidebarMaximumWidth
        sidebarItem.holdingPriority = WorkspaceSplitMetrics.sidebarHoldingPriority
        detailItem.minimumThickness = 480
        detailItem.holdingPriority = WorkspaceSplitMetrics.detailHoldingPriority
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)
        _ = controller.view
        controller.splitView.layoutSubtreeIfNeeded()
        return controller
    }

    private func withIsolatedLegacyMigrationDefaults(
        terminalWidth: CGFloat,
        _ body: (UserDefaults) -> Void
    ) {
        let defaults = UserDefaults.standard
        let previousLegacyWidth = defaults.object(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)
        let previousMigrationMarker = defaults.object(forKey: WorkspaceSplitMetrics.migrationMarkerKey)
        defer {
            if let previousLegacyWidth {
                defaults.set(previousLegacyWidth, forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)
            } else {
                defaults.removeObject(forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)
            }
            if let previousMigrationMarker {
                defaults.set(previousMigrationMarker, forKey: WorkspaceSplitMetrics.migrationMarkerKey)
            } else {
                defaults.removeObject(forKey: WorkspaceSplitMetrics.migrationMarkerKey)
            }
        }

        defaults.set(terminalWidth, forKey: WorkspaceSplitMetrics.legacyTerminalWidthKey)
        defaults.removeObject(forKey: WorkspaceSplitMetrics.migrationMarkerKey)
        body(defaults)
    }

    private func dragDivider(
        _ dividerIndex: Int,
        to destinationX: CGFloat,
        in controller: TestWorkspaceSplitViewController,
        window: NSWindow
    ) throws {
        let splitView = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)
        try dragDivider(
            dividerIndex,
            to: destinationX,
            in: splitView,
            window: window
        )
    }

    private func dragDivider(
        _ dividerIndex: Int,
        to destinationX: CGFloat,
        in splitView: WorkspaceNativeSplitView,
        window: NSWindow
    ) throws {
        let hitRect = splitView.centerBiasedHitRect(forDividerAt: dividerIndex)
        let leadingView = splitView.arrangedSubviews[dividerIndex]
        let trailingView = splitView.arrangedSubviews[dividerIndex + 1]
        let currentDividerPosition = leadingView.isHidden
            ? trailingView.frame.minX
            : leadingView.frame.maxX
        let pointerOffsetFromDivider = hitRect.midX - currentDividerPosition
        let start = splitView.convert(
            NSPoint(x: hitRect.midX, y: splitView.bounds.midY),
            to: nil
        )
        let destination = splitView.convert(
            NSPoint(
                x: destinationX + pointerOffsetFromDivider,
                y: splitView.bounds.midY
            ),
            to: nil
        )
        let drag = try XCTUnwrap(mouseEvent(
            type: .leftMouseDragged,
            location: destination,
            windowNumber: window.windowNumber
        ))
        let up = try XCTUnwrap(mouseEvent(
            type: .leftMouseUp,
            location: destination,
            windowNumber: window.windowNumber
        ))
        let down = try XCTUnwrap(mouseEvent(
            type: .leftMouseDown,
            location: start,
            windowNumber: window.windowNumber
        ))

        NSApp.postEvent(drag, atStart: false)
        NSApp.postEvent(up, atStart: false)
        splitView.mouseDown(with: down)
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    private func normalizeHiddenPaneToMinimum(
        _ item: NSSplitViewItem,
        in controller: NSSplitViewController
    ) {
        let index = controller.splitViewItems.firstIndex { $0 === item }!
        let view = controller.splitView.arrangedSubviews[index]
        var frame = view.frame
        frame.size.width = item.minimumThickness
        view.frame = frame
        var bounds = view.bounds
        bounds.size.width = item.minimumThickness
        view.bounds = bounds
    }

    private func paneWidth(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> CGFloat {
        paneFrame(item, in: controller).width
    }

    private func paneFrame(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> NSRect {
        paneView(item, in: controller).frame
    }

    private func paneView(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> NSView {
        let index = controller.splitViewItems.firstIndex { $0 === item }!
        return controller.splitView.arrangedSubviews[index]
    }

    private func firstDescendant<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
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
}

@MainActor
private final class UnconstrainedSplitTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private typealias TestWorkspaceSplitViewController = WorkspaceSplitViewController<Color, Color, Color>

private struct PresentationEvent: Equatable {
    let isPresented: Bool
    let userInitiated: Bool
}

private final class PresentationRecorder {
    var sidebarEvents: [PresentationEvent] = []
    var terminalEvents: [PresentationEvent] = []
}

@MainActor
private final class MountedSplitZoomModel: ObservableObject {
    @Published var layoutScale: CGFloat = 2
}

private final class MountedSplitGeometryObservation: @unchecked Sendable {
    var sawZeroFrame = false
}

private final class MountedSplitWidthObservation: @unchecked Sendable {
    private(set) var maximumFrameWidth: CGFloat = 0
    private(set) var maximumBoundsWidth: CGFloat = 0

    func record(_ splitView: NSView) {
        maximumFrameWidth = max(maximumFrameWidth, splitView.frame.width)
        maximumBoundsWidth = max(maximumBoundsWidth, splitView.bounds.width)
    }
}

private final class WorkspaceSizingActivity: @unchecked Sendable {
    private(set) var splitResizeCount = 0

    func recordSplitResize() {
        splitResizeCount += 1
    }

    func reset() {
        splitResizeCount = 0
    }
}

@MainActor
private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutCallCount = 0
    private(set) var updateConstraintsCallCount = 0

    override func layout() {
        layoutCallCount += 1
        super.layout()
    }

    override func updateConstraints() {
        updateConstraintsCallCount += 1
        super.updateConstraints()
    }

    func resetLayoutCounts() {
        layoutCallCount = 0
        updateConstraintsCallCount = 0
    }
}

private struct MountedSplitZoomFixture: View {
    @ObservedObject var model: MountedSplitZoomModel

    var body: some View {
        VStack(spacing: 0) {
            Color.gray.frame(height: 44)

            WorkspaceSplitView(
                isSidebarPresented: true,
                isTerminalPresented: false,
                layoutScale: model.layoutScale,
                separatorColor: .separatorColor,
                accentColor: .controlAccentColor,
                onSidebarPresentationChange: { _, _ in },
                onTerminalPresentationChange: { _, _ in },
                sidebar: {
                    Color.red.frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                detail: {
                    Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                terminal: { EmptyView() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private final class MountedConstrainedScaleModel: ObservableObject {
    @Published var layoutScale: CGFloat = 1
    @Published var sidebarPreferred: Bool
    @Published var terminalPreferred: Bool
    @Published private(set) var sidebarEffective: Bool
    @Published private(set) var terminalEffective: Bool

    init(sidebarPreferred: Bool, terminalPreferred: Bool) {
        self.sidebarPreferred = sidebarPreferred
        self.terminalPreferred = terminalPreferred
        sidebarEffective = sidebarPreferred
        terminalEffective = terminalPreferred
    }

    func handleSidebar(_ isPresented: Bool, userInitiated: Bool) {
        if userInitiated {
            sidebarPreferred = isPresented
        }
        sidebarEffective = isPresented
    }

    func handleTerminal(_ isPresented: Bool, userInitiated: Bool) {
        if userInitiated {
            terminalPreferred = isPresented
        }
        terminalEffective = isPresented
    }
}

private struct MountedConstrainedScaleFixture: View {
    @ObservedObject var model: MountedConstrainedScaleModel
    var terminalLifecycle: MountedTerminalLifecycleObservation?

    init(
        model: MountedConstrainedScaleModel,
        terminalLifecycle: MountedTerminalLifecycleObservation? = nil
    ) {
        self.model = model
        self.terminalLifecycle = terminalLifecycle
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.gray.frame(height: 44)

            WorkspaceSplitView(
                isSidebarPresented: model.sidebarPreferred,
                isTerminalPresented: model.terminalPreferred,
                layoutScale: model.layoutScale,
                separatorColor: .separatorColor,
                accentColor: .controlAccentColor,
                onSidebarPresentationChange: model.handleSidebar(_:userInitiated:),
                onTerminalPresentationChange: model.handleTerminal(_:userInitiated:),
                sidebar: {
                    Color.red.frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                detail: {
                    Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                terminal: {
                    if model.terminalPreferred {
                        if let terminalLifecycle {
                            MountedTerminalLifecycleProbe(observation: terminalLifecycle)
                        } else {
                            Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private final class MountedTerminalLifecycleObservation {
    private(set) weak var view: NSView?
    private(set) var mountCount = 0
    private(set) var dismantleCount = 0

    func didMount(_ view: NSView) {
        self.view = view
        mountCount += 1
    }

    func didDismantle() {
        dismantleCount += 1
    }
}

private struct MountedTerminalLifecycleProbe: NSViewRepresentable {
    let observation: MountedTerminalLifecycleObservation

    func makeCoordinator() -> MountedTerminalLifecycleObservation {
        observation
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.didMount(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: MountedTerminalLifecycleObservation
    ) {
        coordinator.didDismantle()
    }
}

@MainActor
private final class LiveSplitFeedbackModel: ObservableObject {
    @Published var sidebarPreferred = false
    @Published var terminalPreferred = true
    @Published private(set) var sidebarEffective = false
    @Published private(set) var terminalEffective = true
    var sidebarEvents: [PresentationEvent] = []
    var terminalEvents: [PresentationEvent] = []

    func handleSidebar(_ isPresented: Bool, userInitiated: Bool) {
        sidebarEvents.append(PresentationEvent(
            isPresented: isPresented,
            userInitiated: userInitiated
        ))
        if userInitiated {
            sidebarPreferred = isPresented
        }
        sidebarEffective = isPresented
    }

    func handleTerminal(_ isPresented: Bool, userInitiated: Bool) {
        terminalEvents.append(PresentationEvent(
            isPresented: isPresented,
            userInitiated: userInitiated
        ))
        if userInitiated {
            terminalPreferred = isPresented
        }
        terminalEffective = isPresented
    }
}

private struct LiveSplitFeedbackFixture: View {
    @ObservedObject var model: LiveSplitFeedbackModel

    var body: some View {
        WorkspaceSplitView(
            isSidebarPresented: model.sidebarPreferred,
            isTerminalPresented: model.terminalPreferred,
            layoutScale: 1,
            separatorColor: .separatorColor,
            accentColor: .controlAccentColor,
            onSidebarPresentationChange: model.handleSidebar,
            onTerminalPresentationChange: model.handleTerminal,
            sidebar: { Color.red },
            detail: { Color.blue },
            terminal: { Color.black }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class DividerTrackingObservation: @unchecked Sendable {
    var sawActiveAndHoveredDivider = false
}
