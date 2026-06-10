import XCTest
@testable import MonknotCore

final class MarkdownSymbolQuickOpenMatcherTests: XCTestCase {
    func testRanksHeadingTitlesByQuery() {
        let items = [
            MarkdownOutlineItem(id: "1", title: "Introduction", level: 1, location: .init(line: 1, offset: 0)),
            MarkdownOutlineItem(id: "2", title: "Daily Notes", level: 2, location: .init(line: 5, offset: 0)),
            MarkdownOutlineItem(id: "3", title: "Setup", level: 2, location: .init(line: 10, offset: 0)),
        ]

        let matches = MarkdownSymbolQuickOpenMatcher.rankedItems(query: "daily", items: items)
        XCTAssertEqual(matches.map(\.title), ["Daily Notes"])
    }
}
