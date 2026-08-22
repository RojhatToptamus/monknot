import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownMissingLinkCreationTests: MarkdownWorkspaceLinkTestCase {
    func testMissingWikilinkCreationURLUsesResolverAndSourceRelativeMarkdownPath() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-missing-link-target", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Notes/Source.md"), rootURL: root)
        let documents = [source]

        XCTAssertEqual(
            creationURL("[[New Note#Plan]]", source: source, root: root, documents: documents),
            root.appendingPathComponent("Notes/New Note.md").standardizedFileURL
        )
        XCTAssertEqual(
            creationURL("[[/Reference/Guide.markdown]]", source: source, root: root, documents: documents),
            root.appendingPathComponent("Reference/Guide.markdown").standardizedFileURL
        )
        XCTAssertEqual(
            creationURL("[[./Local]]", source: source, root: root, documents: documents),
            root.appendingPathComponent("Notes/Local.md").standardizedFileURL
        )
    }

    func testMissingWikilinkCreationURLRefusesNonMissingAmbiguousAndUnsafeTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-missing-link-refusal", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Notes/Source.md"), rootURL: root)
        let existing = WorkspaceDocument(url: root.appendingPathComponent("Notes/Existing.md"), rootURL: root)
        let first = WorkspaceDocument(url: root.appendingPathComponent("One/Daily.md"), rootURL: root)
        let second = WorkspaceDocument(url: root.appendingPathComponent("Two/Daily.md"), rootURL: root)
        let documents = [source, existing, first, second]

        for markdown in [
            "[[Existing]]",
            "[[Daily]]",
            "[[../Escape]]",
            "[[Folder/../../Escape]]",
            "[[https://example.com/note]]",
            "[new](New.md)",
            "[[New.txt]]",
            "[[.hidden]]",
            "[[Folder//New]]",
            "[[New?mode=edit]]",
            "[[Bad%ZZ]]",
        ] {
            XCTAssertNil(
                creationURL(markdown, source: source, root: root, documents: documents),
                markdown
            )
        }
    }
}
