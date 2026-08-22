import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownPresentationTokenTests: XCTestCase {
    func testWideMarkdownToolbarPreservesCompleteFormattingActionOrder() {
        XCTAssertEqual(
            MarkdownSourceToolbar.regularActionGroups.map { $0.map(\.label) },
            [
                ["Bold", "Italic", "Quote", "Inline Code", "Link"],
                ["Bullet List", "Numbered List", "Task List"],
                ["Image", "Horizontal Rule"],
            ]
        )
    }

    func testMarkdownToolbarUsesMeasuredOpticalSymbolSizes() {
        let expectedPointSizes: [String: CGFloat] = [
            "bold": 17,
            "italic": 17,
            "quote.opening": 17,
            "curlybraces": 13,
            "link": 13,
            "list.bullet": 17,
            "list.number": 17,
            "checklist": 14,
            "photo": 14,
            "minus": 17,
        ]

        XCTAssertEqual(MonknotIconButton.IconButtonSize.editorToolbar.iconPointSizeBase, 17)
        XCTAssertEqual(
            Set(MarkdownSourceToolbar.regularActionGroups.flatMap { $0.map(\.systemImage) }),
            Set(expectedPointSizes.keys)
        )

        for (systemImage, expectedPointSize) in expectedPointSizes {
            XCTAssertEqual(
                MonknotSymbolOptics.pointSizeBase(
                    for: systemImage,
                    nominal: MonknotIconButton.IconButtonSize.editorToolbar.iconPointSizeBase
                ),
                expectedPointSize,
                "\(systemImage) escaped the measured Markdown-toolbar profile"
            )
        }
    }

    func testMarkdownHeadingMenuSharesTheFormattingControlGeometry() {
        let size = MarkdownSourceToolbar.controlSize

        XCTAssertEqual(size.iconPointSizeBase, 17)
        XCTAssertEqual(MarkdownSourceToolbar.expandedHeadingWidthBase, 100)
        XCTAssertEqual(MarkdownSourceToolbar.compactHeadingWidthBase, 104)
        XCTAssertEqual(MarkdownSourceToolbar.headingFontSizeBase, 13)
        XCTAssertEqual(MarkdownSourceToolbar.headingChevronFontSizeBase, 10)
        XCTAssertEqual(MarkdownSourceToolbar.headingChevronBaselineOffsetBase, 3.2)

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    size.height(theme: theme, zoomScale: zoomScale),
                    "Paragraph and formatting controls must share one height"
                )
                XCTAssertEqual(
                    size.cornerRadius(theme: theme, zoomScale: zoomScale),
                    theme.chromeRadius(8, zoomScale: zoomScale),
                    "Paragraph and formatting controls must share one corner radius"
                )
            }
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
            .quote,
            .strong,
            .wikilink,
            .link,
            .code,
        ] {
            XCTAssertTrue(styles.contains(expectedStyle))
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
