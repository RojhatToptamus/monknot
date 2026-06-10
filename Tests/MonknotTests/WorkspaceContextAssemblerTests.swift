import XCTest
@testable import MonknotCore

final class WorkspaceContextAssemblerTests: XCTestCase {
    func testSearchTermsFiltersStopWords() {
        let terms = WorkspaceContextAssembler.searchTerms(from: "What is the authentication flow?")
        XCTAssertTrue(terms.contains("authentication"))
        XCTAssertTrue(terms.contains("flow"))
        XCTAssertFalse(terms.contains("what"))
        XCTAssertFalse(terms.contains("the"))
    }

    func testAssembleBuildsContextChunksAroundMatches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("auth.md")
        try """
        intro
        ## Authentication
        users sign in with tokens
        more details
        """.write(to: note, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let chunks = try WorkspaceContextAssembler().assemble(
            question: "How does authentication work?",
            documents: scan.documents
        )

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.first?.relativePath, "auth.md")
        XCTAssertTrue(chunks.first?.text.contains("Authentication") == true)
    }

    func testAssemblePrioritizesPreferredRelatedDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let primary = root.appendingPathComponent("primary.md")
        let related = root.appendingPathComponent("related.md")
        try """
        # Primary
        authentication overview
        """.write(to: primary, atomically: true, encoding: .utf8)
        try """
        # Related
        authentication tokens and sessions
        """.write(to: related, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let chunks = try WorkspaceContextAssembler().assemble(
            question: "How does authentication work?",
            documents: scan.documents,
            preferredRelativePaths: ["related.md"]
        )

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.first?.relativePath, "related.md")
    }

    func testPreferredDocumentsPreservesOrder() {
        let root = URL(fileURLWithPath: "/tmp")
        let documents = [
            WorkspaceDocument(url: root.appendingPathComponent("b.md"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("a.md"), rootURL: root),
            WorkspaceDocument(url: root.appendingPathComponent("c.md"), rootURL: root)
        ]

        let preferred = WorkspaceContextAssembler.preferredDocuments(
            from: documents,
            preferredRelativePaths: ["c.md", "a.md"]
        )

        XCTAssertEqual(preferred.map(\.relativePath), ["c.md", "a.md"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-context-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
