import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSplitPersistenceTests: WorkspaceSplitViewTestCase {
    func testAutosaveRestoresPeripheralWidthsAcrossControllerRecreation() async throws {
        let autosaveName = "Monknot.WorkspaceSplitTests.\(UUID().uuidString)"
        defer { removeSplitAutosaveDefaults(named: autosaveName) }

        let restoredGeometry = try await seedAndVerifyAutosavedSplitGeometry(
            named: autosaveName,
            sidebarWidth: 365,
            terminalWidth: 435
        )

        XCTAssertEqual(restoredGeometry.sidebar, 365, accuracy: 2)
        XCTAssertEqual(restoredGeometry.terminal, 435, accuracy: 2)
    }

    func testNarrowMigrationRetainsBothLegacyPeripheralWidthsIndependently() async {
        let legacySidebarWidth: CGFloat = 390
        let legacyTerminalWidth: CGFloat = 470

        await withLegacySidebarWidth(legacySidebarWidth) {
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
    }

    func testScaleTwoNarrowMigrationStagesAndRestoresScaledNativeWidths() async {
        let legacySidebarWidth: CGFloat = 360
        let legacyTerminalWidth: CGFloat = 520

        await withLegacySidebarWidth(legacySidebarWidth) {
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
}
