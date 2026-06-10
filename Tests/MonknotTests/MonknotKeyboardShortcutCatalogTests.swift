import XCTest
import MonknotCore

final class MonknotKeyboardShortcutCatalogTests: XCTestCase {
    func testQuickOpenShortcutIsListed() {
        let entry = MonknotKeyboardShortcutCatalog.entries.first { $0.title == "Quick Open" }
        XCTAssertEqual(entry?.shortcut, "⌘P")
    }
}
