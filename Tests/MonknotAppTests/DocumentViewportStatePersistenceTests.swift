import XCTest
@testable import MonknotApp

final class DocumentViewportStatePersistenceTests: XCTestCase {
    func testRoundTripIsIsolatedPerWorkspace() throws {
        let suiteName = "MonknotViewportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = DocumentViewportStatePersistence(defaults: defaults)
        let firstWorkspace = URL(fileURLWithPath: "/tmp/first-workspace", isDirectory: true)
        let secondWorkspace = URL(fileURLWithPath: "/tmp/second-workspace", isDirectory: true)
        let documentID = "/tmp/first-workspace/Note.md"
        let state = DocumentViewportState(
            textScrollPosition: .init(x: 12, y: 34),
            textSelection: .init(location: 8, length: 3),
            markdownPreviewScrollPosition: .init(x: 0, y: 90),
            htmlPreviewScrollPosition: nil,
            pdfViewportState: .init(
                position: .init(pageIndex: 4, point: .init(x: 10, y: 20)),
                zoomMode: .fixed(scaleFactor: 1.25)
            )
        )

        persistence.save([documentID: state], retaining: [documentID], for: firstWorkspace)

        XCTAssertEqual(persistence.load(for: firstWorkspace), [documentID: state])
        XCTAssertEqual(persistence.load(for: secondWorkspace), [:])
    }

    func testSavePrunesUnknownAndBoundsRetainedDocuments() throws {
        let suiteName = "MonknotViewportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = DocumentViewportStatePersistence(defaults: defaults, maximumDocumentCount: 2)
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let ids = ["a", "b", "c"]
        let states = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, DocumentViewportState(textSelection: .init(location: id.count, length: 0)))
        })

        persistence.save(states, retaining: ids, for: workspace)

        XCTAssertEqual(Set(persistence.load(for: workspace).keys), ["b", "c"])
    }

    func testCorruptPayloadFallsBackToEmptyState() throws {
        let suiteName = "MonknotViewportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = DocumentViewportStatePersistence(defaults: defaults)
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        defaults.set(Data("not json".utf8), forKey: persistence.key(for: workspace))

        XCTAssertEqual(persistence.load(for: workspace), [:])
    }

    func testViewportUpdateIdentityRejectsStaleWorkspaceCallbacksButRetainsRemovedDirtyDocuments() {
        let staleDocumentID = "/old-workspace/Paper.pdf"
        let removedDirtyDocumentID = "/current-workspace/Removed.pdf"

        XCTAssertTrue(shouldAcceptDocumentViewportUpdate(
            documentID: "/current-workspace/Paper.pdf",
            isCurrentWorkspaceDocument: true,
            removedDirtyDocumentIDs: []
        ))
        XCTAssertTrue(shouldAcceptDocumentViewportUpdate(
            documentID: removedDirtyDocumentID,
            isCurrentWorkspaceDocument: false,
            removedDirtyDocumentIDs: [removedDirtyDocumentID]
        ))
        XCTAssertFalse(shouldAcceptDocumentViewportUpdate(
            documentID: staleDocumentID,
            isCurrentWorkspaceDocument: false,
            removedDirtyDocumentIDs: [removedDirtyDocumentID]
        ))
    }
}
