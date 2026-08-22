import Foundation
import XCTest
@testable import MonknotCore

final class GoToLineInputTests: MarkdownWorkspaceLinkTestCase {
    func testGoToLineInputParsesUnicodeCRLFAndTrailingEmptyLine() throws {
        let markdown = "alpha\r\n😀café\r\n"

        XCTAssertEqual(
            try MarkdownSourceLocationInputParser.parse("2:2", in: markdown).get(),
            MarkdownSourceLocation(line: 2, offset: 2),
            "the second visible column follows the emoji's UTF-16 surrogate pair"
        )
        XCTAssertEqual(
            try MarkdownSourceLocationInputParser.parse(" 3 ", in: markdown).get(),
            MarkdownSourceLocation(line: 3, offset: 0)
        )
        XCTAssertEqual(
            MarkdownSourceLocationValidator.validated(
                MarkdownSourceLocation(line: 3, offset: 0),
                in: markdown
            ),
            MarkdownSourceLocation(line: 3, offset: 0)
        )
    }

    func testGoToLineInputReportsInvalidAndOutOfRangePositions() throws {
        let markdown = "one\ntwo"

        XCTAssertEqual(
            MarkdownSourceLocationInputParser.parse("", in: markdown),
            .failure(.invalidFormat)
        )
        XCTAssertEqual(
            MarkdownSourceLocationInputParser.parse("1:0", in: markdown),
            .failure(.invalidFormat)
        )
        XCTAssertEqual(
            MarkdownSourceLocationInputParser.parse("3", in: markdown),
            .failure(.lineOutOfRange(maximum: 2))
        )
        XCTAssertEqual(
            try MarkdownSourceLocationInputParser.parse("2:4", in: markdown).get(),
            MarkdownSourceLocation(line: 2, offset: 3)
        )
        XCTAssertEqual(
            MarkdownSourceLocationInputParser.parse("2:5", in: markdown),
            .failure(.columnOutOfRange(maximum: 4))
        )
    }
}
