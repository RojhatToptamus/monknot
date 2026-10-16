import AVFoundation
import UniformTypeIdentifiers
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

    func testAvailableCopyURLKeepsFolderNamesWholeAndExtensionsLast() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["v1.2", "photo.png", "Release.app", "Makefile"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("v1.2 copy"),
            withIntermediateDirectories: true
        )

        func copyName(_ name: String, isDirectory: Bool) -> String {
            WorkspaceDocumentSupport.availableCopyURL(named: name, isDirectory: isDirectory, in: root)
                .lastPathComponent
        }
        XCTAssertEqual(copyName("v1.2", isDirectory: true), "v1.2 copy 2")
        XCTAssertEqual(copyName("photo.png", isDirectory: false), "photo copy.png")
        XCTAssertEqual(copyName("Release.app", isDirectory: true), "Release copy.app")
        XCTAssertEqual(copyName("Makefile", isDirectory: false), "Makefile copy")
        XCTAssertEqual(copyName("new.md", isDirectory: false), "new.md")
    }

    func testIsURLContainedInComparesWholePathComponents() {
        let root = URL(fileURLWithPath: "/tmp/Work")
        XCTAssertTrue(WorkspaceDocumentSupport.isURL(root, containedIn: root))
        XCTAssertTrue(WorkspaceDocumentSupport.isURL(URL(fileURLWithPath: "/tmp/Work/a/b.md"), containedIn: root))
        XCTAssertFalse(WorkspaceDocumentSupport.isURL(URL(fileURLWithPath: "/tmp/Workshop/b.md"), containedIn: root))
        XCTAssertFalse(WorkspaceDocumentSupport.isURL(URL(fileURLWithPath: "/tmp"), containedIn: root))
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
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertTrue(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/sound.M4A")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/movie.AVI")))
        XCTAssertTrue(WorkspaceDocumentSupport.isPDFDocument(URL(fileURLWithPath: "/tmp/guide.pdf")))
        XCTAssertTrue(WorkspaceDocumentSupport.isMarkdownDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertFalse(WorkspaceDocumentSupport.isWorkspaceDocument(URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/diagram.mmd"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertTrue(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/preview.html"), rootURL: URL(fileURLWithPath: "/tmp")).capabilities.canPreviewHTML)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/Makefile"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .text)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/image.png"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .image)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/movie.mp4"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .media)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/movie.avi"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
        XCTAssertEqual(WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/archive.zip"), rootURL: URL(fileURLWithPath: "/tmp")).kind, .unsupported)
    }

    func testWorkspaceScanGateSkipsKnownUnsupportedExtensionsBeforeDocumentCreation() {
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/README.md")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/Guide.PDF")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/Makefile")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/movie.avi")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/movie.mkv")))
        XCTAssertFalse(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(URL(fileURLWithPath: "/tmp/movie.webm")))
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
        XCTAssertTrue(image.capabilities.canPreview)
        XCTAssertFalse(image.capabilities.canEditText)
        XCTAssertFalse(image.capabilities.canSearchText)
        XCTAssertFalse(image.capabilities.canSearchPDF)
        XCTAssertFalse(image.hasPreviewMode, "Images have one view, so the Source/Preview control stays disabled")
        XCTAssertTrue(media.capabilities.canPreview)
        XCTAssertFalse(media.capabilities.canEditText)
        XCTAssertFalse(media.capabilities.canSearchText)
        XCTAssertFalse(media.capabilities.canSearchPDF)
        XCTAssertFalse(media.hasPreviewMode, "Media has one view, so the Source/Preview control stays disabled")
        XCTAssertFalse(archive.capabilities.canPreview)
    }

    func testRasterImagesAreImageDocumentsAndSVGStaysEditableSource() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["photo.JPG", "photo.jpeg", "shot.png", "anim.gif", "live.heic", "scan.tiff", "pic.webp", "icon.ico", "a.avif", "b.bmp"] {
            let url = root.appendingPathComponent(name)
            XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(url), name)
            XCTAssertEqual(WorkspaceDocument(url: url, rootURL: root).kind, .image, name)
            XCTAssertTrue(WorkspaceDocumentKind.image.opensInPDFViewer)
        }

        let svg = WorkspaceDocument(url: root.appendingPathComponent("logo.svg"), rootURL: root)
        XCTAssertEqual(svg.kind, .text, "An SVG is markup; its source is what you edit")
        XCTAssertTrue(svg.capabilities.canEditText)
    }

    func testVideoAndAudioThatAVFoundationPlaysAreMediaDocuments() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let playableTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        for fileExtension in WorkspaceDocumentSupport.mediaExtensions {
            for name in ["clip.\(fileExtension)", "CLIP.\(fileExtension.uppercased())"] {
                let url = root.appendingPathComponent(name)
                let document = WorkspaceDocument(url: url, rootURL: root)
                XCTAssertTrue(WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(url), name)
                XCTAssertEqual(document.kind, .media, name)
                XCTAssertFalse(document.kind.opensInPDFViewer, name)
                let contentType = document.contentTypeIdentifier.flatMap(UTType.init)
                XCTAssertTrue(
                    contentType.map { playableTypes.contains($0.identifier) } == true,
                    "\(name) must be a type AVFoundation plays"
                )
                XCTAssertTrue(contentType?.conforms(to: .audiovisualContent) == true, name)
            }
        }

        // TypeScript keeps its extension, which UTType also reads as an MPEG-2 transport stream.
        XCTAssertEqual(WorkspaceDocument(url: root.appendingPathComponent("app.ts"), rootURL: root).kind, .text)
        for skipped in ["clip.avi", "clip.mkv", "clip.webm", "clip.ogg", "clip.wmv"] {
            XCTAssertNil(
                WorkspaceDocumentSupport.workspaceClassification(for: root.appendingPathComponent(skipped)),
                skipped
            )
        }
    }

    func testExtensionlessFilesAreTextOnlyByConventionalName() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["LICENSE", "License", "README", "CHANGELOG", "AUTHORS", "NOTICE", "COPYING", "Makefile", "Dockerfile"] {
            let classification = WorkspaceDocumentSupport.workspaceClassification(for: root.appendingPathComponent(name))
            XCTAssertEqual(classification?.kind, .text, name)
            XCTAssertEqual(classification?.capabilities.canEditText, true, name)
        }
        for name in ["data", "a.out", "Icon"] {
            XCTAssertNil(WorkspaceDocumentSupport.workspaceClassification(for: root.appendingPathComponent(name)), name)
        }
    }

    func testUppercaseExtensionsClassifyLikeLowercaseOnes() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["photo.png", "notes.md", "guide.pdf", "page.html", "data.json", "clip.mov", "song.mp3", "app.swift", "logo.svg"] {
            let lower = WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root)
            let upper = WorkspaceDocument(url: root.appendingPathComponent(name.uppercased()), rootURL: root)
            XCTAssertEqual(upper.kind, lower.kind, name)
            XCTAssertEqual(upper.capabilities, lower.capabilities, name)
            XCTAssertEqual(upper.contentTypeIdentifier, lower.contentTypeIdentifier, name)
        }
    }

    func testRelativePathFallsBackToFilenameOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/other/readme.md")

        XCTAssertEqual(WorkspaceDocumentSupport.relativePath(for: outside, in: root), "readme.md")
    }
}
