import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
class WorkspaceSplitViewTestCase: XCTestCase {

    func makeController(
        sidebarPresented: Bool = true,
        terminalPresented: Bool = true,
        isTerminalFullscreen: Bool = false,
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
            isTerminalFullscreen: isTerminalFullscreen,
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

    func removeSplitAutosaveDefaults(named autosaveName: String) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.contains(autosaveName) {
            defaults.removeObject(forKey: key)
        }
    }

    func update(
        _ controller: TestWorkspaceSplitViewController,
        sidebarPresented: Bool,
        terminalPresented: Bool,
        isTerminalFullscreen: Bool = false,
        layoutScale: CGFloat? = nil,
        sidebarRevealRequest: UInt = 0,
        terminalRevealRequest: UInt = 0,
        recorder: PresentationRecorder,
        animated: Bool = false
    ) {
        controller.update(
            sidebar: Color.red,
            detail: Color.blue,
            terminal: Color.black,
            isSidebarPresented: sidebarPresented,
            isTerminalPresented: terminalPresented,
            isTerminalFullscreen: isTerminalFullscreen,
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
            },
            animated: animated
        )
    }

    func mount(
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

    func layoutMountedSplitHost<Content: View>(
        window: NSWindow,
        host: NSHostingView<Content>
    ) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func observeSplitWidthChanges(
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

    func assertMountedSplitFitsAllocation(
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

    func assertTerminalFullscreenRoundTrip(
        prepopulateAutosave: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let autosaveName = "Monknot.WorkspaceSplitTests.Fullscreen.\(UUID().uuidString)"
        defer { removeSplitAutosaveDefaults(named: autosaveName) }

        var expectedSidebarWidth: CGFloat = 340
        var expectedTerminalWidth: CGFloat = 510
        if prepopulateAutosave {
            let seedController = makeController(autosaveName: autosaveName)
            let seedWindow = mount(seedController, width: 1_600)
            seedController.splitView.setPosition(expectedSidebarWidth, ofDividerAt: 0)
            seedController.splitView.setPosition(
                seedController.splitView.bounds.width
                    - expectedTerminalWidth
                    - seedController.splitView.dividerThickness,
                ofDividerAt: 1
            )
            let didPersistGeometry = await waitForStableSplitState(
                controller: seedController,
                window: seedWindow,
                perform: {},
                until: {
                    abs(self.paneWidth(seedController.sidebarItem, in: seedController) - 340) <= 1
                        && abs(self.paneWidth(seedController.terminalItem, in: seedController) - 510) <= 1
                        && seedController.splitView.autosaveName == autosaveName
                }
            )
            XCTAssertTrue(
                didPersistGeometry,
                splitStateDescription(seedController),
                file: file,
                line: line
            )
            expectedSidebarWidth = paneWidth(seedController.sidebarItem, in: seedController)
            expectedTerminalWidth = paneWidth(seedController.terminalItem, in: seedController)
            seedWindow.orderOut(nil)
            seedWindow.contentViewController = nil
            await nextMainQueueTurn()
        }

        let recorder = PresentationRecorder()
        let controller = makeController(
            autosaveName: autosaveName,
            recorder: recorder
        )
        let window = mount(controller, width: 1_600)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        let didSettleDockedGeometry = await waitForStableSplitState(
            controller: controller,
            window: window,
            perform: {
                if !prepopulateAutosave {
                    controller.splitView.setPosition(expectedSidebarWidth, ofDividerAt: 0)
                    controller.splitView.setPosition(
                        controller.splitView.bounds.width
                            - expectedTerminalWidth
                            - controller.splitView.dividerThickness,
                        ofDividerAt: 1
                    )
                }
            },
            until: {
                abs(self.paneWidth(controller.sidebarItem, in: controller) - expectedSidebarWidth) <= 1
                    && abs(self.paneWidth(controller.terminalItem, in: controller) - expectedTerminalWidth) <= 1
                    && controller.splitView.autosaveName == autosaveName
            }
        )
        XCTAssertTrue(
            didSettleDockedGeometry,
            splitStateDescription(controller),
            file: file,
            line: line
        )

        let sidebarWidth = paneWidth(controller.sidebarItem, in: controller)
        let terminalWidth = paneWidth(controller.terminalItem, in: controller)
        let detailView = paneView(controller.detailItem, in: controller)
        let terminalView = paneView(controller.terminalItem, in: controller)
        let nativeSplit = try XCTUnwrap(controller.splitView as? WorkspaceNativeSplitView)

        let didEnterFullscreen = await waitForStableSplitState(
            controller: controller,
            window: window,
            perform: {
                self.update(
                    controller,
                    sidebarPresented: true,
                    terminalPresented: true,
                    isTerminalFullscreen: true,
                    recorder: recorder,
                    animated: true
                )
            },
            until: {
                controller.isTerminalFullscreen
                    && controller.detailItem.isCollapsed
                    && detailView.isHidden
                    && abs(self.paneWidth(controller.sidebarItem, in: controller) - sidebarWidth) <= 1
                    && self.paneView(controller.detailItem, in: controller) === detailView
                    && self.paneView(controller.terminalItem, in: controller) === terminalView
                    && abs(
                        self.paneFrame(controller.terminalItem, in: controller).minX
                            - self.paneFrame(controller.sidebarItem, in: controller).maxX
                            - WorkspaceSplitMetrics.dividerThickness
                    ) <= 1
                    && abs(
                        self.paneFrame(controller.terminalItem, in: controller).maxX
                            - controller.splitView.bounds.maxX
                    ) <= 1
                    && controller.splitView.autosaveName == nil
                    && nativeSplit.disabledDividerIndices == [0, 1]
            }
        )
        XCTAssertTrue(
            didEnterFullscreen,
            splitStateDescription(controller),
            file: file,
            line: line
        )

        XCTAssertTrue(controller.isTerminalFullscreen, file: file, line: line)
        XCTAssertTrue(controller.detailItem.isCollapsed, file: file, line: line)
        XCTAssertTrue(detailView.isHidden, file: file, line: line)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidth,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertTrue(
            paneView(controller.detailItem, in: controller) === detailView,
            file: file,
            line: line
        )
        XCTAssertTrue(
            paneView(controller.terminalItem, in: controller) === terminalView,
            file: file,
            line: line
        )
        XCTAssertEqual(
            paneFrame(controller.terminalItem, in: controller).minX,
            paneFrame(controller.sidebarItem, in: controller).maxX
                + WorkspaceSplitMetrics.dividerThickness,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            paneFrame(controller.terminalItem, in: controller).maxX,
            controller.splitView.bounds.maxX,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertNil(controller.splitView.autosaveName, file: file, line: line)
        XCTAssertEqual(nativeSplit.disabledDividerIndices, [0, 1], file: file, line: line)
        XCTAssertEqual(
            controller.splitView(
                nativeSplit,
                effectiveRect: nativeSplit.bounds,
                forDrawnRect: nativeSplit.bounds,
                ofDividerAt: 1
            ),
            .zero,
            file: file,
            line: line
        )

        let didRestoreDockedGeometry = await waitForStableSplitState(
            controller: controller,
            window: window,
            perform: {
                self.update(
                    controller,
                    sidebarPresented: true,
                    terminalPresented: true,
                    isTerminalFullscreen: false,
                    recorder: recorder,
                    animated: true
                )
            },
            until: {
                !controller.isTerminalFullscreen
                    && !controller.detailItem.isCollapsed
                    && !detailView.isHidden
                    && abs(self.paneWidth(controller.sidebarItem, in: controller) - sidebarWidth) <= 1
                    && abs(self.paneWidth(controller.terminalItem, in: controller) - terminalWidth) <= 1
                    && self.paneView(controller.detailItem, in: controller) === detailView
                    && self.paneView(controller.terminalItem, in: controller) === terminalView
                    && nativeSplit.disabledDividerIndices.isEmpty
                    && controller.splitView.autosaveName == autosaveName
            }
        )
        XCTAssertTrue(
            didRestoreDockedGeometry,
            splitStateDescription(controller),
            file: file,
            line: line
        )

        XCTAssertFalse(controller.isTerminalFullscreen, file: file, line: line)
        XCTAssertFalse(controller.detailItem.isCollapsed, file: file, line: line)
        XCTAssertFalse(detailView.isHidden, file: file, line: line)
        XCTAssertEqual(
            paneWidth(controller.sidebarItem, in: controller),
            sidebarWidth,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            paneWidth(controller.terminalItem, in: controller),
            terminalWidth,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(nativeSplit.disabledDividerIndices, [], file: file, line: line)
        XCTAssertEqual(controller.splitView.autosaveName, autosaveName, file: file, line: line)
    }

    func waitForStableSplitState(
        controller: TestWorkspaceSplitViewController,
        window: NSWindow,
        timeout: TimeInterval = 2,
        perform: @MainActor () -> Void,
        until condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let resizeCounter = SplitResizeCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: controller.splitView,
            queue: .main
        ) { _ in
            resizeCounter.recordResize()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        perform()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            layoutImmediately(window, controller)
            if condition() {
                let generation = resizeCounter.generation
                await nextMainQueueTurn()
                layoutImmediately(window, controller)
                await nextMainQueueTurn()
                layoutImmediately(window, controller)
                if condition(), resizeCounter.generation == generation {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func layoutImmediately(
        _ window: NSWindow,
        _ controller: TestWorkspaceSplitViewController
    ) {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func splitStateDescription(_ controller: TestWorkspaceSplitViewController) -> String {
        let frames = controller.splitView.arrangedSubviews.map { NSStringFromRect($0.frame) }
        let disabledDividers = (controller.splitView as? WorkspaceNativeSplitView)?
            .disabledDividerIndices ?? []
        return "frames=\(frames) detailCollapsed=\(controller.detailItem.isCollapsed) "
            + "terminalFullscreen=\(controller.isTerminalFullscreen) "
            + "disabledDividers=\(disabledDividers) "
            + "autosave=\(controller.splitView.autosaveName ?? "nil")"
    }

    func layout(_ window: NSWindow, _ controller: TestWorkspaceSplitViewController) {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    func setControllerSize(
        _ controller: TestWorkspaceSplitViewController,
        width: CGFloat
    ) {
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        controller.splitView.frame = controller.view.bounds
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    func layoutController(
        _ controller: TestWorkspaceSplitViewController,
        width: CGFloat
    ) {
        setControllerSize(controller, width: width)
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    func assertAllVisiblePanesMeetMinimums(
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

    func readLegacySidebarWidth() -> CGFloat {
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

    func storeLegacySidebarWidth(
        _ width: CGFloat,
        timeout: TimeInterval = 1
    ) async -> Bool {
        let controller = makeLegacySidebarController()
        let window = UnconstrainedSplitTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.splitView.autosaveName = WorkspaceSplitMetrics.legacyAutosaveName
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_600, height: 620))
        window.layoutIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(width, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(timeout)
        var didRestoreExpectedWidth = false
        while Date() < deadline {
            await nextMainQueueTurn()
            window.layoutIfNeeded()
            controller.splitView.layoutSubtreeIfNeeded()
            if abs(readLegacySidebarWidth() - width) <= 2 {
                didRestoreExpectedWidth = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        controller.splitView.autosaveName = nil
        window.orderOut(nil)
        window.contentViewController = nil
        await nextMainQueueTurn()
        return didRestoreExpectedWidth
    }

    func withLegacySidebarWidth(
        _ width: CGFloat,
        perform body: () async -> Void
    ) async {
        let previousWidth = readLegacySidebarWidth()
        let didStoreWidth = await storeLegacySidebarWidth(width)
        XCTAssertTrue(didStoreWidth)
        await body()
        let didRestorePreviousWidth = await storeLegacySidebarWidth(previousWidth)
        XCTAssertTrue(didRestorePreviousWidth)
    }

    func makeLegacySidebarController() -> NSSplitViewController {
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

    func withIsolatedLegacyMigrationDefaults(
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

    func dragDivider(
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

    func dragDivider(
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

    func mouseEvent(
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

    func normalizeHiddenPaneToMinimum(
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

    func paneWidth(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> CGFloat {
        paneFrame(item, in: controller).width
    }

    func paneFrame(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> NSRect {
        paneView(item, in: controller).frame
    }

    func paneView(
        _ item: NSSplitViewItem,
        in controller: TestWorkspaceSplitViewController
    ) -> NSView {
        let index = controller.splitViewItems.firstIndex { $0 === item }!
        return controller.splitView.arrangedSubviews[index]
    }

    func firstDescendant<ViewType: NSView>(
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
final class UnconstrainedSplitTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

typealias TestWorkspaceSplitViewController = WorkspaceSplitViewController<Color, Color, Color>

struct PresentationEvent: Equatable {
    let isPresented: Bool
    let userInitiated: Bool
}

final class PresentationRecorder {
    var sidebarEvents: [PresentationEvent] = []
    var terminalEvents: [PresentationEvent] = []
}

@MainActor
final class MountedSplitZoomModel: ObservableObject {
    @Published var layoutScale: CGFloat = 2
}

final class MountedSplitGeometryObservation: @unchecked Sendable {
    var sawZeroFrame = false
}

final class MountedSplitWidthObservation: @unchecked Sendable {
    private(set) var maximumFrameWidth: CGFloat = 0
    private(set) var maximumBoundsWidth: CGFloat = 0

    func record(_ splitView: NSView) {
        maximumFrameWidth = max(maximumFrameWidth, splitView.frame.width)
        maximumBoundsWidth = max(maximumBoundsWidth, splitView.bounds.width)
    }
}

final class WorkspaceSizingActivity: @unchecked Sendable {
    private(set) var splitResizeCount = 0

    func recordSplitResize() {
        splitResizeCount += 1
    }

    func reset() {
        splitResizeCount = 0
    }
}

@MainActor
final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
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

struct MountedSplitZoomFixture: View {
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
final class MountedConstrainedScaleModel: ObservableObject {
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

struct MountedConstrainedScaleFixture: View {
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
final class MountedTerminalLifecycleObservation {
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

struct MountedTerminalLifecycleProbe: NSViewRepresentable {
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
final class LiveSplitFeedbackModel: ObservableObject {
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

struct LiveSplitFeedbackFixture: View {
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

final class DividerTrackingObservation: @unchecked Sendable {
    var sawActiveAndHoveredDivider = false
}

final class SplitResizeCounter: @unchecked Sendable {
    let lock = NSLock()
    var value = 0

    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func recordResize() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
