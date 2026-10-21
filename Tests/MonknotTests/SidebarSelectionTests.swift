import MonknotCore
import XCTest

final class SidebarSelectionTests: XCTestCase {
    private let rows = ["a", "b", "c", "d", "e"]

    func testShiftClickSelectsTheRowsFromTheAnchorAndKeepsTheAnchor() {
        let selection = SidebarSelection(single: "b").extending(to: "d", rows: rows)
        XCTAssertEqual(selection.itemIDs, ["b", "c", "d"])
        XCTAssertEqual(selection.anchorID, "b")
        XCTAssertEqual(selection.leadID, "d")

        // A second ⇧-click from the same anchor replaces the range, upwards too.
        let upwards = selection.extending(to: "a", rows: rows)
        XCTAssertEqual(upwards.itemIDs, ["a", "b"])
        XCTAssertEqual(upwards.anchorID, "b")
        XCTAssertEqual(upwards.leadID, "a")
    }

    func testShiftClickFromAHiddenAnchorStartsAtTheLeadOrAlone() {
        var selection = SidebarSelection(single: "hidden")
        XCTAssertEqual(selection.extending(to: "c", rows: rows).itemIDs, ["c"])

        selection = SidebarSelection(single: "hidden").toggling("b")
        // "b" is now the anchor and lead.
        XCTAssertEqual(selection.extending(to: "d", rows: rows).itemIDs, ["b", "c", "d"])
        XCTAssertEqual(SidebarSelection().extending(to: "c", rows: rows).itemIDs, ["c"])
    }

    func testCommandClickAddsAndRemovesItems() {
        var selection = SidebarSelection(single: "a").toggling("c")
        XCTAssertEqual(selection.itemIDs, ["a", "c"])
        XCTAssertEqual(selection.anchorID, "c")
        XCTAssertEqual(selection.leadID, "c")

        selection = selection.toggling("c")
        XCTAssertEqual(selection.itemIDs, ["a"])
        XCTAssertEqual(selection.leadID, "a", "Taking out the lead leaves the last one picked")
        XCTAssertEqual(selection.anchorID, "a")

        XCTAssertTrue(selection.toggling("a").isEmpty)
        XCTAssertNil(selection.toggling("a").leadID)
    }

    func testArrowKeysMoveFromTheLeadAndShiftExtendsFromTheAnchor() throws {
        var selection = try XCTUnwrap(SidebarSelection(single: "b").moving(by: 1, rows: rows, extending: false))
        XCTAssertEqual(selection.itemIDs, ["c"])

        selection = try XCTUnwrap(selection.moving(by: 1, rows: rows, extending: true))
        selection = try XCTUnwrap(selection.moving(by: 1, rows: rows, extending: true))
        XCTAssertEqual(selection.itemIDs, ["c", "d", "e"])
        XCTAssertEqual(selection.leadID, "e")

        // Back up past the anchor: the range turns round it.
        for _ in 0..<3 {
            selection = try XCTUnwrap(selection.moving(by: -1, rows: rows, extending: true))
        }
        XCTAssertEqual(selection.itemIDs, ["b", "c"])
        XCTAssertEqual(selection.anchorID, "c")

        // The ends hold.
        XCTAssertEqual(SidebarSelection(single: "e").moving(by: 1, rows: rows, extending: false)?.itemIDs, ["e"])
        XCTAssertEqual(SidebarSelection(single: "a").moving(by: -1, rows: rows, extending: false)?.itemIDs, ["a"])
    }

    func testHomeAndEndAndMovingFromNothing() {
        XCTAssertEqual(SidebarSelection(single: "c").moving(by: Int.min, rows: rows, extending: false)?.itemIDs, ["a"])
        XCTAssertEqual(SidebarSelection(single: "c").moving(by: Int.max, rows: rows, extending: true)?.itemIDs, ["c", "d", "e"])
        XCTAssertEqual(SidebarSelection().moving(by: 1, rows: rows, extending: false)?.itemIDs, ["a"])
        XCTAssertEqual(SidebarSelection().moving(by: -1, rows: rows, extending: false)?.itemIDs, ["e"])
        // Home and End from nothing go to the first and last rows, not the other way round.
        XCTAssertEqual(SidebarSelection().moving(by: Int.min, rows: rows, extending: false)?.itemIDs, ["a"])
        XCTAssertEqual(SidebarSelection().moving(by: Int.max, rows: rows, extending: false)?.itemIDs, ["e"])
        XCTAssertEqual(SidebarSelection(single: "gone").moving(by: Int.min, rows: rows, extending: true)?.itemIDs, ["a"])
        XCTAssertEqual(SidebarSelection(single: "gone").moving(by: 1, rows: rows, extending: false)?.itemIDs, ["a"])
        XCTAssertNil(SidebarSelection(single: "a").moving(by: 1, rows: [], extending: false))
    }

    func testSelectAllKeepsTheLead() {
        let selection = SidebarSelection.all(rows, leadID: "c")
        XCTAssertEqual(selection.itemIDs, rows)
        XCTAssertEqual(selection.leadID, "c")
        XCTAssertEqual(SidebarSelection.all(rows, leadID: "gone").leadID, "e")
    }

    func testFilteringAndMappingFollowTheItems() {
        let selection = SidebarSelection(single: "/w/a").toggling("/w/b").toggling("/w/c")
        let moved = selection.mapped { $0.replacingOccurrences(of: "/w/", with: "/w/x/") }
        XCTAssertEqual(moved.itemIDs, ["/w/x/a", "/w/x/b", "/w/x/c"])
        XCTAssertEqual(moved.leadID, "/w/x/c")

        let filtered = selection.filtered { $0 != "/w/c" }
        XCTAssertEqual(filtered.itemIDs, ["/w/a", "/w/b"])
        XCTAssertEqual(filtered.leadID, "/w/b", "A lead that is gone gives way to the last item")
        XCTAssertEqual(filtered.anchorID, "/w/a")
    }

    func testTypeSelectFindsTheNextRowByItsName() {
        var typeSelect = SidebarTypeSelect()
        let names = ["Alpha.md", "beta.md", "Bravo", "Écrit.md", "notes"]
        XCTAssertEqual(typeSelect.type("b", at: 0, rows: rows, names: names, leadID: nil), "b")
        XCTAssertEqual(typeSelect.type("r", at: 0.3, rows: rows, names: names, leadID: "b"), "c", "The prefix grows within a second")
        // After a pause a new prefix starts from the row after the lead, wrapping round.
        XCTAssertEqual(typeSelect.type("b", at: 2, rows: rows, names: names, leadID: "c"), "b")
        XCTAssertEqual(typeSelect.type("e", at: 4, rows: rows, names: names, leadID: "a"), "d", "Accents are ignored")
        XCTAssertNil(typeSelect.type("z", at: 6, rows: rows, names: names, leadID: "a"))
    }
}
