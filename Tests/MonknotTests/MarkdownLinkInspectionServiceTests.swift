import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownLinkInspectionServiceTests: XCTestCase {
    func testFindsExactIncomingLinksWithSourceLocations() throws {
        let fixture = try makeFixture([
            "Current.md": "# Current\n",
            "Source.md": "[markdown](Current.md)\r\n[[Current#Heading]]\n[reference][target]\n\n[target]: Current.md\n",
            "Other.md": "[web](https://example.com)\n",
        ])
        defer { fixture.remove() }

        let result = try inspect("Current.md", fixture: fixture)

        XCTAssertEqual(result.incomingLinks.map(\.sourceRelativePath), ["Source.md", "Source.md", "Source.md"])
        XCTAssertEqual(result.incomingLinks.map(\.location.line), [1, 2, 3])
        XCTAssertEqual(result.incomingLinks.map(\.column), [1, 1, 1])
        XCTAssertEqual(result.incomingLinks.map(\.label), ["markdown", "Current#Heading", "reference"])
        XCTAssertTrue(result.outgoingIssues.isEmpty)
    }

    func testReportsMissingAmbiguousAndUnsafeOutgoingLinksAsUnresolved() throws {
        let fixture = try makeFixture([
            "Current.md": "[[Missing]]\n[[Daily]]\n[unsafe](../Outside.md)\n",
            "One/Daily.md": "# One\n",
            "Two/Daily.md": "# Two\n",
        ])
        defer { fixture.remove() }

        let result = try inspect("Current.md", fixture: fixture)

        XCTAssertEqual(result.outgoingIssues.map(\.kind), [.missing, .ambiguous, .missing])
        XCTAssertEqual(result.outgoingIssues.map(\.location.line), [1, 2, 3])
        XCTAssertEqual(
            result.outgoingIssues[1].candidateDocumentIDs,
            fixture.scan.documents.filter { $0.displayName == "Daily.md" }.map(\.id).sorted()
        )
    }

    func testUsesDirtyTextForActiveAndIncomingDocumentsWithoutChangingDisk() throws {
        let fixture = try makeFixture([
            "Current.md": "# Current\n",
            "Source.md": "[other](Other.md)\n",
            "Other.md": "# Other\n",
        ])
        defer { fixture.remove() }
        let current = try fixture.document("Current.md")
        let source = try fixture.document("Source.md")

        let result = try MarkdownLinkInspectionService(textCache: WorkspaceTextContentCache()).inspect(
            document: current,
            workspaceRootURL: fixture.root,
            documents: fixture.scan.documents,
            textByDocumentID: [
                current.id: "[[Dirty Missing]]\n",
                source.id: "😀 [current](Current.md)\r\n",
            ]
        )

        XCTAssertEqual(result.outgoingIssues.map(\.label), ["Dirty Missing"])
        XCTAssertEqual(result.incomingLinks.map(\.sourceDocumentID), [source.id])
        XCTAssertEqual(result.incomingLinks.first?.column, 3)
        XCTAssertEqual(try String(contentsOf: source.url, encoding: .utf8), "[other](Other.md)\n")
    }

    func testSkipsOversizedIncomingSourcesAndCountsThem() throws {
        let fixture = try makeFixture([
            "Current.md": "# Current\n",
            "Large.md": String(repeating: "x", count: 256) + "[current](Current.md)\n",
        ])
        defer { fixture.remove() }

        let current = try fixture.document("Current.md")
        let result = try MarkdownLinkInspectionService(
            maxFileBytes: 64,
            textCache: WorkspaceTextContentCache()
        ).inspect(
            document: current,
            workspaceRootURL: fixture.root,
            documents: fixture.scan.documents,
            textByDocumentID: [current.id: "# Current\n"]
        )

        XCTAssertTrue(result.incomingLinks.isEmpty)
        XCTAssertEqual(result.skippedDocumentCount, 1)
    }

    func testPreCancelledInspectionThrowsCancellationError() async throws {
        let fixture = try makeFixture([
            "Current.md": "# Current\n",
            "Source.md": "[current](Current.md)\n",
        ])
        defer { fixture.remove() }
        let current = try fixture.document("Current.md")
        let service = MarkdownLinkInspectionService(textCache: WorkspaceTextContentCache())

        let task = Task.detached {
            try service.inspect(
                document: current,
                workspaceRootURL: fixture.root,
                documents: fixture.scan.documents
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func inspect(_ relativePath: String, fixture: Fixture) throws -> MarkdownLinkInspection {
        try MarkdownLinkInspectionService(textCache: WorkspaceTextContentCache()).inspect(
            document: fixture.document(relativePath),
            workspaceRootURL: fixture.root,
            documents: fixture.scan.documents
        )
    }

    private func makeFixture(_ files: [String: String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-link-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, text) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return Fixture(
            root: root,
            scan: try WorkspaceDocumentScanner().scan(rootURL: root)
        )
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let scan: WorkspaceDocumentScanResult

        func document(_ relativePath: String) throws -> WorkspaceDocument {
            try XCTUnwrap(scan.documents.first { $0.relativePath == relativePath })
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
