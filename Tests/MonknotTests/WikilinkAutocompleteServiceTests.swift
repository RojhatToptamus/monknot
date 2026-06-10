import XCTest
@testable import MonknotCore

final class WikilinkAutocompleteServiceTests: XCTestCase {
    func testDetectsActiveWikilinkPrefix() {
        let text = "See [[Daily No"
        let context = WikilinkAutocompleteService.activeCompletion(in: text, cursorUTF16Offset: (text as NSString).length)

        XCTAssertEqual(context?.partialText, "Daily No")
        XCTAssertEqual(context?.replaceRangeLocation, 6)
        XCTAssertEqual(context?.replaceRangeLength, 8)
    }

    func testSuggestsMarkdownTitles() {
        let root = URL(fileURLWithPath: "/tmp/ws", isDirectory: true)
        let documents = [
            WorkspaceDocument(url: root.appendingPathComponent("inbox/Daily Note.md"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root),
        ]

        let suggestions = WikilinkAutocompleteService.suggestions(partial: "daily", documents: documents)
        XCTAssertEqual(suggestions, ["Daily Note"])
    }

    func testSuggestionsReturnMultipleMatchesInRankOrder() {
        let root = URL(fileURLWithPath: "/tmp/ws", isDirectory: true)
        let documents = [
            WorkspaceDocument(url: root.appendingPathComponent("alpha.md"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("alphabet.md"), rootURL: root),
        ]

        let suggestions = WikilinkAutocompleteService.suggestions(partial: "alp", documents: documents)
        XCTAssertEqual(suggestions, ["alpha", "alphabet"])
    }
}
