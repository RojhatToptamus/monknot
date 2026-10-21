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

    func testAvailableCopyURLShortensALongNameToFitTheSuffix() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = WorkspaceDocumentSupport.maximumFileNameLength
        // Hangul syllables (3 code units each once decomposed) and an emoji (2), so a cut by code
        // unit could split either.
        let file = String(repeating: "한", count: 82) + "📄.md"
        let folder = String(repeating: "f", count: limit)
        for name in [file, folder] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let fileCopy = WorkspaceDocumentSupport.availableCopyURL(named: file, isDirectory: false, in: root)
            .lastPathComponent
        XCTAssertEqual(WorkspaceDocumentSupport.fileNameLength(fileCopy), 254)
        XCTAssertLessThanOrEqual(WorkspaceDocumentSupport.fileNameLength(fileCopy), limit)
        XCTAssertTrue(fileCopy.hasSuffix("한 copy.md"), fileCopy)
        XCTAssertTrue(fileCopy.hasPrefix("한한"), fileCopy)

        let folderCopy = WorkspaceDocumentSupport.availableCopyURL(named: folder, isDirectory: true, in: root)
            .lastPathComponent
        XCTAssertEqual(folderCopy, String(repeating: "f", count: limit - 5) + " copy")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(folderCopy),
            withIntermediateDirectories: true
        )
        let secondCopy = WorkspaceDocumentSupport.availableCopyURL(named: folder, isDirectory: true, in: root)
            .lastPathComponent
        XCTAssertEqual(secondCopy, String(repeating: "f", count: limit - 7) + " copy 2")
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
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        func kind(_ name: String) -> WorkspaceDocumentKind {
            WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root).kind
        }
        for name in ["README.MD", "spec.markdown", "note.mdown", "doc.mkd"] {
            XCTAssertEqual(kind(name), .markdown, name)
        }
        for name in ["diagram.MMD", "Makefile", "notes.TXT", "Preview.HTML"] {
            XCTAssertEqual(kind(name), .text, name)
        }
        XCTAssertEqual(kind("guide.PDF"), .pdf)
        XCTAssertEqual(kind("image.PNG"), .image)
        XCTAssertEqual(kind("movie.MP4"), .media)
        XCTAssertEqual(kind("sound.M4A"), .media)
        XCTAssertEqual(kind("movie.AVI"), .unsupported)
        XCTAssertEqual(kind("archive.ZIP"), .unsupported)
        XCTAssertTrue(WorkspaceDocumentSupport.isPDFDocument(URL(fileURLWithPath: "/tmp/guide.pdf")))
        XCTAssertTrue(WorkspaceDocumentSupport.isMarkdownDocument(URL(fileURLWithPath: "/tmp/doc.mkd")))
        XCTAssertTrue(WorkspaceDocument(url: root.appendingPathComponent("preview.html"), rootURL: root).capabilities.canPreviewHTML)
    }

    /// Every file is listed. Source formats the system does not know open as text; files the
    /// system knows as binary, and common undeclared binary formats, open in their own app and are
    /// never searched.
    func testEveryFileIsClassifiedAsTextOrAsOpeningInItsOwnApp() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["init.lua", "App.vue", "Card.svelte", "main.dart", "Main.scala", "paper.tex", "refs.bib",
                     "index.rst", "Cargo.lock", "LICENSE-MIT", "Brewfile", "a.out", "Info.plist", "notes.final"] {
            let document = WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root)
            XCTAssertEqual(document.kind, .text, name)
            XCTAssertTrue(document.capabilities.canEditText, name)
            XCTAssertTrue(document.capabilities.canSearchText, name)
            XCTAssertFalse(document.hasPreviewMode, name)
        }
        for name in ["archive.zip", "report.docx", "sheet.xlsx", "clip.avi", "font.ttf", "tool.exe", "lib.dylib",
                     "module.pyc", "cache.sqlite", "font.woff2", "weights.safetensors", "data.parquet", "letter.rtf",
                     "libcore.rlib"] {
            let document = WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root)
            XCTAssertEqual(document.kind, .unsupported, name)
            XCTAssertFalse(document.capabilities.canEditText, name)
            XCTAssertFalse(document.capabilities.canSearchText, name)
            XCTAssertFalse(document.capabilities.canPreview, name)
        }
    }

    func testANotebookIsEditableJSONWithAPreview() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["analysis.ipynb", "Analysis.IPYNB"] {
            let notebook = WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root)
            XCTAssertEqual(notebook.kind, .text, name)
            XCTAssertTrue(notebook.capabilities.canPreviewNotebook, name)
            XCTAssertTrue(notebook.capabilities.canEditText, name)
            XCTAssertTrue(notebook.capabilities.canSearchText, name)
            XCTAssertTrue(notebook.hasPreviewMode, name)
            XCTAssertFalse(notebook.capabilities.canPreviewHTML, name)
        }
        XCTAssertFalse(WorkspaceDocument(url: root.appendingPathComponent("data.json"), rootURL: root).capabilities.canPreviewNotebook)
    }

    /// A kind an older build saved that no longer exists reads as a file that opens in its own
    /// app, so the open tabs saved with it still load.
    func testAKindSavedByAnOlderBuildStillDecodes() throws {
        let decoded = try JSONDecoder().decode([WorkspaceDocumentKind].self, from: Data(#"["markdown","nativePreview"]"#.utf8))
        XCTAssertEqual(decoded, [.markdown, .unsupported])
    }

    /// Capabilities saved before notebooks existed (open tabs, Recents) still decode.
    func testCapabilitiesSavedWithoutTheNotebookFlagDecode() throws {
        let saved = Data(#"{"canPreview":true,"canEditText":true,"canSearchText":true,"canSearchPDF":false,"canExportPDF":false,"canShowOutline":false,"canPreviewHTML":true}"#.utf8)
        let capabilities = try JSONDecoder().decode(WorkspaceDocumentCapabilities.self, from: saved)
        XCTAssertTrue(capabilities.canPreviewHTML)
        XCTAssertFalse(capabilities.canPreviewNotebook)
        let roundTrip = try JSONDecoder().decode(
            WorkspaceDocumentCapabilities.self,
            from: JSONEncoder().encode(capabilities)
        )
        XCTAssertEqual(roundTrip, capabilities)
    }

    /// Only the extension of a known file type counts as one: version numbers, release tags and
    /// names with a dot in them do not.
    func testOnlyAKnownFileTypeCountsAsAnExtension() {
        for pathExtension in ["md", "MD", "lua", "ipynb", "mp3", "7z", "docx", "plist", "rtf", "parquet"] {
            XCTAssertTrue(WorkspaceDocumentSupport.isKnownFileExtension(pathExtension), pathExtension)
        }
        for pathExtension in ["", "2", "0-beta", "1a", "0rc1", "Smith", "final", "xyz"] {
            XCTAssertFalse(WorkspaceDocumentSupport.isKnownFileExtension(pathExtension), pathExtension)
        }
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
        for unplayable in ["clip.avi", "clip.mkv", "clip.webm", "clip.ogg", "clip.wmv"] {
            XCTAssertEqual(
                WorkspaceDocument(url: root.appendingPathComponent(unplayable), rootURL: root).kind,
                .unsupported,
                unplayable
            )
        }
    }

    /// An extensionless file opens as text; the editor says so when its bytes are not text.
    func testExtensionlessFilesAreText() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        for name in ["LICENSE", "License", "README", "CHANGELOG", "AUTHORS", "NOTICE", "COPYING", "Makefile", "Dockerfile", "data", "Icon"] {
            let classification = WorkspaceDocumentSupport.classification(for: root.appendingPathComponent(name))
            XCTAssertEqual(classification.kind, .text, name)
            XCTAssertTrue(classification.capabilities.canEditText, name)
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
