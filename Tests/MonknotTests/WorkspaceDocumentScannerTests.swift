import Foundation
@testable import MonknotCore
import XCTest

final class WorkspaceDocumentScannerTests: XCTestCase {
    func testScannerBuildsWorkspaceFileTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Readme", to: root.appendingPathComponent("README.md"))
        try write("%PDF-1.7", to: root.appendingPathComponent("Guide.pdf"))
        try write("media", to: root.appendingPathComponent("Clip.mp4"))
        try write("plain text", to: root.appendingPathComponent("Notes.txt"))
        try write("<h1>Hello</h1>", to: root.appendingPathComponent("Preview.html"))
        try write("graph TD; A-->B", to: root.appendingPathComponent("diagram.mmd"))
        try write("build:\n\ttrue", to: root.appendingPathComponent("Makefile"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try write("- [x] Done", to: root.appendingPathComponent("Notes/Todo.markdown"))
        try write("not markdown", to: root.appendingPathComponent("Notes/image.png"))
        try write("binary", to: root.appendingPathComponent("Notes/archive.zip"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        let relativePaths = result.documents.map(\.relativePath).sorted()

        XCTAssertEqual(relativePaths, ["Clip.mp4", "Guide.pdf", "Makefile", "Notes.txt", "Notes/Todo.markdown", "Notes/archive.zip", "Notes/image.png", "Preview.html", "README.md", "diagram.mmd"])
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Clip.mp4" })?.kind, .media)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Guide.pdf" })?.kind, .pdf)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "README.md" })?.kind, .markdown)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Notes.txt" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.capabilities.canPreviewHTML, true)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "diagram.mmd" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Makefile" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "image.png" })?.kind, .nativePreview)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "archive.zip" })?.kind, .unsupported)
        XCTAssertEqual(result.root.children?.map(\.name), ["Empty", "Notes", "Clip.mp4", "diagram.mmd", "Guide.pdf", "Makefile", "Notes.txt", "Preview.html", "README.md"])
        XCTAssertEqual(result.root.children?.first(where: { $0.name == "Notes" })?.children?.map(\.name), ["archive.zip", "image.png", "Todo.markdown"])
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
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/sound.M4A")))
        XCTAssertTrue(WorkspaceDocumentSupport.isPDFDocument(URL(fileURLWithPath: "/tmp/guide.pdf")))
        XCTAssertTrue(WorkspaceDocumentSupport.isMarkdownDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/diagram.mmd"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertTrue(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).capabilities.canPreviewHTML)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/Makefile"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/image.png"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .nativePreview)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/movie.mp4"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .media)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/archive.zip"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
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
        XCTAssertFalse(html.capabilities.usesQuickLookPreview)
        XCTAssertTrue(mermaid.capabilities.canEditText)
        XCTAssertTrue(mermaid.capabilities.canSearchText)
        XCTAssertTrue(image.capabilities.usesQuickLookPreview)
        XCTAssertTrue(media.capabilities.canPreview)
        XCTAssertFalse(media.capabilities.canEditText)
        XCTAssertFalse(media.capabilities.canSearchText)
        XCTAssertFalse(media.capabilities.usesQuickLookPreview)
        XCTAssertFalse(archive.capabilities.canPreview)
    }

    func testScannerSkipsSymbolicLinkDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realDirectory = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try write("# Real", to: realDirectory.appendingPathComponent("Real.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Loop"),
            withDestinationURL: root
        )

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        XCTAssertEqual(result.documents.map(\.relativePath), ["Real/Real.md"])
        XCTAssertEqual(result.root.children?.map(\.name), ["Real"])
    }

    func testRelativePathFallsBackToFilenameOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/other/readme.md")

        XCTAssertEqual(WorkspaceDocumentSupport.relativePath(for: outside, in: root), "readme.md")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
