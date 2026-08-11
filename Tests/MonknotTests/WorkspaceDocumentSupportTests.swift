import XCTest
@testable import MonknotCore

final class WorkspaceDocumentSupportTests: XCTestCase {
    func testDisplayNameForRelativePathUsesLastPathComponent() {
        XCTAssertEqual(
            WorkspaceDocumentSupport.displayName(forRelativePath: "notes/daily/2026-06-08.md"),
            "2026-06-08.md"
        )
        XCTAssertEqual(
            WorkspaceDocumentSupport.displayName(forRelativePath: "README.md"),
            "README.md"
        )
    }

    func testValidatedRelativePathReturnsPlainPOSIXPathsForFilesAndFolders() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Sources/Notes ü", isDirectory: true)
        let file = folder.appendingPathComponent("My File.swift")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try WorkspaceDocumentSupport.validatedRelativePath(for: folder, in: root),
            "Sources/Notes ü"
        )
        XCTAssertEqual(
            try WorkspaceDocumentSupport.validatedRelativePath(for: file, in: root),
            "Sources/Notes ü/My File.swift"
        )
    }

    func testValidatedRelativePathRejectsOutsidePrefixSiblingAndWorkspaceRoot() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Workspace", isDirectory: true)
        let prefixSibling = parent.appendingPathComponent("Workspace-Other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixSibling, withIntermediateDirectories: true)
        let outside = prefixSibling.appendingPathComponent("Note.md")
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try WorkspaceDocumentSupport.validatedRelativePath(for: outside, in: root)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSupport.RelativePathValidationError,
                .outsideWorkspace
            )
        }
        XCTAssertThrowsError(
            try WorkspaceDocumentSupport.validatedRelativePath(for: root, in: root)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSupport.RelativePathValidationError,
                .workspaceRoot
            )
        }
    }

    func testValidatedRelativePathRejectsStaleItemsAndUnavailableWorkspace() throws {
        let root = try makeTemporaryDirectory()
        let stale = root.appendingPathComponent("Removed.md")
        try "removed\n".write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: stale)

        XCTAssertThrowsError(
            try WorkspaceDocumentSupport.validatedRelativePath(for: stale, in: root)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSupport.RelativePathValidationError,
                .itemUnavailable
            )
        }

        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(
            try WorkspaceDocumentSupport.validatedRelativePath(for: stale, in: root)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSupport.RelativePathValidationError,
                .workspaceUnavailable
            )
        }
    }

    func testValidatedRelativePathRejectsSymlinkReplacement() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("Outside.md")
        let link = root.appendingPathComponent("Note.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try WorkspaceDocumentSupport.validatedRelativePath(for: link, in: root)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSupport.RelativePathValidationError,
                .itemUnavailable
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDocumentSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
