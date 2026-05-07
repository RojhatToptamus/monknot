import Foundation
@testable import MarkprevCore
import XCTest

final class WorkspaceDocumentScannerTests: XCTestCase {
    func testScannerBuildsSupportedDocumentTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Readme", to: root.appendingPathComponent("README.md"))
        try write("%PDF-1.7", to: root.appendingPathComponent("Guide.pdf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try write("- [x] Done", to: root.appendingPathComponent("Notes/Todo.markdown"))
        try write("not markdown", to: root.appendingPathComponent("Notes/image.png"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        let relativePaths = result.documents.map(\.relativePath).sorted()

        XCTAssertEqual(relativePaths, ["Guide.pdf", "Notes/Todo.markdown", "README.md"])
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Guide.pdf" })?.kind, .pdf)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "README.md" })?.kind, .markdown)
        XCTAssertEqual(result.root.children?.map(\.name), ["Notes", "Guide.pdf", "README.md"])
        XCTAssertEqual(result.root.children?.first?.children?.map(\.name), ["Todo.markdown"])
    }

    func testSupportedExtensionsAreCaseInsensitive() {
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/README.MD")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/spec.markdown")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/note.mdown")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/guide.PDF")))
        XCTAssertTrue(WorkspaceDocumentSupport.isPDFDocument(URL(fileURLWithPath: "/tmp/guide.pdf")))
        XCTAssertTrue(WorkspaceDocumentSupport.isMarkdownDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/image.png")))
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
            .appendingPathComponent("markprev-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
