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

    func testInternalDropBuildsSafeRelativeLinksWithoutCopyingFiles() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let notes = workspace.appendingPathComponent("notes", isDirectory: true)
        let reference = workspace.appendingPathComponent("Référence (final).md")
        let image = workspace.appendingPathComponent("diagram image.png")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let document = notes.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        try "# Référence\n".write(to: reference, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: image)

        let plan = try MarkdownImageAssetService.planFileDrop(
            [reference, image],
            workspaceURL: workspace,
            markdownDocumentURL: document
        )
        let result = try MarkdownImageAssetService.importFileDrop(plan)

        XCTAssertFalse(plan.requiresImportConfirmation)
        XCTAssertEqual(result.importedAssets, [])
        XCTAssertEqual(
            result.markdown,
            "[Référence \\(final\\)](../R%C3%A9f%C3%A9rence%20%28final%29.md)\n" +
                "![diagram image](../diagram%20image.png)"
        )
        XCTAssertEqual(try String(contentsOf: reference, encoding: .utf8), "# Référence\n")
    }

    func testExternalDropPlansBeforeCopyAndImportsMultipleFilesWithCollisions() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let sourceA = container.appendingPathComponent("source-a", isDirectory: true)
        let sourceB = container.appendingPathComponent("source-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        let first = sourceA.appendingPathComponent("Guide.txt")
        let second = sourceB.appendingPathComponent("Guide.txt")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        let plan = try MarkdownImageAssetService.planFileDrop(
            [first, second],
            workspaceURL: workspace,
            markdownDocumentURL: document
        )

        XCTAssertTrue(plan.requiresImportConfirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("assets").path))

        let result = try MarkdownImageAssetService.importFileDrop(plan)

        XCTAssertEqual(result.importedAssets.map(\.fileURL.lastPathComponent), ["Guide.txt", "Guide copy.txt"])
        XCTAssertEqual(result.markdown, "[Guide](assets/Guide.txt)\n[Guide copy](assets/Guide%20copy.txt)")
        XCTAssertEqual(try String(contentsOf: result.importedAssets[0].fileURL, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: result.importedAssets[1].fileURL, encoding: .utf8), "second")

        MarkdownImageAssetService.removeUncommittedAssets(result.importedAssets, workspaceURL: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.importedAssets[0].fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.importedAssets[1].fileURL.path))
    }

    func testDropRejectsFoldersSymlinksAndUnsupportedFilesWithoutCreatingAssets() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        let unsupported = outside.appendingPathComponent("archive.bin")
        let symlink = outside.appendingPathComponent("alias.txt")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: unsupported)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: document)

        XCTAssertThrowsError(try MarkdownImageAssetService.planFileDrop(
            [outside],
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))
        XCTAssertThrowsError(try MarkdownImageAssetService.planFileDrop(
            [symlink],
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))
        XCTAssertThrowsError(try MarkdownImageAssetService.planFileDrop(
            [unsupported],
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("assets").path))
    }

    func testMultiFileImportRollsBackEarlierCopiesWhenLaterImageFails() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        let valid = outside.appendingPathComponent("Guide.txt")
        let invalidImage = outside.appendingPathComponent("Broken.png")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        try "guide".write(to: valid, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: invalidImage)
        let plan = try MarkdownImageAssetService.planFileDrop(
            [valid, invalidImage],
            workspaceURL: workspace,
            markdownDocumentURL: document
        )

        XCTAssertThrowsError(try MarkdownImageAssetService.importFileDrop(plan))

        let assets = workspace.appendingPathComponent("assets", isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? [], [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownImageAssetServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
