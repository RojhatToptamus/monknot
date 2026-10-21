import AppKit
import XCTest
@testable import MonknotCore

final class WorkspaceDocumentKindSystemImageTests: XCTestCase {
    private func glyph(_ name: String) -> WorkspaceFileGlyph {
        WorkspaceFileGlyph(path: "/workspace/\(name)")
    }

    func testEachKindOfFileHasAGlyphThatSaysWhatItIs() {
        let expected: [(String, WorkspaceFileGlyph)] = [
            ("Product brief.md", .markdown), ("notes.markdown", .markdown),
            ("Pitch deck.pdf", .pdf),
            ("todo.txt", .plainText), ("server.log", .plainText), ("README", .plainText),
            ("LICENSE", .plainText), ("guide.rst", .plainText), ("Release 1.2", .plainText),
            ("App.swift", .code), ("index.js", .code), ("main.py", .code), ("build.sh", .code),
            ("index.html", .code), ("analysis.ipynb", .code), ("styles.css", .code), ("logo.svg", .code),
            ("Makefile", .code), ("Dockerfile", .code), ("page.mdx", .code), ("notes.lua", .code),
            ("config.json", .data), ("compose.yaml", .data), ("Cargo.toml", .data), ("Info.plist", .data),
            ("feed.xml", .data), (".env", .data),
            ("sales.csv", .table), ("export.tsv", .table),
            ("Photo.png", .image), ("scan.HEIC", .image),
            ("Clip.mov", .video), ("talk.mp4", .video),
            ("Voice memo.m4a", .audio), ("song.mp3", .audio), ("take.wav", .audio),
            ("notes.sqlite", .other),
        ]
        for (name, glyph) in expected {
            XCTAssertEqual(self.glyph(name), glyph, name)
        }
    }

    /// The bug this replaces: every text file wore the Markdown note's glyph.
    func testNoFileButMarkdownShowsTheMarkdownGlyph() {
        let markdown = WorkspaceFileGlyph.markdown.systemImage
        let names = WorkspaceDocumentSupport.textExtensions.map { "file.\($0)" }
            + WorkspaceDocumentSupport.htmlExtensions.map { "file.\($0)" }
            + WorkspaceDocumentSupport.notebookExtensions.map { "file.\($0)" }
            + WorkspaceDocumentSupport.textFilenames.map { $0 }
            + WorkspaceDocumentSupport.imageExtensions.map { "file.\($0)" }
            + WorkspaceDocumentSupport.mediaExtensions.map { "file.\($0)" }
            + ["file.pdf", "file.sqlite", "unknown-kind-of-file"]
        for name in names {
            XCTAssertNotEqual(glyph(name).systemImage, markdown, name)
        }
        for kind in [WorkspaceDocumentKind.pdf, .text, .image, .media, .unsupported] {
            XCTAssertNotEqual(kind.systemImage, markdown, "\(kind)")
        }
    }

    func testEveryGlyphIsADistinctOutlineSymbolThatExists() {
        let names = WorkspaceFileGlyph.allCases.map(\.systemImage)
        XCTAssertEqual(Set(names).count, names.count, "Two kinds share a glyph")
        for name in names {
            XCTAssertFalse(name.contains(".fill"), name)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testATabAndADocumentShowTheSameGlyph() {
        let root = URL(fileURLWithPath: "/workspace")
        for name in ["config.json", "todo.txt", "Product brief.md", "Voice memo.m4a"] {
            let document = WorkspaceDocument(url: root.appendingPathComponent(name), rootURL: root)
            XCTAssertEqual(WorkspaceTabItem(document: document).fileGlyph, document.fileGlyph, name)
        }
    }

    func testEditorModeSymbolsDifferFromNewDocumentAndFileIcons() {
        XCTAssertEqual(EditorMode.source.systemImage, "text.alignleft")
        XCTAssertEqual(EditorMode.preview.systemImage, "eye")
        XCTAssertNotEqual(EditorMode.source.systemImage, "doc.badge.plus")
        XCTAssertFalse(WorkspaceFileGlyph.allCases.map(\.systemImage).contains(EditorMode.source.systemImage))
    }
}
