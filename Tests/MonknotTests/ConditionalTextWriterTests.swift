import Foundation
import XCTest
@testable import MonknotCore

final class ConditionalTextWriterTests: ExternalDocumentReconciliationTestCase {
    func testConditionalWriterRejectsStaleDiskAndPreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        try Data("baseline".utf8).write(to: url)
        let expected = try WorkspaceConditionalTextWriter.read(from: url)
        try Data("external".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(
            try WorkspaceConditionalTextWriter.write(
                "local",
                to: url,
                expecting: .present(expected)
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    func testConditionalWriterReadRefreshesSignatureAfterAtomicReplacement() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        try Data("disk\n".utf8).write(to: url)
        let initial = try WorkspaceConditionalTextWriter.read(from: url)

        let replacement = "newest disk\n"
        try Data(replacement.utf8).write(to: url, options: .atomic)
        let current = try WorkspaceConditionalTextWriter.read(from: url)

        XCTAssertEqual(current.text, replacement)
        XCTAssertEqual(current.signature.fileSize, Int64(replacement.utf8.count))
        XCTAssertNotEqual(current.signature.fileSize, initial.signature.fileSize)
    }

    func testConditionalWriterAcceptsAFileWhoseTextIsUnchanged() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        try Data("baseline\n".utf8).write(to: url)
        let expected = try WorkspaceConditionalTextWriter.read(from: url)
        // Another app saves the same text, and something else touches the file.
        try Data("baseline\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: url.path
        )
        XCTAssertNotEqual(try WorkspaceConditionalTextWriter.read(from: url).signature, expected.signature)

        try WorkspaceConditionalTextWriter.write("local\n", to: url, expecting: .present(expected))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "local\n")
    }

    func testConditionalWriterCreatesOnlyWhenStillAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.md")
        _ = try WorkspaceConditionalTextWriter.write("created", to: url, expecting: .absent)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "created")

        XCTAssertThrowsError(
            try WorkspaceConditionalTextWriter.write("overwrite", to: url, expecting: .absent)
        ) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .unexpectedlyCreated)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "created")
    }
}
