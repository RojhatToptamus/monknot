import Foundation
import XCTest
@testable import MonknotCore

final class UnifiedDiffTests: ExternalDocumentReconciliationTestCase {
    func testMergeAndUnifiedDiffPreserveCRLFContent() throws {
        let baseline = "alpha\r\nbeta\r\ngamma\r\n"
        let local = "local\r\nbeta\r\ngamma\r\n"
        let disk = "alpha\r\nbeta\r\ndisk\r\n"

        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: baseline,
                local: local,
                disk: disk
            ),
            "local\r\nbeta\r\ndisk\r\n"
        )

        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\r\nbeta\r\n",
            to: "alpha\r\nlocal\r\n",
            contextLines: 0
        )
        let lines = try XCTUnwrap(diff.hunks.first?.lines)
        XCTAssertEqual(lines.map(\.kind), [.removal, .addition])
        XCTAssertEqual(lines.map(\.text), ["beta\r", "local\r"])
        XCTAssertEqual(lines.map(\.hasTerminatingNewline), [true, true])
    }

    func testUnifiedDiffReturnsNoHunksForIdenticalText() {
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\nbeta\n",
            to: "alpha\nbeta\n"
        )

        XCTAssertFalse(diff.hasChanges)
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testUnifiedDiffShowsReplacementWithIndicatorsContextAndLineNumbers() throws {
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\nbeta\ngamma\n",
            to: "alpha\nlocal\ngamma\n",
            contextLines: 1
        )

        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(hunk.oldStartLine, 1)
        XCTAssertEqual(hunk.oldLineCount, 3)
        XCTAssertEqual(hunk.newStartLine, 1)
        XCTAssertEqual(hunk.newLineCount, 3)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removal, .addition, .context])
        XCTAssertEqual(hunk.lines.map(\.indicator), [" ", "−", "+", " "])
        XCTAssertEqual(hunk.lines.map(\.text), ["alpha", "beta", "local", "gamma"])
        XCTAssertEqual(hunk.lines.map(\.oldLineNumber), [1, 2, nil, 3])
        XCTAssertEqual(hunk.lines.map(\.newLineNumber), [1, nil, 2, 3])
    }

    func testUnifiedDiffSeparatesDistantChangesIntoContextHunks() {
        let oldLines = (1...10).map { "line \($0)" }
        var newLines = oldLines
        newLines[1] = "local two"
        newLines[8] = "local nine"

        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: oldLines.joined(separator: "\n"),
            to: newLines.joined(separator: "\n"),
            contextLines: 1
        )

        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks[0].lines.map(\.text), ["line 1", "line 2", "local two", "line 3"])
        XCTAssertEqual(diff.hunks[1].lines.map(\.text), ["line 8", "line 9", "local nine", "line 10"])
        XCTAssertEqual(diff.hunks[0].oldStartLine, 1)
        XCTAssertEqual(diff.hunks[0].newStartLine, 1)
        XCTAssertEqual(diff.hunks[1].oldStartLine, 8)
        XCTAssertEqual(diff.hunks[1].newStartLine, 8)
    }

    func testUnifiedDiffHandlesInsertionAndDeletionAtDocumentEdges() {
        let insertion = ExternalDocumentReconciliationService.unifiedDiff(
            from: "beta\n",
            to: "alpha\nbeta\n",
            contextLines: 0
        )
        let deletion = ExternalDocumentReconciliationService.unifiedDiff(
            from: "alpha\nbeta\n",
            to: "alpha\n",
            contextLines: 0
        )

        XCTAssertEqual(insertion.hunks.first?.oldStartLine, 0)
        XCTAssertEqual(insertion.hunks.first?.oldLineCount, 0)
        XCTAssertEqual(insertion.hunks.first?.newStartLine, 1)
        XCTAssertEqual(insertion.hunks.first?.lines.map(\.kind), [.addition])
        XCTAssertEqual(insertion.hunks.first?.lines.map(\.text), ["alpha"])

        XCTAssertEqual(deletion.hunks.first?.oldStartLine, 2)
        XCTAssertEqual(deletion.hunks.first?.newStartLine, 1)
        XCTAssertEqual(deletion.hunks.first?.newLineCount, 0)
        XCTAssertEqual(deletion.hunks.first?.lines.map(\.kind), [.removal])
        XCTAssertEqual(deletion.hunks.first?.lines.map(\.text), ["beta"])
    }

    func testUnifiedDiffPreservesTrailingNewlineChanges() throws {
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "value",
            to: "value\n",
            contextLines: 0
        )

        let lines = try XCTUnwrap(diff.hunks.first?.lines)
        XCTAssertEqual(lines.map(\.kind), [.removal, .addition])
        XCTAssertEqual(lines.map(\.text), ["value", "value"])
        XCTAssertEqual(lines.map(\.hasTerminatingNewline), [false, true])
    }

    func testUnifiedDiffHandlesEmptyUnicodeTextAndClampsNegativeContext() throws {
        let longUnicodeLine = String(repeating: "😀", count: 2_000)
        let diff = ExternalDocumentReconciliationService.unifiedDiff(
            from: "",
            to: longUnicodeLine,
            contextLines: -20
        )

        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(hunk.oldStartLine, 0)
        XCTAssertEqual(hunk.oldLineCount, 0)
        XCTAssertEqual(hunk.newStartLine, 1)
        XCTAssertEqual(hunk.newLineCount, 1)
        XCTAssertEqual(hunk.lines.map(\.kind), [.addition])
        XCTAssertEqual(hunk.lines.first?.text, longUnicodeLine)
        XCTAssertFalse(hunk.lines.first?.hasTerminatingNewline ?? true)
    }
}
