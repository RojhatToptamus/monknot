import XCTest
@testable import MonknotCore

final class HTMLScrollSyncTests: XCTestCase {
    func testScrollFractionMapsLineToNormalizedPosition() {
        XCTAssertEqual(HTMLScrollSync.scrollFraction(forLine: 1, totalLines: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(HTMLScrollSync.scrollFraction(forLine: 10, totalLines: 10), 1, accuracy: 0.0001)
        XCTAssertEqual(HTMLScrollSync.scrollFraction(forLine: 5, totalLines: 10), 4.0 / 9.0, accuracy: 0.0001)
    }

    func testLineMapsScrollFractionBackToSourceLine() {
        XCTAssertEqual(HTMLScrollSync.line(forScrollFraction: 0, totalLines: 10), 1)
        XCTAssertEqual(HTMLScrollSync.line(forScrollFraction: 1, totalLines: 10), 10)
        XCTAssertEqual(HTMLScrollSync.line(forScrollFraction: 0.5, totalLines: 10), 6)
    }

    func testTotalLinesCountsNewlines() {
        XCTAssertEqual(HTMLScrollSync.totalLines(in: ""), 1)
        XCTAssertEqual(HTMLScrollSync.totalLines(in: "one"), 1)
        XCTAssertEqual(HTMLScrollSync.totalLines(in: "one\ntwo\nthree"), 3)
    }
}
