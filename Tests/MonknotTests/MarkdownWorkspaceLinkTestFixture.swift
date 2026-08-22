import Foundation
import XCTest
@testable import MonknotCore

class MarkdownWorkspaceLinkTestCase: XCTestCase {

    let parser = MarkdownWorkspaceLinkParser()
    let resolver = MarkdownWorkspaceLinkResolver()

    func creationURL(
        _ markdown: String,
        source: WorkspaceDocument,
        root: URL,
        documents: [WorkspaceDocument]
    ) -> URL? {
        guard let link = parser.links(in: markdown).first else { return nil }
        return resolver.missingWikilinkCreationURL(
            link,
            sourceDocument: source,
            workspaceRootURL: root,
            documents: documents
        )
    }

    func resolve(
        _ markdown: String,
        source: WorkspaceDocument,
        root: URL,
        documents: [WorkspaceDocument]
    ) -> MarkdownWorkspaceLinkResolution {
        guard let link = parser.links(in: markdown).first else { return .invalid }
        return resolver.resolve(
            link,
            sourceDocument: source,
            workspaceRootURL: root,
            documents: documents
        )
    }
}
