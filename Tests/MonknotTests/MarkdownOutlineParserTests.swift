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

    func testOutlineTitlesUseRenderedMarkdownText() {
        let markdown = """
        # **Bold** and *italic*
        ## `Code` [Link](https://example.com)
        ### ![Alt](image.png)
        """

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), [
            "Bold and italic",
            "Code Link",
            "Alt"
        ])
    }

    func testOutlineTitlesPreserveCommonEscapes() {
        let markdown = #"""
        # **real _nested_**
        ## Keep C:\Users\Name and \[brackets\]
        ### ~~real strike~~
        """#

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), [
            "real nested",
            #"Keep C:\Users\Name and [brackets]"#,
            "real strike"
        ])
    }

    func testOutlineTitlesHandleCommonInlineMarkdown() {
        let markdown = #"""
        # **Bold _nested_**
        ## [A **bold** label](https://example.com/a.md) ![Alt image](assets/img.png)
        ### `code` and ~~strike~~
        """#

        let items = MarkdownOutlineParser().parse(markdown)

        XCTAssertEqual(items.map(\.title), [
            "Bold nested",
            "A bold label Alt image",
            "code and strike"
        ])
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
