import Foundation
import XCTest
@testable import MonknotCore

final class ConditionalDataWriterTests: ExternalDocumentReconciliationTestCase {
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
}
