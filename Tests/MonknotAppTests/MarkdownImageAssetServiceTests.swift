import AppKit
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

    func testExternalWebImagesKeepTheirBytesAndOtherImagesBecomePNG() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        let photo = outside.appendingPathComponent("Photo one.jpg")
        let scan = outside.appendingPathComponent("Scan.tiff")
        try jpeg.write(to: photo)
        try tiff.write(to: scan)

        let plan = try MarkdownImageAssetService.planFileDrop(
            [photo, scan],
            workspaceURL: workspace,
            markdownDocumentURL: document
        )
        let result = try MarkdownImageAssetService.importFileDrop(plan)

        XCTAssertEqual(result.importedAssets.map(\.fileURL.lastPathComponent), ["Photo one.jpg", "Scan.png"])
        XCTAssertEqual(try Data(contentsOf: result.importedAssets[0].fileURL), jpeg)
        let converted = try Data(contentsOf: result.importedAssets[1].fileURL)
        XCTAssertEqual(Array(converted.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
        XCTAssertEqual(result.markdown, "![Photo one](assets/Photo%20one.jpg)\n![Scan](assets/Scan.png)")
    }

    func testOnlyFormatsEveryBrowserShowsKeepTheirOriginalBytes() {
        for name in ["photo.jpg", "photo.JPEG", "chart.png", "loop.gif", "shot.webp", "logo.svg"] {
            XCTAssertTrue(MarkdownImageAssetService.keepsOriginalImageFormat(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["photo.heic", "scan.tiff", "old.bmp", "no-extension"] {
            XCTAssertFalse(MarkdownImageAssetService.keepsOriginalImageFormat(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    /// A note takes any file dropped on it as a File block, binary ones too, as the sidebar lists
    /// them; folders, aliases and hidden files are refused, and nothing is copied while planning.
    func testDropRejectsFoldersSymlinksAndHiddenFilesWithoutCreatingAssets() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = workspace.appendingPathComponent("Draft.md")
        let hidden = outside.appendingPathComponent(".env")
        let binary = outside.appendingPathComponent("archive.bin")
        let symlink = outside.appendingPathComponent("alias.txt")
        try "# Draft\n".write(to: document, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: hidden)
        try Data([1, 2, 3]).write(to: binary)
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
            [hidden],
            workspaceURL: workspace,
            markdownDocumentURL: document
        ))
        let plan = try MarkdownImageAssetService.planFileDrop(
            [binary],
            workspaceURL: workspace,
            markdownDocumentURL: document
        )
        XCTAssertEqual(plan.items.map(\.sourceURL.lastPathComponent), ["archive.bin"])
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
