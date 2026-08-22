import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownHeadingNormalizationTests: MarkdownWorkspaceLinkTestCase {
    func testHeadingNormalizationMatchesRendererRulesAndFindsFirstHeading() {
        XCTAssertEqual(MarkdownHeadingFragment.normalized("  Hello, **World**!  "), "hello-world")
        XCTAssertEqual(MarkdownHeadingFragment.normalized("日本語"), "section")
        XCTAssertEqual(MarkdownHeadingFragment.normalized("A---B"), "a-b")

        let markdown = """
        ```md
        # Hidden Heading
        ```
        # Hello, **World**!
        ## Later
        """
        XCTAssertEqual(
            MarkdownHeadingFragment.sourceLocation(for: "hello-world", in: markdown),
            MarkdownSourceLocation(line: 4, offset: 0)
        )
        XCTAssertNil(MarkdownHeadingFragment.sourceLocation(for: "hidden-heading", in: markdown))
    }
}
