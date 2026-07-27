import AppKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class DocumentSplitViewRatioAccessorTests: XCTestCase {
    func testApplyingInitialRatioDoesNotReenterResizeObserver() {
        let ratio = Box(0.6)
        let committedRatios = Box<[Double]>([])
        let splitView = makeSplitView()
        let coordinator = makeCoordinator(
            ratio: ratio,
            committedRatios: committedRatios
        )

        coordinator.attach(to: splitView)

        let availableWidth = splitView.frame.width - splitView.dividerThickness
        XCTAssertEqual(
            splitView.arrangedSubviews[0].frame.width / availableWidth,
            0.6,
            accuracy: 0.01
        )
        XCTAssertEqual(ratio.value, 0.6, accuracy: 0.001)
        XCTAssertTrue(committedRatios.value.isEmpty)
    }

    func testUserResizePersistsAndIsNotResetByUnchangedConfiguration() {
        let ratio = Box(0.6)
        let committedRatios = Box<[Double]>([])
        let splitView = makeSplitView()
        let coordinator = makeCoordinator(
            ratio: ratio,
            committedRatios: committedRatios
        )
        coordinator.attach(to: splitView)

        splitView.setPosition(700, ofDividerAt: 0)
        let resizedWidth = splitView.arrangedSubviews[0].frame.width

        XCTAssertEqual(ratio.value, 700 / 999, accuracy: 0.01)
        XCTAssertEqual(committedRatios.value.last ?? 0, ratio.value, accuracy: 0.001)

        coordinator.updateConfiguration(
            sourcePaneRatio: Binding(
                get: { ratio.value },
                set: { ratio.value = $0 }
            ),
            minPaneWidth: 240,
            onCommit: { committedRatios.value.append($0) }
        )

        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, resizedWidth, accuracy: 0.001)
    }

    private func makeSplitView() -> NSSplitView {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView())
        splitView.addArrangedSubview(NSView())
        splitView.layoutSubtreeIfNeeded()
        return splitView
    }

    private func makeCoordinator(
        ratio: Box<Double>,
        committedRatios: Box<[Double]>
    ) -> DocumentSplitViewRatioAccessor.Coordinator {
        let ratioBinding = Binding(
            get: { ratio.value },
            set: { ratio.value = $0 }
        )
        return DocumentSplitViewRatioAccessor.Coordinator(
            sourcePaneRatio: ratioBinding,
            minPaneWidth: 240,
            onCommit: { committedRatios.value.append($0) }
        )
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
