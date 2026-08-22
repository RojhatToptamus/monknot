import Foundation
import XCTest
@testable import MonknotCore

final class FlowPlainTextAndCancellationTests: FlowProtectedRangeTestCase {
    func testMarkdownProtectsRawAndAutolinkURLs() {
        let markdown = "Visit https://example.com/docs and <https://example.org/a?q=1>."

        XCTAssertEqual(
            protectedSubstrings(in: markdown),
            ["https://example.com/docs", "<https://example.org/a?q=1>"]
        )
    }

    func testProtectsIncompleteURLLikeFormsWhileTyping() {
        let text = "https:// www.exa mailto:user@ user@example"
        let source = text as NSString

        for mode in [FlowSourceMode.markdown, .plainText] {
            let ranges = service.protectedRanges(in: text, mode: mode)
            for token in ["https://", "www.exa", "mailto:user@", "user@example"] {
                let tokenRange = source.range(of: token)
                XCTAssertTrue(ranges.contains {
                    NSIntersectionRange($0, tokenRange).length == tokenRange.length
                }, "Expected \(token) to be protected in \(mode)")
            }
        }
    }

    func testProtectsIncompleteCustomSchemeURLsWithoutSwallowingFollowingProse() {
        let text = "Open monknot:// obsidian:// ssh:// file:// then ordinary prose remains editable."
        let source = text as NSString

        for mode in [FlowSourceMode.markdown, .plainText] {
            let ranges = service.protectedRanges(in: text, mode: mode)
            for token in ["monknot://", "obsidian://", "ssh://", "file://"] {
                let tokenRange = source.range(of: token)
                XCTAssertTrue(ranges.contains {
                    NSIntersectionRange($0, tokenRange).length == tokenRange.length
                }, "Expected \(token) to be protected in \(mode)")
            }
            let prose = source.range(of: "then ordinary prose remains editable.")
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, prose).length > 0
            })
        }
    }

    func testPlainTextProtectsURLsButNotMarkdownSyntax() {
        let text = "`code` [guide](Guide.md) <em>tag</em> https://example.com/path"

        XCTAssertEqual(
            protectedSubstrings(in: text, mode: .plainText),
            ["https://example.com/path"]
        )
    }

    func testEnclosingRangeReturnsClippedDocumentRelativeIntersections() throws {
        let markdown = "Before `protected` after"
        let protectedRange = (markdown as NSString).range(of: "`protected`")
        let enclosingRange = NSRange(location: protectedRange.location + 2, length: protectedRange.length)

        let intersection = try XCTUnwrap(
            service.protectedRanges(
                in: markdown,
                mode: .markdown,
                intersecting: enclosingRange
            ).first
        )

        XCTAssertEqual(intersection.location, enclosingRange.location)
        XCTAssertEqual(intersection.length, protectedRange.length - 2)
        XCTAssertEqual((markdown as NSString).substring(with: intersection), "rotected`")
    }

    func testOverlappingAndAdjacentRangesAreMerged() {
        let markdown = "<https://example.com><!--comment--><strong>"

        XCTAssertEqual(
            service.protectedRanges(in: markdown, mode: .markdown),
            [NSRange(location: 0, length: (markdown as NSString).length)]
        )
    }

    func testRangesUseUTF16Coordinates() throws {
        let markdown = "😀 text [note](docs/📘.md) and `café`"
        let source = markdown as NSString
        let destination = source.range(of: "docs/📘.md")
        let code = source.range(of: "`café`")
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, destination).length == destination.length
        })
        XCTAssertTrue(ranges.contains(code))
        XCTAssertEqual(destination.location, 15)
        XCTAssertEqual(destination.length, 10)
        XCTAssertEqual(source.substring(with: destination), "docs/📘.md")
    }

    func testCancellationDoesNotWaitForOneWholeDocumentURLMatch() async {
        let source = String(repeating: "https://example.com/path?x=1 ", count: 100_000)
        let workStarted = expectation(description: "protected-range task entered service call")
        let task = Task.detached(priority: .utility) {
            workStarted.fulfill()
            _ = FlowProtectedRangeService().protectedRanges(in: source, mode: .plainText)
        }

        await fulfillment(of: [workStarted], timeout: 1)
        let cancellationStarted = Date()
        task.cancel()
        _ = await task.value

        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStarted),
            1.0,
            "URL detection should observe cancellation between bounded match calls."
        )
    }

    func testBoundedURLDetectionDoesNotSplitTokensAtChunkEdges() {
        let padding = String(repeating: "word ", count: 3_300)
        let url = "https://example.com/path"
        let text = padding + url
        let urlRange = (text as NSString).range(of: url)

        XCTAssertTrue(service.protectedRanges(in: text, mode: .plainText).contains {
            NSIntersectionRange($0, urlRange).length == urlRange.length
        })
    }

    func testOversizedURLTokenIsProtectedWithoutOneUnboundedDetectorCall() {
        let text = "monknot://" + String(repeating: "segment", count: 3_000)

        XCTAssertEqual(
            service.protectedRanges(in: text, mode: .plainText),
            [NSRange(location: 0, length: (text as NSString).length)]
        )
    }
}
