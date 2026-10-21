import AVKit
import AppKit
import ImageIO
import MonknotCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import MonknotApp

/// Every file type Monknot lists opens in its own viewer from a real file on disk: text in the
/// editor, PDFs and images in the PDF viewer, video and audio in the player, and anything that
/// cannot be shown explains why instead of showing garbage.
@MainActor
final class DocumentViewerRoutingTests: WorkspaceStoreTestCase {
    private enum Viewer: Equatable {
        case text(String)
        case pdf
        /// The page size an image opens at, upright.
        case image(CGSize)
        case brokenImage
        case media
        case brokenMedia
        case loadFailure(containing: String)
        /// A file Monknot lists but does not show: it opens in another app.
        case otherApp
    }

    private struct Fixture {
        let name: String
        let kind: WorkspaceDocumentKind
        let viewer: Viewer
    }

    private var hostWindows: [NSWindow] = []

    override func tearDown() async throws {
        for window in hostWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostWindows.removeAll()
        try await super.tearDown()
    }

    // MARK: - Scanning

    func testEveryFileTypeIsListedWithItsKind() async throws {
        let (root, fixtures) = try await makeWorkspace()

        let result = try WorkspaceDocumentScanner().scan(rootURL: root)
        let listed = Dictionary(uniqueKeysWithValues: result.documents.map { ($0.displayName, $0.kind) })

        XCTAssertEqual(
            listed,
            Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.kind) }),
            "Unexpected listing: \(listed.keys.sorted())"
        )
        XCTAssertEqual(listed["clip.avi"], .unsupported, "AVI is not a format AVFoundation reliably plays")
        XCTAssertNil(listed[".env"], "Hidden files stay hidden")
    }

    // MARK: - Opening

    func testEachFileOpensInItsViewerWithoutError() async throws {
        let (root, fixtures) = try await makeWorkspace()
        let store = try await openStore(root)
        let host = hostEditorPane(store: store)

        for fixture in fixtures {
            let document = try XCTUnwrap(
                store.documents.first { $0.displayName == fixture.name },
                fixture.name
            )
            XCTAssertTrue(store.selectDocument(id: document.id), fixture.name)
            try await assertViewer(fixture.viewer, for: document, store: store, host: host)
        }
    }

    private func assertViewer(
        _ viewer: Viewer,
        for document: WorkspaceDocument,
        store: WorkspaceStore,
        host: NSView
    ) async throws {
        let name = document.displayName
        switch viewer {
        case .text(let expected):
            let shown = await waitUntil {
                !store.isDocumentLoading
                    && store.documentLoadFailure == nil
                    && self.documentTextView(in: host)?.string == expected
            }
            XCTAssertTrue(shown, "\(name) did not open its text in the editor: \(store.documentLoadFailure?.message ?? "")")
            XCTAssertNil(firstDescendant(of: PDFView.self, in: host), name)
            XCTAssertNil(firstDescendant(of: MediaPlayerNSView.self, in: host), name)
        case .loadFailure(let fragment):
            let failed = await waitUntil { store.documentLoadFailure?.documentID == document.id }
            XCTAssertTrue(failed, "\(name) should explain why it cannot open")
            XCTAssertTrue(
                store.documentLoadFailure?.message.contains(fragment) == true,
                "\(name): \(store.documentLoadFailure?.message ?? "no message")"
            )
            let editorClosed = await waitUntil { self.documentTextView(in: host) == nil }
            XCTAssertTrue(editorClosed, "\(name) must not show its bytes in the editor")
            XCTAssertNil(store.recentDocuments().first { $0.documentID == document.id })
        case .pdf:
            let shown = await waitUntil { self.pdfView(in: host)?.document?.pageCount == 1 }
            XCTAssertTrue(shown, "\(name) did not open in the PDF viewer")
            XCTAssertFalse(pdfView(in: host)?.document?.page(at: 0) is ImageMarkupPage, name)
        case .image(let pageSize):
            let shown = await waitUntil {
                (self.pdfView(in: host)?.document?.page(at: 0) as? ImageMarkupPage)?
                    .bounds(for: .mediaBox).size == pageSize
            }
            let page = pdfView(in: host)?.document?.page(at: 0)
            XCTAssertTrue(
                shown,
                "\(name) did not open upright in the image viewer: \(String(describing: page?.bounds(for: .mediaBox)))"
            )
        case .brokenImage:
            let settled = await waitUntil {
                self.pdfView(in: host) != nil && self.pdfView(in: host)?.document == nil
            }
            XCTAssertTrue(settled, "\(name) should open the image viewer's failure state")
            XCTAssertNil(store.documentLoadFailure, name)
        case .media:
            let ready = await waitUntil(timeout: 10) {
                self.playerView(in: host)?.player?.currentItem?.status == .readyToPlay
            }
            XCTAssertTrue(
                ready,
                "\(name) did not become playable: \(String(describing: playerView(in: host)?.player?.currentItem?.error))"
            )
            XCTAssertEqual(playerView(in: host)?.player?.rate, 0, "\(name) must not play on its own")
            XCTAssertNil(documentTextView(in: host), name)
        case .brokenMedia:
            let failed = await waitUntil(timeout: 10) {
                self.playerView(in: host)?.player?.currentItem?.status == .failed
            }
            XCTAssertTrue(failed, "\(name) should open the player's failure state")
        case .otherApp:
            let settled = await waitUntil {
                store.selectedDocumentID == document.id
                    && self.documentTextView(in: host) == nil
                    && self.pdfView(in: host) == nil
                    && self.playerView(in: host) == nil
            }
            XCTAssertTrue(settled, "\(name) must not mount a viewer")
            XCTAssertNil(store.documentLoadFailure, name)
            XCTAssertFalse(store.isDocumentLoading, name)
            XCTAssertNil(firstDescendant(of: WKWebView.self, in: host), name)
        }
    }

    // MARK: - Media lifecycle

    func testTheMediaPlayerNeverAutoplaysAndSpaceTogglesPlayback() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotMediaPlayer")
        try await DocumentFileTypeFixtures.writeMovie(to: root.appendingPathComponent("clip.mov"))
        let store = try await openStore(root)
        let host = hostEditorPane(store: store)
        let clip = try XCTUnwrap(store.documents.first { $0.displayName == "clip.mov" })

        store.selectDocument(id: clip.id)
        let ready = await waitUntil(timeout: 10) {
            self.playerView(in: host)?.player?.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(ready)
        let playerView = try XCTUnwrap(self.playerView(in: host))
        let player = try XCTUnwrap(playerView.player)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(playerView.acceptsFirstResponder)
        XCTAssertEqual(playerView.identifier, .monknotDocumentFocusTarget)
        XCTAssertEqual(playerView.controlsStyle, .inline)

        // The 2:1 movie spans the 800-point pane at its own proportions; the surface shows above
        // and below it instead of letterbox bars.
        let fitted = await waitUntil {
            abs(playerView.frame.width - 800) < 1 && abs(playerView.frame.height - 400) < 1
        }
        XCTAssertTrue(fitted, "Player frame: \(playerView.frame)")

        playerView.keyDown(with: try keyEvent(" ", in: playerView))
        XCTAssertNotEqual(player.rate, 0, "Space plays")
        playerView.keyDown(with: try keyEvent(" ", in: playerView))
        XCTAssertEqual(player.rate, 0, "Space pauses")
    }

    func testSwitchingTabsStopsThePlayerAndReleasesTheFile() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotMediaSwitch")
        try await DocumentFileTypeFixtures.writeMovie(to: root.appendingPathComponent("clip.mov"))
        try DocumentFileTypeFixtures.writeWAV(to: root.appendingPathComponent("tone.wav"))
        try "# Note\n".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let store = try await openStore(root)
        let host = hostEditorPane(store: store)
        func document(_ name: String) throws -> WorkspaceDocument {
            try XCTUnwrap(store.documents.first { $0.displayName == name })
        }

        // Only weak references: a player that outlives its tab is a leak, and it could still sound.
        store.selectDocument(id: try document("clip.mov").id)
        _ = await waitUntil { self.playerView(in: host)?.player?.currentItem?.status == .readyToPlay }
        weak let moviePlayerView = playerView(in: host)
        weak let moviePlayer = moviePlayerView?.player
        moviePlayer?.play()
        let moviePlays = await waitUntil { moviePlayer?.timeControlStatus == .playing }
        XCTAssertTrue(moviePlays)

        store.selectDocument(id: try document("tone.wav").id)
        let switched = await waitUntil {
            self.playerView(in: host)?.player?.currentItem?.status == .readyToPlay
                && self.playerView(in: host) !== moviePlayerView
        }
        XCTAssertTrue(switched, "Each media document gets its own player")
        let movieReleased = await waitUntil { moviePlayer == nil }
        XCTAssertTrue(movieReleased, "The hidden movie's player is released with its file")

        weak let audioPlayer = playerView(in: host)?.player
        audioPlayer?.play()
        let audioPlays = await waitUntil { audioPlayer?.timeControlStatus == .playing }
        XCTAssertTrue(audioPlays)
        store.selectDocument(id: try document("Note.md").id)
        let showedNote = await waitUntil { self.playerView(in: host) == nil }
        XCTAssertTrue(showedNote)
        let audioReleased = await waitUntil { audioPlayer == nil }
        XCTAssertTrue(audioReleased, "Sound never continues behind another document")
    }

    func testClosingTheWindowStopsPlayback() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotMediaClose")
        try DocumentFileTypeFixtures.writeWAV(to: root.appendingPathComponent("tone.wav"))
        let document = WorkspaceDocument(url: root.appendingPathComponent("tone.wav"), rootURL: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MediaPlayerView(document: document, theme: .defaultDark, zoomScale: 1))
        host.frame = window.contentLayoutRect
        window.contentView = host
        window.orderFront(nil)
        hostWindows.append(window)

        let ready = await waitUntil(timeout: 10) {
            self.playerView(in: host)?.player?.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(ready)
        let player = try XCTUnwrap(playerView(in: host)?.player)
        XCTAssertEqual(
            playerView(in: host)?.frame.size,
            CGSize(
                width: MonknotMetrics.scale(360, theme: .defaultDark, zoomScale: 1),
                height: MonknotMetrics.scale(MediaPlayerView.audioControlsHeight, theme: .defaultDark, zoomScale: 1)
            ),
            "Audio shows only the player's control bar"
        )
        player.play()
        let plays = await waitUntil { player.timeControlStatus == .playing }
        XCTAssertTrue(plays)

        window.close()
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.timeControlStatus, .paused)
    }

    func testAMissingMediaFileShowsTheFailureState() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotMediaMissing")
        let document = WorkspaceDocument(url: root.appendingPathComponent("gone.mp3"), rootURL: root)
        let host = hostView(MediaPlayerView(document: document, theme: .defaultLight, zoomScale: 1))

        let failed = await waitUntil(timeout: 10) {
            self.playerView(in: host)?.player?.currentItem?.status == .failed
        }
        XCTAssertTrue(failed)
    }

    /// Finder's Open With opens the file's folder with the file selected, whatever its type; a
    /// hidden file, which the sidebar does not list, says so instead of opening nothing.
    func testOpenWithSelectsMediaAndNamesFilesItCannotOpen() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotOpenWith")
        try DocumentFileTypeFixtures.writeWAV(to: root.appendingPathComponent("tone.wav"))
        try "# Note\n".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try Data("RIFF".utf8).write(to: root.appendingPathComponent("clip.avi"))
        try Data("SECRET=1\n".utf8).write(to: root.appendingPathComponent(".env"))

        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: root.appendingPathComponent("tone.wav"))
        let opened = await waitUntil { !store.isBusy && store.workspaceURL != nil }
        XCTAssertTrue(opened)
        XCTAssertEqual(store.selectedDocument?.displayName, "tone.wav")
        XCTAssertEqual(store.selectedDocument?.kind, .media)
        XCTAssertNil(store.errorMessage)

        store.openWorkspace(root, selecting: root.appendingPathComponent("clip.avi"))
        let listed = await waitUntil { !store.isBusy && store.selectedDocument?.displayName == "clip.avi" }
        XCTAssertTrue(listed)
        XCTAssertEqual(store.selectedDocument?.kind, .unsupported)
        XCTAssertNil(store.errorMessage)

        store.openWorkspace(root, selecting: root.appendingPathComponent(".env"))
        let refused = await waitUntil { !store.isBusy && store.errorMessage != nil }
        XCTAssertTrue(refused)
        XCTAssertEqual(store.errorMessage, "Monknot can't open “.env”.")
    }

    /// A notebook opens on its JSON in Source and shows its cells and outputs in Preview.
    func testANotebookShowsItsCellsInPreview() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotNotebook")
        try Self.notebookJSON.write(to: root.appendingPathComponent("analysis.ipynb"), atomically: true, encoding: .utf8)
        let store = try await openStore(root)
        let notebook = try XCTUnwrap(store.documents.first)
        XCTAssertTrue(notebook.hasPreviewMode)
        let host = hostView(EditorPaneHarness(store: store, editorMode: .preview))

        XCTAssertTrue(store.selectDocument(id: notebook.id))
        var shown = ""
        let rendered = await waitUntil(timeout: 10) {
            guard let webView = self.firstDescendant(of: WKWebView.self, in: host) else { return false }
            webView.evaluateJavaScript("document.getElementById('content')?.innerText ?? ''") { result, _ in
                shown = result as? String ?? ""
            }
            return shown.contains("Quarterly totals") && shown.contains("print(totals)") && shown.contains("42")
        }
        XCTAssertTrue(rendered, "Preview shows: \(shown)")
        XCTAssertNil(documentTextView(in: host), "Preview does not mount the JSON editor")
        XCTAssertFalse(shown.contains("cell_type"), "Preview shows the cells, not the JSON")
    }

    private static let notebookJSON = """
    {
     "cells": [
      {"cell_type": "markdown", "metadata": {}, "source": ["# Sales\\n", "Quarterly totals"]},
      {"cell_type": "code", "execution_count": 1, "metadata": {}, "source": ["print(totals)"],
       "outputs": [{"output_type": "stream", "name": "stdout", "text": ["42\\n"]}]}
     ],
     "metadata": {"kernelspec": {"language": "python", "name": "python3"}},
     "nbformat": 4,
     "nbformat_minor": 5
    }

    """

    func testOpenedMediaIsRecorded() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotMediaRecents")
        try DocumentFileTypeFixtures.writeWAV(to: root.appendingPathComponent("tone.wav"))
        try "# Note\n".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let store = try await openStore(root)
        let note = try XCTUnwrap(store.documents.first { $0.displayName == "Note.md" })
        let tone = try XCTUnwrap(store.documents.first { $0.displayName == "tone.wav" })

        store.selectDocument(id: note.id)
        store.selectDocument(id: tone.id)
        let recorded = await waitUntil { store.recentDocuments().contains { $0.documentID == tone.id } }
        XCTAssertTrue(recorded, "Recents list media like any other document")
    }

    // MARK: - Image fit

    func testImagesOpenWholeAndNeverAboveActualSize() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotImageFit")
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 4_000, height: 3_000)],
            as: .png,
            to: root.appendingPathComponent("huge.png")
        )
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 3, height: 2)],
            as: .png,
            to: root.appendingPathComponent("tiny.png")
        )
        let store = try await openStore(root)
        let host = hostEditorPane(store: store)

        for name in ["huge.png", "tiny.png", "huge.png"] {
            let image = try XCTUnwrap(store.documents.first { $0.displayName == name })
            store.selectDocument(id: image.id)
            let shown = await waitUntil {
                (self.pdfView(in: host)?.document?.page(at: 0) as? ImageMarkupPage)?
                    .bounds(for: .mediaBox).width == (name == "huge.png" ? 4_000 : 3)
            }
            XCTAssertTrue(shown, name)
            // The first image mounts the viewer, which fits it once laid out.
            _ = await waitUntil(timeout: 1) { (self.pdfView(in: host)?.scaleFactor ?? 1) < 1 || name != "huge.png" }
            let pdfView = try XCTUnwrap(self.pdfView(in: host))
            pdfView.layoutDocumentView()
            let page = try XCTUnwrap(pdfView.document?.page(at: 0))
            let pageRect = pdfView.convert(page.bounds(for: .mediaBox), from: page)

            XCTAssertLessThanOrEqual(pdfView.scaleFactor, 1, name)
            if name == "huge.png" {
                XCTAssertLessThan(pdfView.scaleFactor, 0.5, "\(name) opens whole")
                XCTAssertLessThanOrEqual(pageRect.width, pdfView.bounds.width, "\(name) opens whole")
                XCTAssertLessThanOrEqual(pageRect.height, pdfView.bounds.height, "\(name) opens whole")
            } else {
                XCTAssertEqual(pdfView.scaleFactor, 1, accuracy: 0.001, "\(name) opens at its actual size")
            }
        }
    }

    // MARK: - Fixtures

    private func makeWorkspace() async throws -> (URL, [Fixture]) {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotFileTypes")
        var fixtures: [Fixture] = []
        func text(_ name: String, _ contents: String, kind: WorkspaceDocumentKind = .text) throws {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
            fixtures.append(Fixture(name: name, kind: kind, viewer: .text(contents)))
        }
        func image(_ name: String, _ type: UTType, frames: Int = 1, properties: [CFString: Any] = [:], pageSize: CGSize = CGSize(width: 40, height: 20)) throws {
            let images = (0..<frames).map { DocumentFileTypeFixtures.image(width: 40, height: 20, seed: UInt8($0 * 90)) }
            try DocumentFileTypeFixtures.writeImage(images, as: type, to: root.appendingPathComponent(name), properties: properties)
            fixtures.append(Fixture(name: name, kind: .image, viewer: .image(pageSize)))
        }

        try text("Notes.MD", "# Notes\n\nUppercase extension.\n", kind: .markdown)
        try text("note.md", "# Note\n", kind: .markdown)
        try text("plain.txt", "plain text\n")
        try text("data.json", "{\"key\": [1, 2, 3]}\n")
        try text("table.csv", "a,b\n1,2\n")
        try text("page.html", "<h1>Hello</h1>\n")
        try text("config.yaml", "key: value\n")
        try text("main.swift", "print(\"hi\")\n")
        try text("logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"/>\n")
        try text("Makefile", "build:\n\ttrue\n")
        try text("Dockerfile", "FROM scratch\n")
        try text("LICENSE", "MIT License\n")
        try text("README", "Read me\n")
        try text("empty.txt", "")
        try text("init.lua", "local x = 1\n")
        try text("Brewfile", "brew \"git\"\n")
        try text("analysis.ipynb", Self.notebookJSON)

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        try pngBytes.write(to: root.appendingPathComponent("misnamed-png.txt"))
        fixtures.append(Fixture(name: "misnamed-png.txt", kind: .text, viewer: .loadFailure(containing: "not UTF-8")))
        try (Data("ELF".utf8) + Data(repeating: 0, count: 64)).write(to: root.appendingPathComponent("binary.txt"))
        fixtures.append(Fixture(name: "binary.txt", kind: .text, viewer: .loadFailure(containing: "binary data")))
        let line = Data(String(repeating: "large text line ", count: 4).utf8 + [0x0A])
        var large = Data(capacity: 20 * 1024 * 1024)
        while large.count < 20 * 1024 * 1024 { large.append(line) }
        try large.write(to: root.appendingPathComponent("large.txt"))
        fixtures.append(Fixture(name: "large.txt", kind: .text, viewer: .loadFailure(containing: "MB")))
        try (Data("SQLite format 3".utf8) + Data(repeating: 0, count: 32)).write(to: root.appendingPathComponent("cache.store2"))
        fixtures.append(Fixture(name: "cache.store2", kind: .text, viewer: .loadFailure(containing: "binary data")))

        try DocumentFileTypeFixtures.writePDF(to: root.appendingPathComponent("guide.pdf"))
        fixtures.append(Fixture(name: "guide.pdf", kind: .pdf, viewer: .pdf))

        try image("photo.png", .png)
        try image("PHOTO2.PNG", .png)
        try image("photo.jpg", .jpeg)
        try image("sideways.jpg", .jpeg, properties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
        ], pageSize: CGSize(width: 20, height: 40))
        try image("anim.gif", .gif, frames: 2)
        try image("scan.tiff", .tiff)
        try image("icon.bmp", .bmp)
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 32, height: 32)],
            as: .ico,
            to: root.appendingPathComponent("favicon.ico")
        )
        fixtures.append(Fixture(name: "favicon.ico", kind: .image, viewer: .image(CGSize(width: 32, height: 32))))
        if DocumentFileTypeFixtures.canWriteImage(.heic) {
            try image("live.heic", .heic)
        }
        if DocumentFileTypeFixtures.canWriteImage(.webP) {
            try image("pic.webp", .webP)
        } else {
            try DocumentFileTypeFixtures.tinyWebP.write(to: root.appendingPathComponent("pic.webp"))
            fixtures.append(Fixture(name: "pic.webp", kind: .image, viewer: .image(CGSize(width: 1, height: 1))))
        }
        try Data().write(to: root.appendingPathComponent("empty.png"))
        fixtures.append(Fixture(name: "empty.png", kind: .image, viewer: .brokenImage))

        try await DocumentFileTypeFixtures.writeMovie(to: root.appendingPathComponent("clip.mov"))
        fixtures.append(Fixture(name: "clip.mov", kind: .media, viewer: .media))
        try DocumentFileTypeFixtures.writeWAV(to: root.appendingPathComponent("TONE.WAV"))
        fixtures.append(Fixture(name: "TONE.WAV", kind: .media, viewer: .media))
        try Data("not a movie".utf8).write(to: root.appendingPathComponent("broken.mp4"))
        fixtures.append(Fixture(name: "broken.mp4", kind: .media, viewer: .brokenMedia))

        for name in ["clip.avi", "archive.zip", "report.docx"] {
            try Data("PK".utf8).write(to: root.appendingPathComponent(name))
            fixtures.append(Fixture(name: name, kind: .unsupported, viewer: .otherApp))
        }
        try Data("SECRET=1\n".utf8).write(to: root.appendingPathComponent(".env"))
        return (root, fixtures)
    }

    // MARK: - Hosting

    private func openStore(_ root: URL) async throws -> WorkspaceStore {
        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let loaded = await waitUntil { !store.isBusy && store.workspaceURL != nil }
        XCTAssertTrue(loaded, "Workspace did not load")
        store.testing_stopFileWatcher()
        return store
    }

    private func hostEditorPane(store: WorkspaceStore) -> NSView {
        hostView(EditorPaneHarness(store: store))
    }

    private func hostView<Content: View>(_ view: Content) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 800, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = host
        window.orderFront(nil)
        hostWindows.append(window)
        return host
    }

    private func documentTextView(in view: NSView) -> NSTextView? {
        allDescendants(of: NSTextView.self, in: view).first {
            $0.identifier == .monknotDocumentFocusTarget
        }
    }

    private func pdfView(in view: NSView) -> PDFView? {
        firstDescendant(of: PDFView.self, in: view)
    }

    private func playerView(in view: NSView) -> MediaPlayerNSView? {
        firstDescendant(of: MediaPlayerNSView.self, in: view)
    }

    private func firstDescendant<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> ViewType? {
        allDescendants(of: type, in: view).first
    }

    private func allDescendants<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> [ViewType] {
        var matches: [ViewType] = []
        if let match = view as? ViewType {
            matches.append(match)
        }
        for subview in view.subviews {
            matches += allDescendants(of: type, in: subview)
        }
        return matches
    }

    private func keyEvent(_ characters: String, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 49
        ))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// The editor pane as `ContentView` mounts it, in Source mode unless told otherwise, with no split.
private struct EditorPaneHarness: View {
    @ObservedObject var store: WorkspaceStore
    @State private var editorMode: EditorMode
    @State private var isSplitViewEnabled = false
    @State private var sourceLocation: MarkdownSourceLocation?
    @State private var previewLocation: MarkdownSourceLocation?
    @State private var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @State private var documentSearch = DocumentSearchState()
    @StateObject private var pdfViewportCaptureBridge = PDFViewportCaptureBridge()

    init(store: WorkspaceStore, editorMode: EditorMode = .source) {
        self.store = store
        _editorMode = State(initialValue: editorMode)
    }

    var body: some View {
        EditorPaneView(
            store: store,
            editorMode: $editorMode,
            isSplitViewEnabled: $isSplitViewEnabled,
            theme: .defaultLight,
            zoomScale: 1,
            codeFontSize: 13,
            contentWidthPercent: 100,
            showsDocumentOutline: false,
            usePointerCursors: false,
            fontSmoothing: true,
            activeViewportState: nil,
            pdfViewportCaptureBridge: pdfViewportCaptureBridge,
            updateViewportState: { _, _ in },
            pdfUndoCommandSerial: 0,
            pdfRedoCommandSerial: 0,
            updatePDFAnnotationUndoState: { _, _ in },
            sourceLocation: $sourceLocation,
            previewLocation: $previewLocation,
            pdfSearchTarget: $pdfSearchTarget,
            pdfPageNavigationRequest: nil,
            pdfNavigatorToggleCommandSerial: 0,
            documentSearch: $documentSearch,
            searchOptions: MonknotSearchOptions(),
            newMarkdown: {},
            bootstrapStarterWorkspace: {},
            openFolder: {},
            saveDocument: {},
            outlineItems: [],
            textStatistics: nil,
            selectOutlineItem: { _ in },
            onPreviewSourceJump: { _ in },
            copyPDFLinkedExcerpt: { _ in },
            updatePDFSelectionSnapshot: { _ in },
            consumePDFPageNavigationRequest: { _ in },
            onMarkdownSelectionChange: { _ in },
            onMarkdownLinkRequest: { _ in },
            onInspectLinks: nil,
            onMarkdownImagePasteRequest: { _ in },
            onMarkdownFileDropRequest: { _ in },
            onMarkdownPreviewLinkRequest: { _ in },
            onMarkdownTaskRequest: { _ in }
        )
    }
}
