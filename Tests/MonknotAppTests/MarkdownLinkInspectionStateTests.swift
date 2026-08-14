import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownLinkInspectionStateTests: XCTestCase {
    func testLatestPresentationRejectsCancelledStaleResult() async throws {
        let first = try makeFixture(name: "First", sourceText: "[first](Current.md)\n")
        let second = try makeFixture(name: "Second", sourceText: "[second](Current.md)\n")
        defer {
            first.remove()
            second.remove()
        }
        let state = MarkdownLinkInspectionState(
            service: MarkdownLinkInspectionService(textCache: WorkspaceTextContentCache())
        )

        state.present(
            document: first.current,
            workspaceRootURL: first.root,
            documents: first.documents,
            textByDocumentID: [:]
        )
        state.present(
            document: second.current,
            workspaceRootURL: second.root,
            documents: second.documents,
            textByDocumentID: [:]
        )

        let didFinish = await waitUntil {
            !state.isLoading && state.inspection?.documentID == second.current.id
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(state.inspection?.incomingLinks.map(\.label), ["second"])
    }

    func testDismissCancelsPendingInspectionAndClearsState() async throws {
        let fixture = try makeFixture(name: "Dismiss", sourceText: "[current](Current.md)\n")
        defer { fixture.remove() }
        let state = MarkdownLinkInspectionState(
            service: MarkdownLinkInspectionService(textCache: WorkspaceTextContentCache())
        )

        state.present(
            document: fixture.current,
            workspaceRootURL: fixture.root,
            documents: fixture.documents,
            textByDocumentID: [:]
        )
        state.dismiss()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.inspection)
        XCTAssertNil(state.errorMessage)
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

    private func makeFixture(name: String, sourceText: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-link-state-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# \(name)\n".write(
            to: root.appendingPathComponent("Current.md"),
            atomically: true,
            encoding: .utf8
        )
        try sourceText.write(
            to: root.appendingPathComponent("Source.md"),
            atomically: true,
            encoding: .utf8
        )
        let documents = try WorkspaceDocumentScanner().scan(rootURL: root).documents
        return Fixture(
            root: root,
            current: try XCTUnwrap(documents.first { $0.relativePath == "Current.md" }),
            documents: documents
        )
    }

    private struct Fixture {
        let root: URL
        let current: WorkspaceDocument
        let documents: [WorkspaceDocument]

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
