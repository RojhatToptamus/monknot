import XCTest
@testable import MonknotApp

final class DocumentNavigationHistoryTests: XCTestCase {
    func testBackForwardAndNewSelectionFollowBrowserHistorySemantics() {
        var history = DocumentNavigationHistory()

        history.recordSelection("/A.md")
        history.recordSelection("/B.md")
        history.recordSelection("/C.md")

        XCTAssertEqual(history.goBack(), "/B.md")
        XCTAssertEqual(history.goBack(), "/A.md")
        XCTAssertEqual(history.goForward(), "/B.md")
        XCTAssertEqual(history.forwardDocumentID, "/C.md")

        history.recordSelection("/D.md")

        XCTAssertEqual(history.currentDocumentID, "/D.md")
        XCTAssertEqual(history.backDocumentID, "/B.md")
        XCTAssertFalse(history.canGoForward)
    }

    func testHistoryPrunesRemovedDocumentsAndRemapsRenames() {
        var history = DocumentNavigationHistory()
        history.recordSelection("/A.md")
        history.recordSelection("/B.md")
        history.recordSelection("/C.md")
        _ = history.goBack()

        history.remapDocumentID(from: "/A.md", to: "/Renamed.md")
        history.prune(availableDocumentIDs: Set(["/Renamed.md", "/B.md"]))

        XCTAssertEqual(history.currentDocumentID, "/B.md")
        XCTAssertEqual(history.backDocumentID, "/Renamed.md")
        XCTAssertFalse(history.canGoForward)
    }

    func testHistoryBoundsAccumulatedNavigation() {
        var history = DocumentNavigationHistory()

        for index in 0...(DocumentNavigationHistory.maximumStackDepth + 20) {
            history.recordSelection("/\(index).md")
        }

        XCTAssertEqual(history.backStack.count, DocumentNavigationHistory.maximumStackDepth)
        XCTAssertEqual(history.backStack.first, "/20.md")
    }
}
