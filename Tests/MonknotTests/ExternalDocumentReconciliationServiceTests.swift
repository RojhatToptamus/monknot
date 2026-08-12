import Foundation
import XCTest
@testable import MonknotCore

final class ExternalDocumentReconciliationServiceTests: XCTestCase {
    func testConditionalDataWriterRejectsStaleBinaryAndPreservesDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper.pdf")
        let baseline = Data([1, 2, 3])
        let disk = Data([4, 5, 6])
        try disk.write(to: url)

        XCTAssertThrowsError(try WorkspaceConditionalDataWriter.write(
            Data([7, 8, 9]),
            to: url,
            expecting: .present(baseline)
        )) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: url), disk)
    }

    func testConditionalDataWriterAtomicallyReplacesExpectedBinary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper.pdf")
        let baseline = Data([1, 2, 3])
        let updated = Data([7, 8, 9])
        try baseline.write(to: url)

        let written = try WorkspaceConditionalDataWriter.write(
            updated,
            to: url,
            expecting: .present(baseline)
        )

        XCTAssertEqual(written, updated)
        XCTAssertEqual(try Data(contentsOf: url), updated)
    }

    func testConditionalDataWriterCreatesOnlyWhenStillAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper Copy.pdf")
        let created = Data([1, 2, 3])

        XCTAssertEqual(
            try WorkspaceConditionalDataWriter.write(created, to: url, expecting: .absent),
            created
        )
        XCTAssertEqual(try Data(contentsOf: url), created)

        XCTAssertThrowsError(try WorkspaceConditionalDataWriter.write(
            Data([4, 5, 6]),
            to: url,
            expecting: .absent
        )) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .unexpectedlyCreated)
        }
        XCTAssertEqual(try Data(contentsOf: url), created)
    }

    func testMergeUsesChangedSideWhenOtherSideIsBaseline() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "alpha\nbeta\n",
                local: "alpha\nbeta\n",
                disk: "alpha\ndisk\n"
            ),
            "alpha\ndisk\n"
        )
    }

    func testMergeCombinesDisjointUnicodeEdits() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "😀 alpha\nbeta\ngamma\n",
                local: "😀 local\nbeta\ngamma\n",
                disk: "😀 alpha\nbeta\ndisk\n"
            ),
            "😀 local\nbeta\ndisk\n"
        )
    }

    func testMergeCombinesMultipleMineHunksWithDisjointDiskHunk() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "a\nb\nc\nd\ne\n",
                local: "A\nb\nc\nd\nE\n",
                disk: "a\nb\nC\nd\ne\n"
            ),
            "A\nb\nC\nd\nE\n"
        )
    }

    func testMergeCombinesMultipleDisjointHunksOnBothSides() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "a\nb\nc\nd\ne\nf\ng\n",
                local: "A\nb\nc\nd\nE\nf\ng\n",
                disk: "a\nb\nC\nd\ne\nf\nG\n"
            ),
            "A\nb\nC\nd\nE\nf\nG\n"
        )
    }

    func testMergeDeduplicatesSharedHunkWhileCombiningOtherHunks() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "a\nb\nc\n",
                local: "A\nb\nC\n",
                disk: "A\nB\nc\n"
            ),
            "A\nB\nC\n"
        )
    }

    func testMergeCombinesMultipleDisjointCRLFHunks() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "a\r\nb\r\nc\r\nd\r\ne\r\n",
                local: "A\r\nb\r\nc\r\nd\r\nE\r\n",
                disk: "a\r\nb\r\nC\r\nd\r\ne\r\n"
            ),
            "A\r\nb\r\nC\r\nd\r\nE\r\n"
        )
    }

    func testMergeDoesNotSplitEmojiGraphemes() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "😀a",
                local: "😁a",
                disk: "😀b"
            ),
            "😁b"
        )
    }

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

    func testMergeRejectsOverlappingEditsWithoutConflictMarkers() {
        XCTAssertNil(
            ExternalDocumentReconciliationService.merge(
                baseline: "one two three",
                local: "one LOCAL three",
                disk: "one DISK three"
            )
        )
    }

    func testMergeRejectsInsertionInsideOtherSideDeletion() {
        XCTAssertNil(
            ExternalDocumentReconciliationService.merge(
                baseline: "abcde",
                local: "abXcde",
                disk: "ae"
            )
        )
    }

    func testMergeRejectsDivergentInsertionsAtSameBoundary() {
        XCTAssertNil(
            ExternalDocumentReconciliationService.merge(
                baseline: "abc",
                local: "aXbc",
                disk: "aYbc"
            )
        )
    }

    func testMergeKeepsInsertionAtReplacementBoundary() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "abc",
                local: "aXbc",
                disk: "aBc"
            ),
            "aXBc"
        )
    }

    func testMergeRejectsOverlappingDeletions() {
        XCTAssertNil(
            ExternalDocumentReconciliationService.merge(
                baseline: "abcdef",
                local: "abef",
                disk: "abcf"
            )
        )
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

    func testConditionalWriterRejectsStaleDiskAndPreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        try Data("baseline".utf8).write(to: url)
        let expected = try WorkspaceConditionalTextWriter.read(from: url)
        try Data("external".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(
            try WorkspaceConditionalTextWriter.write(
                "local",
                to: url,
                expecting: .present(expected)
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    func testConditionalWriterReadRefreshesSignatureAfterAtomicReplacement() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        try Data("disk\n".utf8).write(to: url)
        let initial = try WorkspaceConditionalTextWriter.read(from: url)

        let replacement = "newest disk\n"
        try Data(replacement.utf8).write(to: url, options: .atomic)
        let current = try WorkspaceConditionalTextWriter.read(from: url)

        XCTAssertEqual(current.text, replacement)
        XCTAssertEqual(current.signature.fileSize, Int64(replacement.utf8.count))
        XCTAssertNotEqual(current.signature.fileSize, initial.signature.fileSize)
    }

    func testConditionalWriterCreatesOnlyWhenStillAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        _ = try WorkspaceConditionalTextWriter.write("created", to: url, expecting: .absent)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "created")

        XCTAssertThrowsError(
            try WorkspaceConditionalTextWriter.write("overwrite", to: url, expecting: .absent)
        ) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .unexpectedlyCreated)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "created")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDocumentReconciliationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
