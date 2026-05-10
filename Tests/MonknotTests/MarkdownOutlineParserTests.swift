import XCTest
@testable import MonknotCore

final class MarkdownOutlineParserTests: XCTestCase {
    func testParsesATXHeadingsWithLineNumbers() {
        let markdown = """
        # Title

        Body
        ## Details
        #### Deep
        """

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), ["Title", "Details", "Deep"])
        XCTAssertEqual(items.map(\.level), [1, 2, 4])
        XCTAssertEqual(items.map { $0.location.line }, [1, 4, 5])
    }

    func testIgnoresHeadingsInsideFencedCodeBlocks() {
        let markdown = """
        # Real

        ```swift
        # Not a heading
        ```

        ## Also Real
        """

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), ["Real", "Also Real"])
        XCTAssertEqual(items.map { $0.location.line }, [1, 7])
    }

    func testPreservesHashCharactersThatArePartOfHeadingText() {
        let markdown = """
        # C#
        ## Title ###
        ### Keep###Together
        """

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), ["C#", "Title", "Keep###Together"])
    }

    func testRequiresClosingFenceToMatchOpeningFenceLength() {
        let markdown = """
        # Real
        ````swift
        ## Ignored
        ```
        ## Still Ignored
        ````
        ## Visible
        """

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), ["Real", "Visible"])
        XCTAssertEqual(items.map { $0.location.line }, [1, 7])
    }

    func testSupportsTildeFencesAndCRLFInput() {
        let markdown = "# Real\r\n~~~\r\n## Ignored\r\n~~~\r\n## Visible\r\n"

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), ["Real", "Visible"])
        XCTAssertEqual(items.map { $0.location.line }, [1, 5])
    }
}
