import Foundation
import XCTest
@testable import MonknotCore

final class ExternalDocumentReconciliationServiceTests: XCTestCase {
    func testConditionalDataWriterRejectsStaleBinaryAndPreservesDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper.pdf")
        let baseline = Data([1, 2, 3])
        let disk = Data([4, 5, 6])
        try disk.write(to: url)

        XCTAssertThrowsError(try WorkspaceConditionalDataWriter.write(
            Data([7, 8, 9]),
            to: url,
            expecting: .present(baseline)
        )) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: url), disk)
    }

    func testConditionalDataWriterAtomicallyReplacesExpectedBinary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper.pdf")
        let baseline = Data([1, 2, 3])
        let updated = Data([7, 8, 9])
        try baseline.write(to: url)

        let written = try WorkspaceConditionalDataWriter.write(
            updated,
            to: url,
            expecting: .present(baseline)
        )

        XCTAssertEqual(written, updated)
        XCTAssertEqual(try Data(contentsOf: url), updated)
    }

    func testConditionalDataWriterCreatesOnlyWhenStillAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Paper Copy.pdf")
        let created = Data([1, 2, 3])

        XCTAssertEqual(
            try WorkspaceConditionalDataWriter.write(created, to: url, expecting: .absent),
            created
        )
        XCTAssertEqual(try Data(contentsOf: url), created)

        XCTAssertThrowsError(try WorkspaceConditionalDataWriter.write(
            Data([4, 5, 6]),
            to: url,
            expecting: .absent
        )) { error in
            XCTAssertEqual(error as? WorkspaceTextRevisionError, .unexpectedlyCreated)
        }
        XCTAssertEqual(try Data(contentsOf: url), created)
    }

    func testMergeUsesChangedSideWhenOtherSideIsBaseline() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "alpha\nbeta\n",
                local: "alpha\nbeta\n",
                disk: "alpha\ndisk\n"
            ),
            "alpha\ndisk\n"
        )
    }

    func testMergeCombinesDisjointUnicodeEdits() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "😀 alpha\nbeta\ngamma\n",
                local: "😀 local\nbeta\ngamma\n",
                disk: "😀 alpha\nbeta\ndisk\n"
            ),
            "😀 local\nbeta\ndisk\n"
        )
    }

    func testMergeDoesNotSplitEmojiGraphemes() {
        XCTAssertEqual(
            ExternalDocumentReconciliationService.merge(
                baseline: "😀a",
                local: "😁a",
                disk: "😀b"
            ),
            "😁b"
        )
    }

    func testMergeRejectsOverlappingEditsWithoutConflictMarkers() {
        XCTAssertNil(
            ExternalDocumentReconciliationService.merge(
                baseline: "one two three",
                local: "one LOCAL three",
                disk: "one DISK three"
            )
        )
    }

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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDocumentReconciliationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
