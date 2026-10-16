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

    func testReadUTF8TextRejectsBinaryDataThatIsValidUTF8() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("misnamed.txt")
        try Data([0x41, 0x00, 0x00, 0x01, 0x42, 0x00, 0x7F]).write(to: file)

        XCTAssertThrowsError(
            try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: nil)
        ) { error in
            guard case WorkspaceTextFileGuard.Error.binaryContent = error else {
                return XCTFail("Expected binaryContent, got \(error)")
            }
        }
    }

    func testReadUTF8TextOpensAnEmptyFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        XCTAssertEqual(try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: nil), "")
    }

    /// One file that is not text must not fail the whole search or replace; it simply has no matches.
    func testSearchAndReplaceSkipFilesThatAreNotUTF8Text() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("note.md")
        try "needle in a note\n".write(to: note, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("photo.txt")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: binary)
        let nulText = root.appendingPathComponent("zeros.txt")
        try Data("needle".utf8 + [0x00, 0x00]).write(to: nulText)
        let latin1 = root.appendingPathComponent("latin1.txt")
        try XCTUnwrap("needle café".data(using: .isoLatin1)).write(to: latin1)
        let documents = [binary, nulText, latin1, note].map { WorkspaceDocument(url: $0, rootURL: root) }

        for maxAutoIndexedTextBytes: Int64 in [0, 1024 * 1024] {
            let cache = WorkspaceTextContentCache()
            let batch = try WorkspaceSearchService(
                maxAutoIndexedTextBytes: maxAutoIndexedTextBytes,
                textCache: cache
            ).search(query: "needle", documents: documents)
            XCTAssertEqual(batch.results.map(\.documentID), [note.standardizedFileURL.path])
            XCTAssertEqual(batch.skippedLargeFileCount, 0)
        }

        let index = WorkspaceSearchIndex(textCache: WorkspaceTextContentCache())
        XCTAssertNoThrow(try index.rebuild(documents: documents))
        XCTAssertEqual(
            try index.search(query: "needle", documents: documents).results.map(\.documentID),
            [note.standardizedFileURL.path]
        )

        let replaced = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache())
            .replaceAndWrite(find: "needle", replacement: "pin", documents: documents)
        XCTAssertEqual(replaced.fileResults.map(\.documentID), [note.standardizedFileURL.path])
        XCTAssertEqual(try Data(contentsOf: latin1), try XCTUnwrap("needle café".data(using: .isoLatin1)))
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

    func testSavingKeepsAByteOrderMarkTheFileStartsWith() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        let marked = root.appendingPathComponent("marked.md")
        let plain = root.appendingPathComponent("plain.md")
        try (byteOrderMark + Data("# Old".utf8)).write(to: marked)
        try Data("# Old".utf8).write(to: plain)

        let loaded = try WorkspaceTextFileGuard.readUTF8Text(from: marked, cache: nil)
        XCTAssertEqual(loaded, "# Old")
        try WorkspaceTextFileGuard.writeUTF8Text("# New", to: marked)
        try WorkspaceTextFileGuard.writeUTF8Text("# New", to: plain)
        try WorkspaceConditionalTextWriter.write(
            "# Newer",
            to: marked,
            expecting: .present(try WorkspaceConditionalTextWriter.read(from: marked))
        )

        XCTAssertEqual(try Data(contentsOf: marked), byteOrderMark + Data("# Newer".utf8))
        XCTAssertEqual(try Data(contentsOf: plain), Data("# New".utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-text-guard-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
