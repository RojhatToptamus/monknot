import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownPresentationTokenTests: XCTestCase {
    /// Every SF Symbol the Preview editor's menus, bars and handles ask for is drawn for the page, in
    /// the size context it is asked in, and exists on this system (a missing name would render as a
    /// question mark).
    func testEveryGlyphThePreviewEditorRequestsIsDrawn() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/MonknotCore/Resources/editor.js"),
            encoding: .utf8
        )
        var requested = Set<String>()
        let itemIcon = try NSRegularExpression(pattern: #"icon: "([^"]+)""#)
        let callIcon = try NSRegularExpression(pattern: #"icon\("([^"]+)"(?:, "(\w+)")?\)"#)
        let range = NSRange(script.startIndex..., in: script)
        for match in itemIcon.matches(in: script, range: range) {
            requested.insert("menu:" + String(script[Range(match.range(at: 1), in: script)!]))
        }
        for match in callIcon.matches(in: script, range: range) {
            let name = String(script[Range(match.range(at: 1), in: script)!])
            let context = Range(match.range(at: 2), in: script).map { String(script[$0]) } ?? "menu"
            requested.insert("\(context):\(name)")
        }
        XCTAssertGreaterThan(requested.count, 40, "The scan found the page's glyph requests")

        let drawn = MarkdownEditorSymbolAssets.icons()
        for key in requested.sorted() {
            XCTAssertNotNil(drawn[key], "\(key) is requested by the page but not drawn")
            let name = String(key.split(separator: ":", maxSplits: 1)[1])
            // Remove Link draws `xmark` where the system has no `link.badge.minus`.
            guard name != "link.badge.minus" else { continue }
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) is not an SF Symbol here")
        }
    }

    func testOutlineRailTracksTheVisibleHeadingAndClampsNestedIndentation() {
        let items = [
            MarkdownOutlineItem(
                id: "a", title: "A", level: 1, location: .init(line: 1, offset: 0)
            ),
            MarkdownOutlineItem(
                id: "b", title: "B", level: 2, location: .init(line: 3, offset: 8)
            ),
        ]

        XCTAssertEqual(
            MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 1, items: items),
            0
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 10, items: items),
            1
        )
        XCTAssertNil(MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 1, items: []))
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 1), 0)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 3), 14)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 8), 35)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 1), 24)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 3), 16)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 8), 8)
        XCTAssertNil(
            MarkdownOutlineRailLayout.revealAnchor,
            "Outline reveals should scroll only enough to make the heading visible"
        )
        XCTAssertNotNil(MonknotMotion.outlineAnimation(reduceMotion: false))
        XCTAssertNil(MonknotMotion.outlineAnimation(reduceMotion: true))
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: "hovered",
                focusedItemID: "focused",
                activeItemID: "active"
            ),
            "hovered"
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: nil,
                focusedItemID: "focused",
                activeItemID: "active"
            ),
            "focused"
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: nil,
                focusedItemID: nil,
                activeItemID: "active"
            ),
            "active"
        )
    }

    func testMarkdownSyntaxTokenizerCoversEveryReferenceAccent() {
        let markdown = "# Heading\n> Quote\n**Strong** [[Wiki]] [Link](https://example.com) `code`"
        let styles = MarkdownSyntaxTokenizer.tokens(in: markdown).map(\.style)

        for expectedStyle in [
            MarkdownSyntaxStyle.heading,
            .strong,
            .wikilink,
            .link,
            .code,
            .marker,
        ] {
            XCTAssertTrue(styles.contains(expectedStyle))
        }
    }

    func testMarkdownSyntaxMarkersCoverOnlyTheBlockSyntax() {
        let markdown = """
        ## Heading
        > > Nested quote
        - item
          12. numbered
        * [x] done
        **not a list** and #not-a-heading
        ---
        """
        let source = markdown as NSString
        let markers = MarkdownSyntaxTokenizer.tokens(in: markdown)
            .filter { $0.style == .marker }
            .map { source.substring(with: $0.range) }

        XCTAssertEqual(markers, ["##", "> > ", "-", "12.", "* [x]"])
    }

    func testMarkdownInlineSyntaxNeverSpansACarriageReturn() {
        // `paragraphRange` splits at a lone CR, so a token crossing one would differ between a
        // line-local restyle and a full pass.
        for markdown in ["**a\rb**", "[[a\rb]]", "[a\rb](x.md)", "[a](x\r.md)", "`a\rb`"] {
            XCTAssertTrue(MarkdownSyntaxTokenizer.tokens(in: markdown).isEmpty, markdown.debugDescription)
        }
    }

    func testMarkdownEditorLineHeightTracksHighZoomFontSize() {
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 13), 22)
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 39), 57)
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 120), 174)
        XCTAssertGreaterThan(
            MarkdownEditorLayout.lineHeight(forFontSize: 39),
            39,
            "High-zoom Markdown lines must not overlap"
        )
    }
}
