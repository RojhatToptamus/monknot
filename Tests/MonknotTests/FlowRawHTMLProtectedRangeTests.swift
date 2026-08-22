import Foundation
import XCTest
@testable import MonknotCore

final class FlowRawHTMLProtectedRangeTests: FlowProtectedRangeTestCase {
    func testMarkdownProtectsIndentedAndHTMLCodeContents() {
        let markdown = """
        Prose

            let teh = value
        <pre>teh <strong>code</strong></pre>
        <code>inline teh</code>
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for code in ["let teh = value", "teh <strong>code</strong>", "inline teh"] {
            let codeRange = source.range(of: code)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, codeRange).length == codeRange.length
            }, "Expected \(code) to be protected")
        }
    }

    func testMarkdownProtectsHTMLTagsAndComments() {
        let markdown = "<section data-label=\">\">Editable</section> and <!-- protected\ncomment --> prose."

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["<section data-label=\">\">", "</section>", "<!-- protected\ncomment -->"]
        )
    }

    func testMarkdownCodeBlocksRequireAnExactHTMLClosingTagName() {
        let markdown = "<code>first </codeblock> still code</code> editable prose"
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let code = source.range(of: "<code>first </codeblock> still code</code>")
        let prose = source.range(of: "editable prose")

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, code).length == code.length
        })
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, prose).length > 0
        })
    }

    func testMarkdownCodeBlocksRequireAnExactHTMLOpeningTagName() {
        let markdown = "<code-example>editable</code-example> <code>protected</code>"
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let editable = source.range(of: "editable")
        let code = source.range(of: "<code>protected</code>")

        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, editable).length > 0
        })
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, code).length == code.length
        })
    }

    func testMarkdownProtectsScriptAndStyleBodiesWithExactCaseInsensitiveTagNames() {
        let markdown = """
        <SCRIPT type="module">const teh = "</script-example>";</sCrIpT>
        Editable after script.
        <style>.teh { color: red; }</STYLE>
        Editable after style.
        <script-example>editable custom-element body</script-example>
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for body in ["const teh = \"</script-example>\";", ".teh { color: red; }"] {
            let bodyRange = source.range(of: body)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, bodyRange).length == bodyRange.length
            }, "Expected raw HTML body \(body) to be protected")
        }
        for prose in [
            "Editable after script.",
            "Editable after style.",
            "editable custom-element body",
        ] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsUnclosedScriptAndStyleBlocksConservatively() {
        for markdown in [
            "Before <script>const teh = 1",
            "Before <style>.teh { color: red; }",
        ] {
            let source = markdown as NSString
            let opening = source.range(of: "<")
            let protectedTail = NSRange(location: opening.location, length: source.length - opening.location)
            XCTAssertTrue(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, protectedTail).length == protectedTail.length
            })
        }
    }

    func testMarkdownHTMLScannerIgnoresTokensInsideMarkdownCode() {
        let markdown = """
        Inline `<pre>` example and `<!--` example. Editable after inline examples.

        ```html
        <pre>
        <!--
        ```
        Editable after fenced examples.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for prose in ["Editable after inline examples.", "Editable after fenced examples."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownHTMLScannerDoesNotReparseNestedTokensInCommentsOrRawBlocks() {
        for markdown in [
            "<!-- mention <pre> -->\nEditable after comment.",
            "<script>const s = \"<pre>\"; const c = \"<!--\";</script>\nEditable after script.",
        ] {
            let source = markdown as NSString
            let prose = source.range(of: "Editable")
            XCTAssertFalse(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }
}
