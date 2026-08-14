import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownListEditPlannerTests: XCTestCase {
    func testReturnContinuesBulletsAndPreservesNestedIndentation() throws {
        let source = "- parent\n  * 😀 child"
        let plan = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .newline,
            in: source,
            selectedRange: NSRange(location: (source as NSString).length, length: 0)
        ))

        XCTAssertEqual(apply(plan, to: source), "- parent\n  * 😀 child\n  * ")
        XCTAssertEqual(plan.selectedRange, NSRange(location: (source as NSString).length + 5, length: 0))
    }

    func testReturnContinuesNumberedAndTaskListsWithExistingLineEndings() throws {
        let numbered = "1) first\r\n9) ninth"
        let numberedPlan = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .newline,
            in: numbered,
            selectedRange: NSRange(location: (numbered as NSString).length, length: 0)
        ))
        XCTAssertEqual(apply(numberedPlan, to: numbered), "1) first\r\n9) ninth\r\n10) ")

        let task = "- [x] shipped"
        let taskPlan = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .newline,
            in: task,
            selectedRange: NSRange(location: (task as NSString).length, length: 0)
        ))
        XCTAssertEqual(apply(taskPlan, to: task), "- [x] shipped\n- [ ] ")
    }

    func testReturnEndsAnEmptyListMarker() throws {
        for marker in ["- ", "12. ", "* [ ] ", "+ [x]"] {
            let source = "item\n\(marker)"
            let plan = try XCTUnwrap(MarkdownListEditPlanner.plan(
                .newline,
                in: source,
                selectedRange: NSRange(location: (source as NSString).length, length: 0)
            ))
            XCTAssertEqual(apply(plan, to: source), "item\n")
            XCTAssertEqual(plan.selectedRange, NSRange(location: 5, length: 0))
        }
    }

    func testTabAndShiftTabIndentSelectedNestedItems() throws {
        let source = "- parent\n  - child\n- peer"
        let selectedLength = ("- parent\n  - child" as NSString).length
        let indented = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .indent,
            in: source,
            selectedRange: NSRange(location: 0, length: selectedLength)
        ))
        XCTAssertEqual(apply(indented, to: source), "  - parent\n    - child\n- peer")

        let nested = "    - child"
        let outdented = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .outdent,
            in: nested,
            selectedRange: NSRange(location: (nested as NSString).length, length: 0)
        ))
        XCTAssertEqual(apply(outdented, to: nested), "  - child")
        XCTAssertEqual(outdented.selectedRange, NSRange(location: (nested as NSString).length - 2, length: 0))

        let crlf = "- one\r\n- two"
        let crlfPlan = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .indent,
            in: crlf,
            selectedRange: NSRange(location: 0, length: (crlf as NSString).length)
        ))
        XCTAssertEqual(apply(crlfPlan, to: crlf), "  - one\r\n  - two")

        let firstLinePlan = try XCTUnwrap(MarkdownListEditPlanner.plan(
            .indent,
            in: crlf,
            selectedRange: NSRange(location: 0, length: ("- one\r\n" as NSString).length)
        ))
        XCTAssertEqual(apply(firstLinePlan, to: crlf), "  - one\r\n- two")
    }

    func testPlannerDoesNotChangeListsInsideFencedCode() {
        let source = "before\n```markdown\n- code\n```\nafter"
        let codeCaret = NSMaxRange((source as NSString).range(of: "- code"))

        XCTAssertNil(MarkdownListEditPlanner.plan(
            .newline,
            in: source,
            selectedRange: NSRange(location: codeCaret, length: 0)
        ))
        XCTAssertNil(MarkdownListEditPlanner.plan(
            .indent,
            in: source,
            selectedRange: NSRange(location: codeCaret, length: 0)
        ))
    }

    func testPlannerLeavesNonListTextAndSelectionsOnReturnToNativeEditing() {
        XCTAssertNil(MarkdownListEditPlanner.plan(
            .newline,
            in: "plain text",
            selectedRange: NSRange(location: 10, length: 0)
        ))
        XCTAssertNil(MarkdownListEditPlanner.plan(
            .newline,
            in: "- selected",
            selectedRange: NSRange(location: 2, length: 8)
        ))
    }

    func testLargeDocumentPlanningRemainsAnOnDemandBoundedInteraction() throws {
        let source = String(repeating: "ordinary Markdown body line\n", count: 120_000) + "- tail"
        let started = Date()
        let plan = MarkdownListEditPlanner.plan(
            .newline,
            in: source,
            selectedRange: NSRange(location: (source as NSString).length, length: 0)
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotNil(plan)
        XCTAssertLessThan(elapsed, 1.5)
        print(String(format: "Markdown list planner %.2f MB: %.3fs", Double(source.utf8.count) / 1_048_576, elapsed))

        let selectedList = String(repeating: "- nested item\n", count: 20_000)
        let selectionStarted = Date()
        let selectionPlan = MarkdownListEditPlanner.plan(
            .indent,
            in: selectedList,
            selectedRange: NSRange(location: 0, length: (selectedList as NSString).length)
        )
        let selectionElapsed = Date().timeIntervalSince(selectionStarted)
        XCTAssertNotNil(selectionPlan)
        XCTAssertLessThan(selectionElapsed, 1.5)
        print(String(format: "Markdown list planner 20,000-item selection: %.3fs", selectionElapsed))
    }

    private func apply(_ plan: MarkdownListEditPlan, to text: String) -> String {
        (text as NSString).replacingCharacters(in: plan.replacementRange, with: plan.replacementText)
    }
}
