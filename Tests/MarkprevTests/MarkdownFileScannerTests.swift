import Foundation
@testable import MarkprevCore
import XCTest

final class MarkdownFileScannerTests: XCTestCase {
    func testScannerBuildsMarkdownOnlyTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Readme", to: root.appendingPathComponent("README.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try write("- [x] Done", to: root.appendingPathComponent("Notes/Todo.markdown"))
        try write("not markdown", to: root.appendingPathComponent("Notes/image.png"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)

        let result = try MarkdownFileScanner().scan(rootURL: root)
        let relativePaths = result.files.map(\.relativePath).sorted()

        XCTAssertEqual(relativePaths, ["Notes/Todo.markdown", "README.md"])
        XCTAssertEqual(result.root.children?.map(\.name), ["Notes", "README.md"])
        XCTAssertEqual(result.root.children?.first?.children?.map(\.name), ["Todo.markdown"])
    }

    func testSupportedExtensionsAreCaseInsensitive() {
        XCTAssertTrue(MarkdownFileSupport.isMarkdownFile(URL(fileURLWithPath: "/tmp/README.MD")))
        XCTAssertTrue(MarkdownFileSupport.isMarkdownFile(URL(fileURLWithPath: "/tmp/spec.markdown")))
        XCTAssertTrue(MarkdownFileSupport.isMarkdownFile(URL(fileURLWithPath: "/tmp/note.mdown")))
        XCTAssertTrue(MarkdownFileSupport.isMarkdownFile(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertFalse(MarkdownFileSupport.isMarkdownFile(URL(fileURLWithPath: "/tmp/image.png")))
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

        let result = try MarkdownFileScanner().scan(rootURL: root)
        XCTAssertEqual(result.files.map(\.relativePath), ["Real/Real.md"])
        XCTAssertEqual(result.root.children?.map(\.name), ["Real"])
    }

    func testRelativePathFallsBackToFilenameOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/other/readme.md")

        XCTAssertEqual(MarkdownFileSupport.relativePath(for: outside, in: root), "readme.md")
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
