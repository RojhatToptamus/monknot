import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownTaskSourceMutationTests: MarkdownWorkspaceLinkTestCase {
    func testTaskReplacementRevalidatesLineAndExpectedStateWhilePreservingCRLF() throws {
        let markdown = "Intro\r\n- [ ] first\r\n1. [X] second\r\n"
        let first = try XCTUnwrap(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 2,
            expectedChecked: false,
            desiredChecked: true
        ))
        XCTAssertEqual((markdown as NSString).substring(with: first.range.nsRange), " ")
        XCTAssertEqual(first.replacementText, "x")

        let second = try XCTUnwrap(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 3,
            expectedChecked: true,
            desiredChecked: false
        ))
        XCTAssertEqual(second.expectedText, "X")
        XCTAssertEqual(second.replacementText, " ")
        XCTAssertNil(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 2,
            expectedChecked: true,
            desiredChecked: false
        ))
        XCTAssertNil(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 1,
            expectedChecked: false,
            desiredChecked: true
        ))
    }
}
