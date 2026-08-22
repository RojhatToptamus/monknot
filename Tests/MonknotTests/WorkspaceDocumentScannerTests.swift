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

        XCTAssertEqual(relativePaths, ["Guide.pdf", "Makefile", "Notes.txt", "Notes/Todo.markdown", "Preview.html", "README.md", "diagram.mmd"])
        XCTAssertNil(result.documents.first(where: { $0.displayName == "Clip.mp4" }))
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Guide.pdf" })?.kind, .pdf)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "README.md" })?.kind, .markdown)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Notes.txt" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.capabilities.canPreviewHTML, true)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "diagram.mmd" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Makefile" })?.kind, .text)
        XCTAssertNil(result.documents.first(where: { $0.displayName == "image.png" }))
        XCTAssertNil(result.documents.first(where: { $0.displayName == "archive.zip" }))
        XCTAssertEqual(result.root.children?.map(\.name), ["Empty", "Notes", "diagram.mmd", "Guide.pdf", "Makefile", "Notes.txt", "Preview.html", "README.md"])
        XCTAssertEqual(result.root.children?.first(where: { $0.name == "Notes" })?.children?.map(\.name), ["Todo.markdown"])
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

    func testScannerSkipsSymbolicLinkFiles() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideFile = outside.appendingPathComponent("Outside.md")
        try write("# Outside", to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked.md"),
            withDestinationURL: outsideFile
        )

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.root.children?.isEmpty == true)
    }

    func testScannerChecksTaskCancellation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<120 {
            let directory = root.appendingPathComponent("Folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write("needle \(index)", to: directory.appendingPathComponent("note.md"))
        }

        let task = Task {
            await Task.yield()
            _ = try WorkspaceDocumentScanner().scan(rootURL: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected workspace scan to throw CancellationError")
        } catch is CancellationError {
        }
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
