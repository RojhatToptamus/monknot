import Foundation
@testable import MonknotCore
import XCTest

final class WorkspaceDocumentScannerTests: XCTestCase {
    func testScannerBuildsWorkspaceFileTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Readme", to: root.appendingPathComponent("README.md"))
        try write("%PDF-1.7", to: root.appendingPathComponent("Guide.pdf"))
        try write("not a movie", to: root.appendingPathComponent("Clip.mp4"))
        try write("media", to: root.appendingPathComponent("Clip.avi"))
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

        XCTAssertEqual(relativePaths, ["Clip.mp4", "Guide.pdf", "Makefile", "Notes.txt", "Notes/Todo.markdown", "Notes/image.png", "Preview.html", "README.md", "diagram.mmd"])
        XCTAssertEqual(
            result.documents.first(where: { $0.displayName == "Clip.mp4" })?.kind,
            .media,
            "Media is listed by its extension; the scan never reads the file"
        )
        XCTAssertNil(result.documents.first(where: { $0.displayName == "Clip.avi" }))
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Guide.pdf" })?.kind, .pdf)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "README.md" })?.kind, .markdown)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Notes.txt" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Preview.html" })?.capabilities.canPreviewHTML, true)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "diagram.mmd" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "Makefile" })?.kind, .text)
        XCTAssertEqual(result.documents.first(where: { $0.displayName == "image.png" })?.kind, .image)
        XCTAssertNil(result.documents.first(where: { $0.displayName == "archive.zip" }))
        XCTAssertEqual(result.root.children?.map(\.name), ["Empty", "Notes", "Clip.mp4", "diagram.mmd", "Guide.pdf", "Makefile", "Notes.txt", "Preview.html", "README.md"])
        XCTAssertEqual(result.root.children?.first(where: { $0.name == "Notes" })?.children?.map(\.name), ["image.png", "Todo.markdown"])
    }

    func testNodeLookupFindsFoldersAndFilesByPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for folder in ["Notes/Deep", "Notes Archive"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("# A", to: root.appendingPathComponent("Notes/Deep/a.md"))
        try write("# B", to: root.appendingPathComponent("Notes Archive/b.md"))

        let tree = try WorkspaceDocumentScanner().scan(rootURL: root).root
        let notes = root.appendingPathComponent("Notes").standardizedFileURL.path

        XCTAssertEqual(tree.node(withID: tree.id)?.id, tree.id)
        XCTAssertEqual(tree.node(withID: notes)?.kind, .folder)
        XCTAssertEqual(tree.node(withID: notes + "/Deep")?.name, "Deep")
        XCTAssertEqual(tree.node(withID: notes + "/Deep/a.md")?.kind, .file)
        XCTAssertEqual(tree.node(withID: notes + " Archive/b.md")?.name, "b.md")
        XCTAssertNil(tree.node(withID: notes + "/Missing"))
        XCTAssertNil(tree.node(withID: "/elsewhere/Notes"))
    }

    /// A folder named like a package is skipped by the scan, so the name check reports it hidden.
    func testPackageNamedFoldersAreHiddenLikeTheScanSkipsThem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["Release.app", "X.bundle", "Notes.rtfd", "Folder", "v1.2", "Kit.framework"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("# Inside", to: folder.appendingPathComponent("Inside.md"))
        }

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        let listed = Set(result.root.children?.map(\.name) ?? [])
        for name in ["Release.app", "X.bundle", "Notes.rtfd", "Folder", "v1.2", "Kit.framework"] {
            XCTAssertEqual(
                WorkspaceDocumentScanner.hidesItem(named: name, isDirectory: true),
                !listed.contains(name),
                name
            )
        }
        XCTAssertEqual(listed, ["Folder", "v1.2", "Kit.framework"])
        XCTAssertFalse(WorkspaceDocumentScanner.hidesItem(named: "Release.app.md", isDirectory: false))
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
