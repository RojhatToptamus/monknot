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

    func testSupportedExtensionsAreCaseInsensitive() {
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/README.MD")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/spec.markdown")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/note.mdown")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/diagram.MMD")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/Makefile")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/guide.PDF")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/notes.TXT")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/Preview.HTML")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/sound.M4A")))
        XCTAssertTrue(WorkspaceDocumentSupport.isPDFDocument(URL(fileURLWithPath: "/tmp/guide.pdf")))
        XCTAssertTrue(WorkspaceDocumentSupport.isMarkdownDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/diagram.mmd"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertTrue(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).capabilities.canPreviewHTML)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/Makefile"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/image.png"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/movie.mp4"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/archive.zip"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
    }

    func testWorkspaceScanGateSkipsKnownUnsupportedExtensionsBeforeDocumentCreation() {
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/README.md")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/Guide.PDF")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/Makefile")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/archive.zip")))
    }

    func testDocumentCapabilitiesAreClassifiedByFormatGroup() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let markdown = WorkspaceDocument(url: root.appendingPathComponent("README.md"), rootURL: root)
        let pdf = WorkspaceDocument(url: root.appendingPathComponent("Guide.pdf"), rootURL: root)
        let text = WorkspaceDocument(url: root.appendingPathComponent("notes.txt"), rootURL: root)
        let html = WorkspaceDocument(url: root.appendingPathComponent("preview.html"), rootURL: root)
        let mermaid = WorkspaceDocument(url: root.appendingPathComponent("diagram.mmd"), rootURL: root)
        let image = WorkspaceDocument(url: root.appendingPathComponent("image.png"), rootURL: root)
        let media = WorkspaceDocument(url: root.appendingPathComponent("movie.mp4"), rootURL: root)
        let archive = WorkspaceDocument(url: root.appendingPathComponent("archive.zip"), rootURL: root)

        XCTAssertTrue(markdown.capabilities.canEditText)
        XCTAssertTrue(markdown.capabilities.canExportPDF)
        XCTAssertTrue(markdown.capabilities.canShowOutline)
        XCTAssertTrue(pdf.capabilities.canSearchPDF)
        XCTAssertFalse(pdf.capabilities.canEditText)
        XCTAssertTrue(text.capabilities.canEditText)
        XCTAssertTrue(text.capabilities.canSearchText)
        XCTAssertFalse(text.capabilities.canPreviewHTML)
        XCTAssertTrue(html.capabilities.canEditText)
        XCTAssertTrue(html.capabilities.canSearchText)
        XCTAssertTrue(html.capabilities.canPreviewHTML)
        XCTAssertTrue(mermaid.capabilities.canEditText)
        XCTAssertTrue(mermaid.capabilities.canSearchText)
        XCTAssertFalse(image.capabilities.canPreview)
        XCTAssertFalse(media.capabilities.canPreview)
        XCTAssertFalse(media.capabilities.canEditText)
        XCTAssertFalse(media.capabilities.canSearchText)
        XCTAssertFalse(archive.capabilities.canPreview)
    }

    func testRelativePathFallsBackToFilenameOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/other/readme.md")

        XCTAssertEqual(WorkspaceDocumentSupport.relativePath(for: outside, in: root), "readme.md")
    }
}
