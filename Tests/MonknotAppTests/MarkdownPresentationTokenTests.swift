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
    /// question mark); and every glyph drawn for the page is one it asks for.
    func testEveryGlyphThePreviewEditorRequestsIsDrawnAndNothingElse() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/MonknotCore/Resources/editor.js"),
            encoding: .utf8
        )
        let requested = try Self.glyphRequests(in: script)
        for key in ["menu:magnifyingglass", "small:checkmark", "small:chevron.down", "tool:bold", "tool:link.badge.minus", "menu:doc"] {
            XCTAssertTrue(requested.contains(key), "The scan finds \(key), requested as the page asks for it")
        }

        let drawn = MarkdownEditorSymbolAssets.icons()
        for key in requested.sorted() {
            XCTAssertNotNil(drawn[key], "\(key) is requested by the page but not drawn")
        }
        for key in Set(drawn.keys).subtracting(requested).sorted() {
            XCTFail("\(key) is drawn for the page but nothing asks for it")
        }
        for key in drawn.keys.sorted() {
            let name = String(key.split(separator: ":", maxSplits: 1)[1])
            // Remove Link draws `xmark` where the system has no `link.badge.minus`.
            guard name != "link.badge.minus" else { continue }
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) is not an SF Symbol here")
        }
    }

    /// The `context:name` keys editor.js asks for, in every form it asks: a menu item's
    /// `icon: "…"`, `icon("…"[, "context"])`, a toolbar `button("…", …)` (a 17 pt tool glyph), a
    /// link editor mode's `glyph: "…"`, and a key written out (`"small:chevron.down"`).
    static func glyphRequests(in script: String) throws -> Set<String> {
        let forms: [(pattern: String, context: String?)] = [
            (#"\bicon: "([^"]+)""#, "menu"),
            (#"\bglyph: "([^"]+)""#, "menu"),
            (#"\bicon\("([^"]+)"(?:, "(\w+)")?\)"#, nil),
            (#"\bbutton\("([^"]+)""#, "tool"),
            (#""((?:menu|tool|small):[^"]+)""#, ""),
        ]
        var requested = Set<String>()
        let range = NSRange(script.startIndex..., in: script)
        for form in forms {
            let expression = try NSRegularExpression(pattern: form.pattern)
            for match in expression.matches(in: script, range: range) {
                let name = String(script[Range(match.range(at: 1), in: script)!])
                switch form.context {
                case .some(""):
                    requested.insert(name)
                case .some(let context):
                    requested.insert("\(context):\(name)")
                case .none:
                    let context = Range(match.range(at: 2), in: script).map { String(script[$0]) } ?? "menu"
                    requested.insert("\(context):\(name)")
                }
            }
        }
        return requested
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
        // Depth counts from the document's shallowest heading and stops at three.
        XCTAssertEqual(MarkdownOutlineRailLayout.depth(forHeadingLevel: 1, shallowestLevel: 1), 0)
        XCTAssertEqual(MarkdownOutlineRailLayout.depth(forHeadingLevel: 2, shallowestLevel: 2), 0)
        XCTAssertEqual(MarkdownOutlineRailLayout.depth(forHeadingLevel: 3, shallowestLevel: 1), 2)
        XCTAssertEqual(MarkdownOutlineRailLayout.depth(forHeadingLevel: 8, shallowestLevel: 1), 3)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndentBase(forDepth: 0), 0)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndentBase(forDepth: 2), 28)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndentBase(forDepth: 9), 42)
        XCTAssertEqual(MarkdownOutlineRailLayout.markLengthBase(forDepth: 0), 16)
        XCTAssertEqual(MarkdownOutlineRailLayout.markLengthBase(forDepth: 2), 9)
        XCTAssertEqual(MarkdownOutlineRailLayout.markLengthBase(forDepth: 7), 6)
        XCTAssertEqual(
            MarkdownOutlineRailLayout.scrollOffset(
                revealing: 400...430,
                from: 0,
                viewportHeight: 380,
                contentHeight: 1_000,
                margin: 6,
                centred: false
            ),
            56,
            "Outline reveals should scroll only enough to make the heading visible"
        )
        XCTAssertNotNil(MonknotMotion.stateMotion(reduceMotion: false))
        XCTAssertNil(MonknotMotion.stateMotion(reduceMotion: true))
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
