import XCTest
@testable import MonknotCore

final class WorkspaceReplaceServiceTests: XCTestCase {
    func testReplacedTextIsCaseInsensitive() {
        let result = WorkspaceReplaceService.replacedText(
            find: "needle",
            replacement: "pin",
            in: "Needle here and another NEEDLE"
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.text, "pin here and another pin")
    }

    func testReplacedTextHonorsCaseSensitiveAndWholeWordOptions() {
        let source = "Cat cat scatter cat_2 cat-café"

        let sensitive = WorkspaceReplaceService.replacedText(
            find: "cat",
            replacement: "dog",
            options: MonknotSearchOptions(isCaseSensitive: true),
            in: source
        )
        let wholeWord = WorkspaceReplaceService.replacedText(
            find: "cat",
            replacement: "dog",
            options: MonknotSearchOptions(isWholeWord: true),
            in: source
        )

        XCTAssertEqual(sensitive.text, "Cat dog sdogter dog_2 dog-café")
        XCTAssertEqual(sensitive.count, 4)
        XCTAssertEqual(wholeWord.text, "dog dog scatter cat_2 dog-café")
        XCTAssertEqual(wholeWord.count, 3)
    }

    func testReplaceAndWriteUpdatesFilesOnDisk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let documents = try WorkspaceDocumentScanner().scan(rootURL: root).documents

        let batch = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).replaceAndWrite(
            find: "beta",
            replacement: "gamma",
            documents: documents
        )

        XCTAssertEqual(batch.totalReplacements, 2)
        XCTAssertEqual(batch.fileResults.count, 2)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha gamma")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "gamma only")
    }

    func testReplaceLimitsToSearchResultDocumentIDs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let documents = try WorkspaceDocumentScanner().scan(rootURL: root).documents
        let firstID = documents.first(where: { $0.relativePath == "first.md" })!.id

        let batch = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).replaceAndWrite(
            find: "beta",
            replacement: "gamma",
            documents: documents,
            limitToDocumentIDs: [firstID]
        )

        XCTAssertEqual(batch.totalReplacements, 1)
        XCTAssertEqual(batch.fileResults.count, 1)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha gamma")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "beta only")
    }

    func testReplaceCapturesPreviousTextsForUndo() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("note.md")
        try "before replace".write(to: note, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: note, rootURL: root)

        let batch = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).replaceAndWrite(
            find: "before",
            replacement: "after",
            documents: [document]
        )

        XCTAssertEqual(batch.previousTextsByDocumentID[document.id], "before replace")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "after replace")
    }

    func testRestoreAndWriteRevertsDiskContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("note.md")
        try "changed".write(to: note, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: note, rootURL: root)

        let batch = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).restoreAndWrite(
            previousTextsByDocumentID: [document.id: "original"],
            documents: [document]
        )

        XCTAssertEqual(batch.fileResults.count, 1)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "original")
    }

    func testPreviewMatchesReplaceWithoutWriting() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "alpha beta".write(to: first, atomically: true, encoding: .utf8)
        try "beta only".write(to: second, atomically: true, encoding: .utf8)

        let documents = try WorkspaceDocumentScanner().scan(rootURL: root).documents

        let preview = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).preview(
            find: "beta",
            replacement: "gamma",
            documents: documents
        )

        XCTAssertEqual(preview.totalReplacements, 2)
        XCTAssertEqual(preview.fileResults.count, 2)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "alpha beta")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "beta only")
    }

    func testReplacePreviewSummaryListsFiles() {
        let preview = WorkspaceReplacePreview(
            fileResults: [
                WorkspaceReplaceFileResult(
                    documentID: "a",
                    relativePath: "notes/a.md",
                    displayName: "a.md",
                    replacementCount: 2
                ),
                WorkspaceReplaceFileResult(
                    documentID: "b",
                    relativePath: "notes/b.md",
                    displayName: "b.md",
                    replacementCount: 1
                )
            ],
            totalReplacements: 3,
            skippedDirtyCount: 1
        )

        let message = WorkspaceReplacePreview.summaryMessage(for: preview)
        XCTAssertTrue(message.contains("3 replacements in 2 files"))
        XCTAssertTrue(message.contains("notes/a.md (2)"))
        XCTAssertTrue(message.contains("1 unsaved file will be skipped"))
    }

    func testReplaceSkipsDirtyDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("note.md")
        try "keep me".write(to: note, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(url: note, rootURL: root)

        let batch = try WorkspaceReplaceService(textCache: WorkspaceTextContentCache()).replaceAndWrite(
            find: "keep",
            replacement: "change",
            documents: [document],
            skipDocumentIDs: [document.id]
        )

        XCTAssertEqual(batch.skippedDirtyCount, 1)
        XCTAssertEqual(batch.totalReplacements, 0)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "keep me")
    }

    func testWriteFailureKeepsEarlierCompletedFileAndLeavesFailingFileUnchanged() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        let second = lockedDirectory.appendingPathComponent("second.md")
        try "replace first".write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try "replace second".write(to: second, atomically: true, encoding: .utf8)

        let documents = [
            WorkspaceDocument(url: first, rootURL: root),
            WorkspaceDocument(url: second, rootURL: root),
        ]
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: lockedDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: lockedDirectory.path
            )
        }

        XCTAssertThrowsError(try WorkspaceReplaceService(
            textCache: WorkspaceTextContentCache()
        ).replaceAndWrite(
            find: "replace",
            replacement: "updated",
            documents: documents
        ))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "updated first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "replace second")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-replace-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
