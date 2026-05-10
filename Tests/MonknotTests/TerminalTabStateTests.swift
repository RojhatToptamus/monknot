import XCTest
@testable import MonknotCore

final class TerminalTabStateTests: XCTestCase {
    func testCreateTerminalSelectsNewTerminalAndAssignsSequentialTitles() {
        var state = TerminalTabState()

        let first = state.create(workingDirectoryPath: "/tmp/workspace")
        let second = state.create(workingDirectoryPath: "/tmp/workspace/docs")

        XCTAssertEqual(state.tabs.map(\.title), ["zsh", "zsh 2"])
        XCTAssertEqual(state.tabs.map(\.workingDirectoryPath), ["/tmp/workspace", "/tmp/workspace/docs"])
        XCTAssertEqual(state.selectedTerminalID, second.id)
        XCTAssertEqual(state.selectedTerminal, second)
        XCTAssertTrue(state.contains(terminalID: first.id))
    }

    func testActivateRequiresAnExistingTerminal() {
        var state = TerminalTabState()
        let first = state.create()
        _ = state.create()

        XCTAssertTrue(state.activate(terminalID: first.id))
        XCTAssertEqual(state.selectedTerminalID, first.id)

        XCTAssertFalse(state.activate(terminalID: "missing"))
        XCTAssertEqual(state.selectedTerminalID, first.id)
    }

    func testRemovingSelectedTerminalSelectsNearestNeighbor() {
        var state = TerminalTabState()
        let first = state.create()
        let second = state.create()
        let third = state.create()

        XCTAssertEqual(state.selectedTerminalID, third.id)

        XCTAssertEqual(state.remove(terminalID: second.id), third.id)
        XCTAssertEqual(state.selectedTerminalID, third.id)

        XCTAssertEqual(state.remove(terminalID: third.id), first.id)
        XCTAssertEqual(state.selectedTerminalID, first.id)
    }

    func testRemovingLastTerminalLeavesNoSelection() {
        var state = TerminalTabState()
        let terminal = state.create()

        XCTAssertNil(state.remove(terminalID: terminal.id))
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.selectedTerminalID)
    }

    func testRenameIgnoresEmptyTitles() {
        var state = TerminalTabState()
        let terminal = state.create()

        state.rename(terminalID: terminal.id, title: "  build  ")
        XCTAssertEqual(state.tab(for: terminal.id)?.title, "build")

        state.rename(terminalID: terminal.id, title: "   ")
        XCTAssertEqual(state.tab(for: terminal.id)?.title, "build")
    }
}
