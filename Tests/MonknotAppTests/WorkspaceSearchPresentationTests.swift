import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceSearchPresentationTests: XCTestCase {
    func testUtilityPanelUsesTheCompleteWorkspaceZoom() {
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.densityZoomScale(WorkspaceZoomPolicy.maximum),
            WorkspaceZoomPolicy.maximum
        )
        XCTAssertEqual(
            WorkspaceSearchLayoutPolicy.densityZoomScale(WorkspaceZoomPolicy.minimum),
            WorkspaceZoomPolicy.minimum
        )
    }

    func testSearchFieldFollowsWorkspaceControlZoom() {
        let maximumHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .defaultDark,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let normalHeight = WorkspaceSearchLayoutPolicy.fieldHeight(
            theme: .defaultDark,
            zoomScale: 1
        )

        XCTAssertGreaterThan(maximumHeight, normalHeight)
        XCTAssertEqual(
            maximumHeight,
            MonknotMetrics.interfaceControl(
                28,
                theme: .defaultDark,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            accuracy: 0.001
        )
    }

    func testGroupingPreservesFirstFileOrderAndGlobalSelectionIndices() {
        let results = [
            result(id: "notes-1", documentID: "/Notes.md", relativePath: "Notes.md", line: 4),
            result(id: "brief-1", documentID: "/Brief.pdf", relativePath: "Reference/Brief.pdf", kind: .pdf, line: 2),
            result(id: "notes-2", documentID: "/Notes.md", relativePath: "Notes.md", line: 18)
        ]

        let groups = WorkspaceSearchResultGrouping.groups(from: results)

        XCTAssertEqual(groups.map(\.documentID), ["/Notes.md", "/Brief.pdf"])
        XCTAssertEqual(groups[0].matches.map(\.index), [0, 2])
        XCTAssertEqual(groups[1].matches.map(\.index), [1])
        XCTAssertEqual(groups[0].relativePath, "Notes.md")
        XCTAssertEqual(groups[1].kind, .pdf)
    }

    func testListItemsFlattenEachFileHeaderBeforeItsMatches() {
        let results = [
            result(id: "notes-1", documentID: "/Notes.md", relativePath: "Notes.md", line: 4),
            result(id: "brief-1", documentID: "/Brief.pdf", relativePath: "Reference/Brief.pdf", kind: .pdf, line: 2),
            result(id: "notes-2", documentID: "/Notes.md", relativePath: "Notes.md", line: 18)
        ]

        let items = WorkspaceSearchResultGrouping.listItems(
            from: WorkspaceSearchResultGrouping.groups(from: results)
        )

        // One lazy item per header and per match, so the stack never estimates a whole file at once.
        XCTAssertEqual(items.map(\.id), [.file("/Notes.md"), .match(0), .match(2), .file("/Brief.pdf"), .match(1)])
    }

    func testMatchesOnOneLineKnowWhichOccurrenceTheyAre() {
        let results = [
            result(id: "a", documentID: "/Notes.md", relativePath: "Notes.md", line: 4),
            result(id: "b", documentID: "/Notes.md", relativePath: "Notes.md", line: 4),
            result(id: "c", documentID: "/Notes.md", relativePath: "Notes.md", line: 9),
        ]
        let matches = WorkspaceSearchResultGrouping.groups(from: results)[0].matches
        XCTAssertEqual(matches.map(\.occurrenceInLine), [0, 1, 0])
    }

    func testPDFMatchesOnDifferentLinesOfOnePageCountTheirOwnOccurrences() {
        func pdfResult(_ id: String, preview: String) -> WorkspaceSearchResult {
            WorkspaceSearchResult(
                id: id,
                documentID: "/Brief.pdf",
                relativePath: "Brief.pdf",
                displayName: "Brief.pdf",
                kind: .pdf,
                line: 3,
                column: 0,
                preview: preview
            )
        }
        let results = [
            pdfResult("a", preview: "first review here"),
            pdfResult("b", preview: "second review and review"),
            pdfResult("c", preview: "second review and review"),
        ]
        let matches = WorkspaceSearchResultGrouping.groups(from: results)[0].matches
        XCTAssertEqual(matches.map(\.occurrenceInLine), [0, 0, 1])
    }

    func testSnippetKeepsSomeContextWhenTheOnlySpaceSitsRightBeforeTheMatch() throws {
        let preview = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx lorem review"
        let snippet = WorkspaceSearchSnippet.make(
            preview: preview,
            query: "review",
            options: MonknotSearchOptions(),
            occurrence: 0
        )
        let match = try XCTUnwrap(snippet.match)
        XCTAssertGreaterThan(
            snippet.text.distance(from: snippet.text.startIndex, to: match.lowerBound),
            WorkspaceSearchSnippet.minimumContext
        )
    }

    func testSnippetKeepsItsOwnOccurrenceInViewAndMarksOnlyIt() throws {
        let line = "See [[Zettelkasten/note-001]] and the incident review, then the follow-up review"
        let options = MonknotSearchOptions()

        let first = WorkspaceSearchSnippet.make(preview: line, query: "review", options: options, occurrence: 0)
        let firstMatch = try XCTUnwrap(first.match)
        XCTAssertTrue(first.text.hasPrefix("…"), "A match far into the line clips the start")
        XCTAssertEqual(String(first.text[firstMatch]), "review")
        XCTAssertLessThanOrEqual(first.text.distance(from: first.text.startIndex, to: firstMatch.lowerBound), 20)

        let second = WorkspaceSearchSnippet.make(preview: line, query: "review", options: options, occurrence: 1)
        let secondMatch = try XCTUnwrap(second.match)
        XCTAssertEqual(String(second.text[secondMatch]), "review")
        XCTAssertNotEqual(first.text, second.text, "Two matches on one line read differently")

        let early = WorkspaceSearchSnippet.make(preview: "review the draft", query: "review", options: options, occurrence: 0)
        XCTAssertEqual(early.text, "review the draft", "A match near the start leaves the line whole")
    }

    func testGroupingReturnsNoPlaceholderGroupForAnEmptySearch() {
        XCTAssertTrue(WorkspaceSearchResultGrouping.groups(from: []).isEmpty)
    }

    func testSearchCapturesDirtyTextAndRejectsCancelledStaleResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("Note.md")
        try "disk value\n".write(to: noteURL, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: noteURL, rootURL: root)
        let state = WorkspaceSearchState()

        state.present(documents: [document])
        state.setQuery(
            "old-token",
            documents: [document],
            dirtyTextByDocumentID: [document.id: "old-token\n"]
        )
        state.setQuery(
            "new-token",
            documents: [document],
            dirtyTextByDocumentID: [document.id: "new-token\n"]
        )

        let didFinish = await waitUntil { !state.isSearching && state.results.count == 1 }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(state.query, "new-token")
        XCTAssertEqual(state.results.first?.preview, "new-token")
    }

    func testSearchUsesAnImmutableDirtySnapshotForOneGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("Note.md")
        try "disk value\n".write(to: noteURL, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: noteURL, rootURL: root)
        let state = WorkspaceSearchState()
        var dirtyText = [document.id: "snapshot-token\n"]

        state.present(documents: [document])
        state.setQuery(
            "snapshot-token",
            documents: [document],
            dirtyTextByDocumentID: dirtyText
        )
        dirtyText[document.id] = "changed-after-start\n"

        let didFinish = await waitUntil { !state.isSearching && state.results.count == 1 }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(state.results.first?.preview, "snapshot-token")
    }

    func testChangingOptionsCancelsAndRejectsThePreviousSearchGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("Note.md")
        try "disk value\n".write(to: noteURL, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: noteURL, rootURL: root)
        let state = WorkspaceSearchState()

        state.present(documents: [document])
        state.setQuery(
            "token",
            options: .init(),
            documents: [document],
            dirtyTextByDocumentID: [document.id: "TOKEN\n"]
        )
        state.refresh(
            options: MonknotSearchOptions(isCaseSensitive: true),
            documents: [document],
            dirtyTextByDocumentID: [document.id: "TOKEN\n"]
        )

        let didFinish = await waitUntil { !state.isSearching }
        XCTAssertTrue(didFinish)
        XCTAssertTrue(state.results.isEmpty)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func result(
        id: String,
        documentID: String,
        relativePath: String,
        kind: WorkspaceSearchResultKind = .text,
        line: Int
    ) -> WorkspaceSearchResult {
        WorkspaceSearchResult(
            id: id,
            documentID: documentID,
            relativePath: relativePath,
            displayName: URL(fileURLWithPath: relativePath).lastPathComponent,
            kind: kind,
            line: line,
            column: 1,
            preview: "A matching workspace result"
        )
    }
}
