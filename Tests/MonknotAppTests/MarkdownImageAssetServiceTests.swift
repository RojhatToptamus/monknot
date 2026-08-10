import Foundation
import XCTest
@testable import MonknotApp

final class MarkdownImageAssetServiceTests: XCTestCase {
    func testSaveCreatesVisibleRootAssetsFolderAndNestedRelativeLink() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let notes = workspace.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let document = notes.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        let png = Data([0x89, 0x50, 0x4e, 0x47])

        let asset = try MarkdownImageAssetService.savePNG(
            png,
            workspaceURL: workspace,
            markdownDocumentURL: document
        )

        XCTAssertEqual(asset.fileURL.deletingLastPathComponent(), workspace.appendingPathComponent("assets"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("assets").path))
        XCTAssertEqual(asset.relativePath.split(separator: "/").prefix(2), ["..", "assets"])
        XCTAssertEqual(try Data(contentsOf: asset.fileURL), png)
        XCTAssertEqual(asset.markdown, "![Pasted image](\(asset.relativePath))")
    }

    func testSaveRejectsEmptyDataAndAssetsSymlinkEscape() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MarkdownImageAssetService.savePNG(
            Data(),
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))

        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("assets"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try MarkdownImageAssetService.savePNG(
            Data([1, 2, 3]),
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testUncommittedAssetCleanupIsWorkspaceBounded() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let document = workspace.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        let asset = try MarkdownImageAssetService.savePNG(
            Data([1, 2, 3]),
            workspaceURL: workspace,
            markdownDocumentURL: document
        )

        MarkdownImageAssetService.removeUncommittedAsset(asset, workspaceURL: workspace)

        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("assets").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownImageAssetServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
