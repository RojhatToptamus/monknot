import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class TerminalResizeHandleTests: XCTestCase {
    func testResizeHandleUsesAForgivingInvisibleHitTarget() {
        XCTAssertGreaterThanOrEqual(MonknotMetrics.terminalResizeHitWidth, 28)
    }

    func testDragStartsFromDisplayedWidthWhenSavedWidthExceedsCurrentMaximum() {
        var width = 720.0
        let binding = Binding(
            get: { width },
            set: { width = $0 }
        )
        let coordinator = TerminalResizeHandle.Coordinator(
            width: binding,
            minWidth: 320,
            maxWidth: 500
        )

        coordinator.beginDrag(at: 100)
        coordinator.drag(to: 110)

        XCTAssertEqual(width, 490, accuracy: 0.001)
    }

    func testDragStartsFromDisplayedWidthWhenSavedWidthIsBelowCurrentMinimum() {
        var width = 200.0
        let binding = Binding(
            get: { width },
            set: { width = $0 }
        )
        let coordinator = TerminalResizeHandle.Coordinator(
            width: binding,
            minWidth: 320,
            maxWidth: 600
        )

        coordinator.beginDrag(at: 100)
        coordinator.drag(to: 90)

        XCTAssertEqual(width, 330, accuracy: 0.001)
    }

    func testResizeHandleExposesAdjustableSplitterSemantics() {
        var width = 420.0
        let binding = Binding(
            get: { width },
            set: { width = $0 }
        )
        let coordinator = TerminalResizeHandle.Coordinator(
            width: binding,
            minWidth: 360,
            maxWidth: 500
        )
        let view = TerminalResizeHandle.ResizeHandleView()
        view.coordinator = coordinator

        XCTAssertEqual(view.accessibilityRole(), .splitter)
        XCTAssertEqual(view.accessibilityOrientation(), .vertical)
        XCTAssertEqual(view.accessibilityValue() as? NSNumber, 420)
        XCTAssertEqual(view.accessibilityMinValue() as? NSNumber, 360)
        XCTAssertEqual(view.accessibilityMaxValue() as? NSNumber, 500)

        XCTAssertTrue(view.accessibilityPerformIncrement())
        XCTAssertEqual(width, 440)
        XCTAssertTrue(view.accessibilityPerformDecrement())
        XCTAssertEqual(width, 420)
    }
}
