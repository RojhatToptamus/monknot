import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class StableWidthLayoutTests: XCTestCase {
    func testTemplatesCoverEveryValueWithTheSameDigitCount() {
        XCTAssertEqual(MonknotStableWidth.digits(0), "0")
        XCTAssertEqual(MonknotStableWidth.digits(3), "000")
        XCTAssertEqual(MonknotStableWidth.pageTemplate(pageCount: 7), "0/0")
        XCTAssertEqual(MonknotStableWidth.pageTemplate(pageCount: 120), "000/000")
        XCTAssertEqual(MonknotStableWidth.lineNumberTemplate(maximumLine: 1_042), "0000")
        XCTAssertEqual(PDFPageStatus(currentPage: 3, pageCount: 214, isAvailable: true).widthTemplate, "000/000")
    }

    func testReservedSlotKeepsOneWidthAsTheValueChanges() {
        func width(_ value: String) -> CGFloat {
            let view = Text(verbatim: value)
                .monknotReservingWidth(of: MonknotStableWidth.pageTemplate(pageCount: 120))
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .fixedSize()
            return NSHostingView(rootView: view).fittingSize.width
        }

        let widths = ["1/120", "9/120", "48/120", "120/120"].map(width)
        XCTAssertEqual(Set(widths).count, 1, "Turning pages must not resize the page indicator: \(widths)")
    }

    func testSearchLocationColumnFitsTheWidestLabelOfEachKind() {
        func result(_ kind: WorkspaceSearchResultKind, line: Int) -> WorkspaceSearchResult {
            WorkspaceSearchResult(
                id: "\(kind)-\(line)",
                documentID: "/tmp/a",
                relativePath: "a",
                displayName: "a",
                kind: kind,
                line: line,
                column: 1,
                preview: "a"
            )
        }

        XCTAssertEqual(WorkspaceSearchLocationColumn.widthTemplates(for: []), [])
        XCTAssertEqual(
            WorkspaceSearchLocationColumn.widthTemplates(for: [result(.text, line: 9), result(.text, line: 1_204)]),
            ["0000"]
        )
        XCTAssertEqual(
            WorkspaceSearchLocationColumn.widthTemplates(for: [result(.text, line: 12), result(.pdf, line: 3)]),
            ["00", "p0"]
        )
        XCTAssertEqual(WorkspaceSearchLocationColumn.label(for: result(.pdf, line: 3)), "p3")
        XCTAssertEqual(WorkspaceSearchLocationColumn.label(for: result(.text, line: 31)), "31")
    }
}
