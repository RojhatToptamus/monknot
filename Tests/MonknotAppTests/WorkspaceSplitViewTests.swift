import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitViewTests: XCTestCase {
    func testNativeSplitOwnsSidebarConstraintsCollapseAndPersistence() {
        let controller = makeController(isSidebarPresented: true)

        XCTAssertTrue(controller.splitView.isVertical)
        XCTAssertEqual(controller.splitView.dividerStyle, .thin)
        XCTAssertEqual(controller.splitView.autosaveName, WorkspaceSplitMetrics.autosaveName)
        XCTAssertEqual(controller.splitViewItems.count, 2)
        XCTAssertEqual(controller.sidebarItem.minimumThickness, WorkspaceSplitMetrics.sidebarMinimumWidth)
        XCTAssertEqual(controller.sidebarItem.maximumThickness, WorkspaceSplitMetrics.sidebarMaximumWidth)
        XCTAssertEqual(controller.sidebarItem.preferredThicknessFraction, NSSplitViewItem.unspecifiedDimension)
        XCTAssertFalse(
            controller.sidebarItem.canCollapse,
            "The visible app toggle must remain the sole owner of sidebar collapse state"
        )
        XCTAssertFalse(controller.sidebarItem.canCollapseFromWindowResize)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        XCTAssertEqual(controller.detailItem.minimumThickness, WorkspaceSplitMetrics.detailMinimumWidth)
        XCTAssertFalse(controller.detailItem.canCollapse)
    }

    func testSidebarPresentationUpdatesTheOwnedNativeSplitItem() {
        let controller = makeController(isSidebarPresented: true)

        controller.update(
            sidebar: Color.red,
            detail: Color.blue,
            isSidebarPresented: false
        )
        XCTAssertTrue(controller.sidebarItem.isCollapsed)

        controller.update(
            sidebar: Color.green,
            detail: Color.orange,
            isSidebarPresented: true
        )
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
    }

    func testSidebarCannotDriftFromTheApplicationPresentationState() {
        let controller = makeController(isSidebarPresented: true)

        XCTAssertFalse(controller.sidebarItem.canCollapse)
        XCTAssertFalse(controller.sidebarItem.canCollapseFromWindowResize)

        controller.update(
            sidebar: Color.red,
            detail: Color.blue,
            isSidebarPresented: true
        )
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
    }

    func testRequestedSidebarVisibilityWinsOverAutosavedCollapseState() {
        let autosaveName = "Monknot.WorkspaceSplitTests.\(UUID().uuidString)"
        let autosaveKey = "NSSplitView Subview Frames \(autosaveName)"
        UserDefaults.standard.removeObject(forKey: autosaveKey)
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey) }

        let firstController = makeController(
            isSidebarPresented: true,
            autosaveName: autosaveName
        )
        let firstWindow = mount(firstController)
        firstController.sidebarItem.isCollapsed = true
        firstWindow.layoutIfNeeded()
        firstController.view.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification,
            object: firstController.splitView
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let restoredController = makeController(
            isSidebarPresented: true,
            autosaveName: autosaveName
        )
        let restoredWindow = mount(restoredController)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertFalse(
            restoredController.sidebarItem.isCollapsed,
            "SceneStorage visibility must override the collapse bit bundled into NSSplitView autosave"
        )
        _ = restoredWindow
    }

    func testMountedNativeSplitKeepsTwoPanesAndReadableDetailAtMinimumWindowWidth() {
        let controller = makeController(isSidebarPresented: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.splitView.arrangedSubviews.count, 2)
        XCTAssertGreaterThanOrEqual(
            controller.sidebarItem.viewController.view.frame.width,
            WorkspaceSplitMetrics.sidebarMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            controller.detailItem.viewController.view.frame.width,
            WorkspaceSplitMetrics.detailMinimumWidth - 1
        )
    }

    func testFreshNativeSplitStartsAtReferenceSidebarWidth() {
        let autosaveName = "Monknot.WorkspaceSplitTests.\(UUID().uuidString)"
        let autosaveKey = "NSSplitView Subview Frames \(autosaveName)"
        UserDefaults.standard.removeObject(forKey: autosaveKey)
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey) }

        let controller = makeController(
            isSidebarPresented: true,
            autosaveName: autosaveName
        )
        let window = mount(controller)

        XCTAssertEqual(
            controller.sidebarItem.viewController.view.frame.width,
            WorkspaceSplitMetrics.sidebarMinimumWidth,
            accuracy: 1
        )
        _ = window
    }

    func testMountedNativeSplitPreservesAbsoluteSidebarWidthWhenWindowResizes() {
        let controller = makeController(isSidebarPresented: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let userWidth = controller.sidebarItem.viewController.view.frame.width

        window.setContentSize(NSSize(width: 1_500, height: 780))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(userWidth, WorkspaceSplitMetrics.sidebarMinimumWidth - 1)
        XCTAssertLessThanOrEqual(userWidth, WorkspaceSplitMetrics.sidebarMaximumWidth + 1)
        XCTAssertEqual(
            controller.sidebarItem.viewController.view.frame.width,
            userWidth,
            accuracy: 1,
            "AppKit should preserve the user's absolute sidebar width when preferredThicknessFraction is unspecified"
        )
    }

    func testSidebarResizeHandleDrivesNativeItemAcrossSupportedRange() {
        let controller = makeController(isSidebarPresented: true)
        let window = mount(controller, width: 1_500)

        for width in [
            WorkspaceSplitMetrics.sidebarMaximumWidth,
            WorkspaceSplitMetrics.sidebarMinimumWidth,
            340,
        ] {
            controller.setSidebarWidth(width)
            XCTAssertEqual(controller.sidebarItem.minimumThickness, width, accuracy: 1)
            XCTAssertEqual(controller.sidebarItem.maximumThickness, width, accuracy: 1)
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                controller.splitView.arrangedSubviews[0].frame.width,
                width,
                accuracy: 1
            )
        }
    }

    func testSidebarDividerUsesWideDetailSideHandleWithThinNativeRendering() {
        let controller = makeController(isSidebarPresented: true)
        let window = mount(controller)
        XCTAssertTrue(controller.splitView.delegate === controller)
        let splitView = controller.splitView
        let sidebarFrame = splitView.arrangedSubviews[0].frame
        let detailFrame = splitView.arrangedSubviews[1].frame
        let dividerRect = NSRect(
            x: sidebarFrame.maxX,
            y: controller.splitView.bounds.minY,
            width: controller.splitView.dividerThickness,
            height: controller.splitView.bounds.height
        )
        let hitRect = controller.sidebarResizeHitRect

        XCTAssertEqual(
            dividerRect.minX,
            sidebarFrame.maxX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.splitView.dividerThickness,
            WorkspaceSplitMetrics.visibleDividerWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            detailFrame.minX,
            dividerRect.maxX,
            accuracy: 0.001,
            "The native divider must remain outside the detail pane"
        )
        XCTAssertEqual(hitRect.minX, detailFrame.minX, accuracy: 0.001)
        XCTAssertEqual(hitRect.width, WorkspaceSplitMetrics.sidebarResizeHitWidth, accuracy: 0.001)
        XCTAssertEqual(hitRect.height, splitView.bounds.height, accuracy: 0.001)
        XCTAssertEqual(hitRect.minX, dividerRect.maxX, accuracy: 0.001)
        XCTAssertGreaterThan(hitRect.maxX, dividerRect.maxX)
        let resizeHandle = try! XCTUnwrap(controller.sidebarResizeProxy.handleView)
        XCTAssertTrue(resizeHandle.isDescendant(of: controller.detailHostingController.view))
        _ = window
    }

    private func makeController(
        isSidebarPresented: Bool,
        autosaveName: String = WorkspaceSplitMetrics.autosaveName
    ) -> WorkspaceSplitViewController<Color, Color> {
        WorkspaceSplitViewController(
            sidebar: Color.red,
            detail: Color.blue,
            isSidebarPresented: isSidebarPresented,
            autosaveName: autosaveName
        )
    }

    private func mount(
        _ controller: WorkspaceSplitViewController<Color, Color>,
        width: CGFloat = 920
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

}
