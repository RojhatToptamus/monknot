import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFSourceRevisionTests: PDFLinkedExcerptTestCase {
    func testSourceRevisionDetectsDirtyEditAndDiskRaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("initial".utf8).write(to: sourceURL)

        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
        XCTAssertTrue(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 4
        ))

        try Data("a longer replacement".utf8).write(to: sourceURL, options: .atomic)
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
    }

    func testSourceRevisionRejectsDeletedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("initial".utf8).write(to: sourceURL)
        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))

        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertNil(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
    }

    func testSourceRevisionRejectsSymlinkReplacementOutsideWorkspace() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = parent.appendingPathComponent("Workspace", isDirectory: true)
        let sourceURL = workspaceURL.appendingPathComponent("Source.pdf")
        let outsideURL = parent.appendingPathComponent("Outside.pdf")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("initial".utf8).write(to: sourceURL)
        try Data("outside".utf8).write(to: outsideURL)
        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: workspaceURL,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))

        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outsideURL)

        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: workspaceURL,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
    }
}
