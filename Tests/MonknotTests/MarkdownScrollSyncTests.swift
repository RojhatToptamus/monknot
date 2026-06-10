import XCTest
@testable import MonknotCore

final class MarkdownScrollSyncTests: XCTestCase {
    func testLineNumberForCharacterIndex() {
        let text = "alpha\nbeta\ngamma"
        XCTAssertEqual(MarkdownScrollSync.lineNumber(forCharacterIndex: 0, in: text), 1)
        XCTAssertEqual(MarkdownScrollSync.lineNumber(forCharacterIndex: 6, in: text), 2)
        XCTAssertEqual(MarkdownScrollSync.lineNumber(forCharacterIndex: 11, in: text), 3)
    }

    func testCharacterOffsetForLine() {
        let text = "alpha\nbeta\ngamma"
        XCTAssertEqual(MarkdownScrollSync.characterOffset(forLine: 1, in: text), 0)
        XCTAssertEqual(MarkdownScrollSync.characterOffset(forLine: 2, in: text), 6)
        XCTAssertEqual(MarkdownScrollSync.characterOffset(forLine: 3, in: text), 11)
    }
}
