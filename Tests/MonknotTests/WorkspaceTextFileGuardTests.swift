import XCTest
@testable import MonknotCore

final class WorkspaceTextFileGuardTests: XCTestCase {
    func testReadUTF8TextLoadsSmallFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let text = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: nil)
        XCTAssertEqual(text, "hello")
    }

    func testReadUTF8TextRejectsOversizedFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("large.txt")
        let payload = String(repeating: "a", count: 2048)
        try payload.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try WorkspaceTextFileGuard.readUTF8Text(from: file, maxBytes: 1024, cache: nil)
        ) { error in
            guard case WorkspaceTextFileGuard.Error.fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testReadUTF8TextEnforcesMaxBytesBeforeReturningCachedText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("cached-large.txt")
        try String(repeating: "a", count: 2048).write(to: file, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache()
        XCTAssertEqual(try WorkspaceTextFileGuard.readUTF8Text(from: file, maxBytes: 4096, cache: cache).count, 2048)

        XCTAssertThrowsError(
            try WorkspaceTextFileGuard.readUTF8Text(from: file, maxBytes: 1024, cache: cache)
        ) { error in
            guard case WorkspaceTextFileGuard.Error.fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testReadUTF8TextRejectsNonUTF8Encoding() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("binary.txt")
        try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: file)

        XCTAssertThrowsError(
            try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: nil)
        ) { error in
            guard case WorkspaceTextFileGuard.Error.unreadableEncoding = error else {
                return XCTFail("Expected unreadableEncoding, got \(error)")
            }
        }
    }

    func testSearchSkipsOversizedTextDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("large.md")
        try String(repeating: "needle ", count: 300).write(to: file, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: file, rootURL: root)]
        let cache = WorkspaceTextContentCache()

        let batch = try WorkspaceSearchService(
            maxMatches: 10,
            maxMatchesPerFile: 10,
            maxTextFileBytes: 1024,
            textCache: cache
        ).search(query: "needle", documents: documents)
        XCTAssertTrue(batch.results.isEmpty)
        XCTAssertEqual(batch.skippedLargeFileCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-text-guard-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
