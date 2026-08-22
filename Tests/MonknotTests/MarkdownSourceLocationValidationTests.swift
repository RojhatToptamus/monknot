import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownSourceLocationValidationTests: MarkdownWorkspaceLinkTestCase {
    func testSourceLocationValidationRejectsStaleLinesAndOffsets() {
        let text = "alpha\r\n😀beta\n"

        XCTAssertEqual(
            MarkdownSourceLocationValidator.validated(
                MarkdownSourceLocation(line: 2, offset: 2),
                in: text
            ),
            MarkdownSourceLocation(line: 2, offset: 2)
        )
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 2, offset: 7),
            in: text
        ))
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 4, offset: 0),
            in: text
        ))
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 0, offset: 0),
            in: text
        ))
    }
}
