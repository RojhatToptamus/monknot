import AppKit
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownSemanticPasteboardExportServiceTests: XCTestCase {
    func testPasteboardItemContainsPlainMarkdownHTMLAndRTF() throws {
        let markdown = "**Bold** and [link](https://example.com)"

        let item = try XCTUnwrap(MarkdownSemanticPasteboardExportService.pasteboardItem(for: markdown))
        XCTAssertEqual(item.string(forType: .string), "Bold and link")
        XCTAssertNotNil(item.data(forType: .html))
        XCTAssertNotNil(item.data(forType: .rtf))

        let htmlData = try XCTUnwrap(item.data(forType: .html))
        let html = try XCTUnwrap(String(data: htmlData, encoding: .utf8))
        XCTAssertTrue(html.localizedCaseInsensitiveContains("bold"))
        XCTAssertTrue(html.contains("https://example.com"))
    }

    func testEmptySelectionDoesNotCreatePasteboardRepresentations() throws {
        XCTAssertNil(try MarkdownSemanticPasteboardExportService.representations(for: ""))
        XCTAssertNil(try MarkdownSemanticPasteboardExportService.pasteboardItem(for: ""))
    }

    func testRawHTMLIsNotEmittedAsExecutableMarkup() throws {
        let representations = try XCTUnwrap(
            MarkdownSemanticPasteboardExportService.representations(
                for: "Before <script>alert('no')</script> after"
            )
        )
        let html = try XCTUnwrap(String(data: representations.html, encoding: .utf8))

        XCTAssertFalse(html.localizedCaseInsensitiveContains("<script"))
        XCTAssertTrue(html.localizedCaseInsensitiveContains("before"))
        XCTAssertTrue(html.localizedCaseInsensitiveContains("after"))
    }

    func testTextViewExposesOnlyItsCurrentSelectionForRenderedCopy() throws {
        let textView = MarkdownNSTextView()
        textView.string = "prefix **Bold** suffix"
        textView.setSelectedRange((textView.string as NSString).range(of: "**Bold**"))

        XCTAssertEqual(textView.selectedMarkdownForRenderedCopy(), "**Bold**")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(textView.selectedMarkdownForRenderedCopy())
    }
}
