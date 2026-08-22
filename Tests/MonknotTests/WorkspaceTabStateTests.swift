import XCTest
@testable import MonknotCore

final class WorkspaceTabStateTests: XCTestCase {
    func testMoveTabBeforeAnotherTabAndToTheEnd() {
        let (readme, guide, notes) = documents()
        var state = WorkspaceTabState()
        [readme, guide, notes].forEach { state.open($0) }

        state.moveTab(documentID: notes.id, before: readme.id)
        XCTAssertEqual(state.tabs.map(\.documentID), [notes.id, readme.id, guide.id])

        state.moveTab(documentID: notes.id, before: nil)
        XCTAssertEqual(state.tabs.map(\.documentID), [readme.id, guide.id, notes.id])
    }

    func testMovingPinnedTabKeepsPinnedTabsBeforeUnpinnedTabs() {
        let (readme, guide, notes) = documents()
        var state = WorkspaceTabState()
        [readme, guide, notes].forEach { state.open($0) }
        state.togglePin(documentID: notes.id)
        state.togglePin(documentID: guide.id)

        state.moveTab(documentID: notes.id, before: guide.id)

        XCTAssertEqual(state.tabs.map(\.documentID), [notes.id, guide.id, readme.id])
        XCTAssertTrue(state.tabs.prefix(2).allSatisfy(\.isPinned))
    }

    func testClosingSelectedAndFinalTabsUpdatesSelectionAndUserEmptyState() {
        let (readme, guide, _) = documents()
        var state = WorkspaceTabState()
        state.open(readme)
        state.open(guide)

        XCTAssertEqual(state.close(documentID: guide.id), readme.id)
        XCTAssertEqual(state.selectedDocumentID, readme.id)
        XCTAssertFalse(state.isEmptyByUserChoice)

        XCTAssertNil(state.close(documentID: readme.id))
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.selectedDocumentID)
        XCTAssertTrue(state.isEmptyByUserChoice)
    }

    func testRemapAndPrunePreserveOnlyAvailableOrExplicitlyPreservedTabs() {
        let (readme, _, notes) = documents()
        var state = WorkspaceTabState()
        state.open(readme)
        state.open(notes)
        let renamedID = "/tmp/MonknotWorkspace/Renamed.md"

        state.remapDocumentID(sourceID: notes.id, destinationID: renamedID)
        XCTAssertTrue(state.contains(documentID: renamedID))
        XCTAssertFalse(state.contains(documentID: notes.id))

        state.pruneUnavailableDocuments(
            availableDocumentIDs: [readme.id],
            preserving: [renamedID]
        )
        XCTAssertTrue(state.contains(documentID: renamedID))

        state.pruneUnavailableDocuments(availableDocumentIDs: [readme.id])
        XCTAssertFalse(state.contains(documentID: renamedID))
        XCTAssertEqual(state.tabs.map(\.documentID), [readme.id])
    }

    func testOpeningExistingTabActivatesWithoutMovingIt() {
        let root = URL(fileURLWithPath: "/tmp/MonknotWorkspace", isDirectory: true)
        let readme = WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root)
        let guide = WorkspaceDocument(url: root.appendingPathComponent("Guide.pdf"), rootURL: root)
        let notes = WorkspaceDocument(url: root.appendingPathComponent("Notes.md"), rootURL: root)

        var state = WorkspaceTabState()
        state.open(readme)
        state.open(guide)
        state.open(notes)
        state.moveTab(documentID: notes.id, before: readme.id)

        let reorderedIDs = state.tabs.map(\.documentID)
        XCTAssertEqual(reorderedIDs, [notes.id, readme.id, guide.id])

        state.open(readme)

        XCTAssertEqual(state.tabs.map(\.documentID), reorderedIDs)
        XCTAssertEqual(state.selectedDocumentID, readme.id)
    }

    func testClosedTabHistoryIsBoundedDeduplicatedAndLIFO() {
        var history = WorkspaceClosedTabHistory(capacity: 2)
        history.record(tab("one.md"))
        history.record(tab("two.md"))
        history.record(tab("one.md", isPinned: true))
        history.record(tab("three.md"))

        XCTAssertEqual(history.tabs.map(\.displayName), ["one.md", "three.md"])
        XCTAssertTrue(history.tabs[0].isPinned)
        XCTAssertEqual(
            history.takeMostRecent(availableDocumentIDs: Set(history.tabs.map(\.documentID)))?.displayName,
            "three.md"
        )
        XCTAssertEqual(
            history.takeMostRecent(availableDocumentIDs: Set(history.tabs.map(\.documentID)))?.displayName,
            "one.md"
        )
        XCTAssertNil(history.takeMostRecent(availableDocumentIDs: []))

        history.record(tab("opened-again.md"))
        history.discard(documentID: tab("opened-again.md").documentID)
        XCTAssertTrue(history.tabs.isEmpty)
    }

    func testClosedTabHistorySkipsDeletedDocuments() {
        var history = WorkspaceClosedTabHistory()
        let available = tab("available.md")
        history.record(available)
        history.record(tab("deleted.md"))

        XCTAssertTrue(history.hasAvailableTab(documentIDs: [available.documentID]))
        XCTAssertEqual(
            history.takeMostRecent(availableDocumentIDs: [available.documentID]),
            available
        )
        XCTAssertTrue(history.tabs.isEmpty)
    }

    func testClosedTabHistoryRemapsRenamedDocumentsAndPreservesPin() {
        var history = WorkspaceClosedTabHistory()
        let source = tab("before.md", isPinned: true)
        let existingDestination = tab("after.md")
        history.record(source)
        history.record(existingDestination)

        let root = URL(fileURLWithPath: "/tmp/MonknotWorkspace", isDirectory: true)
        let renamedDocument = WorkspaceDocument(
            url: root.appendingPathComponent("after.md"),
            rootURL: root
        )
        history.remapDocumentID(
            from: source.documentID,
            to: existingDestination.documentID,
            document: renamedDocument
        )

        XCTAssertEqual(history.tabs.count, 1)
        XCTAssertEqual(history.tabs[0].documentID, existingDestination.documentID)
        XCTAssertEqual(history.tabs[0].displayName, renamedDocument.displayName)
        XCTAssertEqual(history.tabs[0].relativePath, renamedDocument.relativePath)
        XCTAssertTrue(history.tabs[0].isPinned)

        history.reset()
        XCTAssertTrue(history.tabs.isEmpty)
    }

    private func tab(_ name: String, isPinned: Bool = false) -> WorkspaceTabItem {
        WorkspaceTabItem(
            documentID: "/tmp/MonknotWorkspace/\(name)",
            displayName: name,
            relativePath: name,
            kind: .markdown,
            isPinned: isPinned
        )
    }

    private func documents() -> (WorkspaceDocument, WorkspaceDocument, WorkspaceDocument) {
        let root = URL(fileURLWithPath: "/tmp/MonknotWorkspace", isDirectory: true)
        return (
            WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("Guide.pdf"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("Notes.md"), rootURL: root)
        )
    }

}
