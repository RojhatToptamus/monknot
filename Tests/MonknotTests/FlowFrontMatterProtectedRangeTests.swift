import Foundation
import XCTest
@testable import MonknotCore

final class FlowFrontMatterProtectedRangeTests: FlowProtectedRangeTestCase {
    func testMarkdownProtectsYAMLFrontMatterOnlyAtDocumentStart() {
        let markdown = """
        ---
        title: Draft
        tags: [flow]
        ---
        Editable prose.

        ---
        Not front matter.
        ---
        """

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["---\ntitle: Draft\ntags: [flow]\n---\n", "---", "---"]
        )
    }

    func testMarkdownProtectsUnterminatedFrontMatter() {
        let markdown = """
        ---
        title: Draft
        unfinished metadata
        """

        XCTAssertEqual(protectedSubstrings(in: markdown), [markdown])
    }

    func testMarkdownUsesFrontMatterBodyEvidenceOnlyForAnUnclosedOpener() {
        let unclosed = """
        ---
        Ordinary prose continues.
        More prose.
        """
        let unclosedSource = unclosed as NSString
        let unclosedRanges = service.protectedRanges(in: unclosed, mode: .markdown)

        XCTAssertEqual(protectedSubstrings(in: unclosed), ["---"])
        XCTAssertFalse(unclosedRanges.contains {
            NSIntersectionRange($0, unclosedSource.range(of: "Ordinary prose continues.")).length > 0
        })

        let closed = """
        ---
        Ordinary root scalar
        ---
        Editable after front matter.
        """
        let closedSource = closed as NSString
        let closedRanges = service.protectedRanges(in: closed, mode: .markdown)
        let frontMatter = closedSource.range(of: "---\nOrdinary root scalar\n---\n")
        XCTAssertTrue(closedRanges.contains {
            NSIntersectionRange($0, frontMatter).length == frontMatter.length
        })
        XCTAssertFalse(closedRanges.contains {
            NSIntersectionRange($0, closedSource.range(of: "Editable after front matter.")).length > 0
        })
    }

    func testMarkdownProtectsClosedYAMLRootListFrontMatter() {
        let markdown = """
        ---
        - first
        - second
        ...
        Editable prose.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)
        let frontMatter = source.range(of: "---\n- first\n- second\n...\n")

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, frontMatter).length == frontMatter.length
        })
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, source.range(of: "Editable prose.")).length > 0
        })
    }

    func testMarkdownProtectsTOMLFrontMatter() {
        let markdown = """
        +++
        title = "Draft"
        [flow]
        enabled = true
        +++
        Editable prose.
        """

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["+++\ntitle = \"Draft\"\n[flow]\nenabled = true\n+++\n"]
        )
    }

    func testMarkdownHTMLScannerIgnoresTokensInsideIndentedCodeAndFrontMatter() {
        for markdown in [
            "    <pre>\nEditable after indented code.",
            "---\ntitle: \"<pre>\"\n---\nEditable after front matter.",
        ] {
            let source = markdown as NSString
            let prose = source.range(of: "Editable")
            XCTAssertFalse(service.protectedRanges(in: markdown, mode: .markdown).contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }
}
