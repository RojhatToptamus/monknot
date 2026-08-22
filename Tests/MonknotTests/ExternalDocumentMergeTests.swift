import Foundation
import XCTest
@testable import MonknotCore

final class ExternalDocumentMergeTests: ExternalDocumentReconciliationTestCase {
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
}
