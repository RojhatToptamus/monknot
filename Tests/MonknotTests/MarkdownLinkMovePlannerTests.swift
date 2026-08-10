import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownLinkMovePlannerTests: XCTestCase {
    func testCaseOnlyRenameIsAllowedOnlyWhenDestinationIsTheSameFilesystemItem() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.md")
        let targetURL = root.appendingPathComponent("Target.md")
        let destinationURL = root.appendingPathComponent("target.md")
        try "[target](Target.md)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)

        guard WorkspaceFileIdentity.isCaseOnlyRename(
            from: targetURL,
            to: destinationURL
        ) else {
            throw XCTSkip("The test volume is case-sensitive.")
        }

        let plan = try MarkdownLinkMovePlanner().plan(
            moving: targetURL,
            to: destinationURL,
            workspaceRootURL: root,
            documents: [
                WorkspaceDocument(url: sourceURL, rootURL: root),
                WorkspaceDocument(url: targetURL, rootURL: root),
            ]
        )

        XCTAssertEqual(plan.rewriteCount, 1)
        XCTAssertEqual(plan.rewriteFiles.first?.updatedText, "[target](target.md)\n")
    }

    func testExistingDifferentDestinationRemainsRejected() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.md")
        let destinationURL = root.appendingPathComponent("Destination.md")
        try "# Source\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "# Destination\n".write(to: destinationURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try MarkdownLinkMovePlanner().plan(
                moving: sourceURL,
                to: destinationURL,
                workspaceRootURL: root,
                documents: [WorkspaceDocument(url: sourceURL, rootURL: root)]
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownLinkMovePlannerError, .destinationExists)
        }
    }

    func testMovingTargetRewritesInboundLinksAndPreservesSuffix() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Notes/Source.md")
        let targetURL = root.appendingPathComponent("Reference.md")
        let destinationURL = root.appendingPathComponent("Renamed Reference.md")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "[paper](../Reference.md?mode=read#Heading)\n".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        try "# Heading\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let documents = [
            WorkspaceDocument(url: sourceURL, rootURL: root),
            WorkspaceDocument(url: targetURL, rootURL: root),
        ]

        let plan = try MarkdownLinkMovePlanner().plan(
            moving: targetURL,
            to: destinationURL,
            workspaceRootURL: root,
            documents: documents
        )

        XCTAssertEqual(plan.rewriteCount, 1)
        XCTAssertEqual(
            plan.rewriteFiles.first?.updatedText,
            "[paper](../Renamed%20Reference.md?mode=read#Heading)\n"
        )
    }

    func testMovingSourceRewritesOutgoingImageAndReferenceLinksButNotCode() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Notes/Source.md")
        let destinationURL = root.appendingPathComponent("Source.md")
        let assetsURL = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: assetsURL.appendingPathComponent("image.png"))
        try "![image](../assets/image.png)\n[asset]: ../assets/image.png\n`![code](../assets/image.png)`\n".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let documents = [WorkspaceDocument(url: sourceURL, rootURL: root)]

        let plan = try MarkdownLinkMovePlanner().plan(
            moving: sourceURL,
            to: destinationURL,
            workspaceRootURL: root,
            documents: documents
        )

        XCTAssertEqual(plan.rewriteCount, 2)
        XCTAssertEqual(
            plan.rewriteFiles.first?.updatedText,
            "![image](assets/image.png)\n[asset]: assets/image.png\n`![code](../assets/image.png)`\n"
        )
    }

    func testMovingMarkdownFilePreservesSameDocumentHeadingLinks() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Notes/Source.md")
        let destinationURL = root.appendingPathComponent("Archive/Source.md")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = "# Heading\n[Markdown](#Heading)\n[[#Heading]]\n"
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = try MarkdownLinkMovePlanner().plan(
            moving: sourceURL,
            to: destinationURL,
            workspaceRootURL: root,
            documents: [WorkspaceDocument(url: sourceURL, rootURL: root)]
        )

        XCTAssertEqual(plan.rewriteCount, 0)
        XCTAssertTrue(plan.rewriteFiles.isEmpty)
    }

    func testPlanCapturesAllMarkdownRevisionsForCommitRevalidation() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("First.md")
        let secondURL = root.appendingPathComponent("Second.md")
        try "[second](Second.md)\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: secondURL, atomically: true, encoding: .utf8)
        let documents = [
            WorkspaceDocument(url: firstURL, rootURL: root),
            WorkspaceDocument(url: secondURL, rootURL: root),
        ]

        let plan = try MarkdownLinkMovePlanner().plan(
            moving: secondURL,
            to: root.appendingPathComponent("Moved.md"),
            workspaceRootURL: root,
            documents: documents
        )

        XCTAssertEqual(plan.examinedFiles.count, 2)
        XCTAssertEqual(Set(plan.examinedFiles.map { $0.url.lastPathComponent }), ["First.md", "Second.md"])
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-link-move-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
