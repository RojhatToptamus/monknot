import XCTest
@testable import MonknotCore

final class RelatedNotesServiceTests: XCTestCase {
    func testFindsSharedHeadingMatches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        let related = root.appendingPathComponent("related.md")
        try "# Project\n\n# Authentication\n\ncontent".write(to: current, atomically: true, encoding: .utf8)
        try "# Authentication\n\nother note".write(to: related, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "current.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService().relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertEqual(matches.first?.relativePath, "related.md")
        XCTAssertTrue(matches.first?.reason.contains("shared heading") == true)
    }

    func testFindsSharedTagMatches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("a.md")
        let related = root.appendingPathComponent("b.md")
        try "# Note\n\n#project".write(to: current, atomically: true, encoding: .utf8)
        try "# Other\n\n#project".write(to: related, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "a.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService().relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertEqual(matches.first?.relativePath, "b.md")
        XCTAssertTrue(matches.first?.reason.contains("shared tag") == true)
    }

    func testDoesNotScanNonMarkdownTextCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        let source = root.appendingPathComponent("source.txt")
        try "# Project\n\n# Authentication\n\ncontent".write(to: current, atomically: true, encoding: .utf8)
        try "# Authentication\n\nplain text should not appear as related note".write(to: source, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "current.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService().relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testSkipsOversizedMarkdownCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        let large = root.appendingPathComponent("large.md")
        try "# Project\n\n# Authentication\n\ncontent".write(to: current, atomically: true, encoding: .utf8)
        try ("# Authentication\n" + String(repeating: "x", count: 256)).write(to: large, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "current.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService(maxFileBytes: 64).relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testCanDisableCandidateScan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        let related = root.appendingPathComponent("related.md")
        try "# Project\n\n# Authentication\n\ncontent".write(to: current, atomically: true, encoding: .utf8)
        try "# Authentication\n\nother note".write(to: related, atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "current.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService(maxCandidateDocuments: 0).relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testCandidateLimitPrioritizesSameFolder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        try "# Project\n\n# Authentication\n\ncontent".write(
            to: notes.appendingPathComponent("current.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Authentication\n\nsame folder".write(
            to: notes.appendingPathComponent("related.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Authentication\n\nother folder".write(
            to: archive.appendingPathComponent("related.md"),
            atomically: true,
            encoding: .utf8
        )

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let currentDocument = scan.documents.first(where: { $0.relativePath == "notes/current.md" }) else {
            return XCTFail("Missing current document")
        }

        let matches = RelatedNotesService(maxCandidateDocuments: 1).relatedNotes(
            for: currentDocument,
            documents: scan.documents,
            textCache: WorkspaceTextContentCache()
        )

        XCTAssertEqual(matches.map(\.relativePath), ["notes/related.md"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-related-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
