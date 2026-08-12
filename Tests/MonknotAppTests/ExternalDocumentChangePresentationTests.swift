import MonknotCore
import XCTest
@testable import MonknotApp

final class ExternalDocumentChangePresentationTests: XCTestCase {
    func testEmptyAndConsecutiveBlankChangesUseOneCompactRowEach() throws {
        let removed = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\n\n\nomega\n",
            to: "alpha\nomega\n",
            contextLines: 0
        )
        let added = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\nomega\n",
            to: "alpha\n\n\nomega\n",
            contextLines: 0
        )
        let lightMetrics = ExternalDocumentDiffLayoutMetrics(theme: try harborLight(), zoomScale: 1)
        let darkMetrics = ExternalDocumentDiffLayoutMetrics(theme: try harborDark(), zoomScale: 1)

        let removedLines = removed.hunks.flatMap(\.lines)
        let addedLines = added.hunks.flatMap(\.lines)
        XCTAssertEqual(removedLines.map(\.kind), [.removal, .removal])
        XCTAssertEqual(addedLines.map(\.kind), [.addition, .addition])
        XCTAssertTrue((removedLines + addedLines).allSatisfy(\.text.isEmpty))

        for line in removedLines + addedLines {
            XCTAssertEqual(lightMetrics.height(for: line), lightMetrics.rowHeight)
            XCTAssertEqual(darkMetrics.height(for: line), darkMetrics.rowHeight)
            XCTAssertLessThanOrEqual(lightMetrics.rowHeight, 34)
        }
    }

    func testLongLinesUseHorizontalWidthAtNarrowAndWideViewports() throws {
        let longLine = String(repeating: "0123456789", count: 160)
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "short\n",
            to: "\(longLine)\n",
            contextLines: 0
        )
        let metrics = ExternalDocumentDiffLayoutMetrics(theme: try harborLight(), zoomScale: 1)
        let narrowWidth = metrics.contentWidth(for: diff, viewportWidth: 420)
        let wideWidth = metrics.contentWidth(for: diff, viewportWidth: 900)

        XCTAssertGreaterThan(narrowWidth, 900)
        XCTAssertEqual(narrowWidth, wideWidth, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(wideWidth, 900)
    }

    func testOneLineUnicodeAndMixedLineEndingDiffsRetainStableRows() throws {
        let cases = [
            ("old", "new"),
            ("café 👩🏽‍💻\n", "咖啡 🚀\n"),
            ("alpha\r\nbeta\r\n", "alpha\r\nlocal\r\n")
        ]
        let metrics = ExternalDocumentDiffLayoutMetrics(theme: try harborDark(), zoomScale: 1)

        for (oldText, newText) in cases {
            let diff = ExternalDocumentReconciliationService.unifiedDiff(
                from: oldText,
                to: newText,
                contextLines: 0
            )
            let lines = diff.hunks.flatMap(\.lines)
            XCTAssertFalse(lines.isEmpty)
            XCTAssertTrue(lines.allSatisfy { metrics.height(for: $0) == metrics.rowHeight })
            XCTAssertTrue(lines.allSatisfy { !$0.text.contains("\n") })
        }
    }

    func testAddedOnlyAndRemovedOnlySummariesCountLogicalLines() throws {
        let added = ExternalDocumentReconciliationService.unifiedDiff(
            from: "",
            to: "one\n\nthree\n",
            contextLines: 0
        )
        let removed = ExternalDocumentReconciliationService.unifiedDiff(
            from: "one\n\nthree\n",
            to: "",
            contextLines: 0
        )

        let addedSummary = ExternalDocumentDiffSummary(diff: added)
        let removedSummary = ExternalDocumentDiffSummary(diff: removed)
        XCTAssertEqual(addedSummary.addedLineCount, 3)
        XCTAssertEqual(addedSummary.removedLineCount, 0)
        XCTAssertEqual(removedSummary.addedLineCount, 0)
        XCTAssertEqual(removedSummary.removedLineCount, 3)
    }

    func testLargeHunkKeepsEveryLogicalLineAtTheSameHeight() throws {
        let oldText = (1...500).map { "disk \($0)" }.joined(separator: "\n") + "\n"
        let newText = (1...500).map { "mine \($0)" }.joined(separator: "\n") + "\n"
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: oldText,
            to: newText,
            contextLines: 3
        )
        let metrics = ExternalDocumentDiffLayoutMetrics(theme: try harborLight(), zoomScale: 1)
        let lines = diff.hunks.flatMap(\.lines)

        XCTAssertEqual(lines.count, 1_000)
        XCTAssertTrue(lines.allSatisfy { metrics.height(for: $0) == metrics.rowHeight })
        XCTAssertEqual(ExternalDocumentDiffSummary(diff: diff).addedLineCount, 500)
        XCTAssertEqual(ExternalDocumentDiffSummary(diff: diff).removedLineCount, 500)
    }

    func testHarborThemesAndSupportedWidthsShareTheFourColumnContract() throws {
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "disk\n",
            to: "mine\n",
            contextLines: 0
        )
        let light = ExternalDocumentDiffLayoutMetrics(theme: try harborLight(), zoomScale: 1)
        let dark = ExternalDocumentDiffLayoutMetrics(theme: try harborDark(), zoomScale: 1)

        XCTAssertEqual(light.oldLineNumberWidth, dark.oldLineNumberWidth)
        XCTAssertEqual(light.newLineNumberWidth, dark.newLineNumberWidth)
        XCTAssertEqual(light.markerWidth, dark.markerWidth)
        XCTAssertGreaterThan(light.oldLineNumberWidth, 0)
        XCTAssertGreaterThan(light.newLineNumberWidth, 0)
        XCTAssertGreaterThan(light.markerWidth, 0)
        XCTAssertEqual(light.contentWidth(for: diff, viewportWidth: 420), 420)
        XCTAssertEqual(dark.contentWidth(for: diff, viewportWidth: 900), 900)
    }

    private func harborLight() throws -> AppTheme {
        try XCTUnwrap(MonknotThemeCatalog.lightPresets.first { $0.theme.id == "harbor-light" }?.theme)
    }

    private func harborDark() throws -> AppTheme {
        try XCTUnwrap(MonknotThemeCatalog.darkPresets.first { $0.theme.id == "harbor-dark" }?.theme)
    }
}
