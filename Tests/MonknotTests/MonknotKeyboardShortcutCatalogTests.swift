import XCTest
import MonknotCore

final class MonknotKeyboardShortcutCatalogTests: XCTestCase {
    func testQuickOpenShortcutIsListed() {
        let entry = MonknotKeyboardShortcutCatalog.entries.first { $0.title == "Quick Open" }
        XCTAssertEqual(entry?.shortcut, "⌘P")
    }

    func testExplicitRenderedClipboardActionIsListed() {
        XCTAssertEqual(
            MonknotKeyboardShortcutCatalog.entries.first {
                $0.title == "Copy Rendered Markdown"
            }?.shortcut,
            "⌥⌘C"
        )
        XCTAssertFalse(MonknotKeyboardShortcutCatalog.entries.contains {
            $0.title == "Paste Selection into Terminal"
        })
    }

    func testHelpDoesNotAdvertiseAQuestionMarkShortcut() {
        XCTAssertFalse(MonknotKeyboardShortcutCatalog.entries.contains {
            $0.shortcut == "?" || $0.title == "Keyboard Shortcuts Help"
        })
    }

    func testLinkInspectionShortcutIsListed() {
        XCTAssertEqual(
            MonknotKeyboardShortcutCatalog.entries.first { $0.title == "Inspect Links" }?.shortcut,
            "⌥⌘L"
        )
    }
}
