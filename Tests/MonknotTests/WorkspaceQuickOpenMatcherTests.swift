import XCTest
@testable import MonknotCore

final class WorkspaceQuickOpenMatcherTests: XCTestCase {
    func testEmptyQueryReturnsDocumentsInStableOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "a".write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let matches = WorkspaceQuickOpenMatcher.rankedDocuments(query: "", documents: scan.documents)

        XCTAssertEqual(matches.map(\.relativePath), ["alpha.md", "beta.md"])
    }

    func testFuzzyMatchPrefersPathSegmentStarts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("project.md"), atomically: true, encoding: .utf8)
        try "b".write(to: notes.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let matches = WorkspaceQuickOpenMatcher.rankedDocuments(query: "no", documents: scan.documents)

        XCTAssertEqual(matches.first?.relativePath, "notes/notes.md")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-quick-open-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
