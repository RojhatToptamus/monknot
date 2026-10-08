import Foundation
import XCTest
@testable import MonknotApp

final class WorkspaceResourceSchemeHandlerTests: XCTestCase {
    func testPageBaseURLMapsADocumentDirectoryOntoTheScheme() throws {
        let base = try XCTUnwrap(WorkspaceResourceSchemeHandler.pageBaseURL(
            forDirectory: URL(fileURLWithPath: "/Users/me/Notes/My Research", isDirectory: true)
        ))
        XCTAssertEqual(base.absoluteString, "monknot-file:///Users/me/Notes/My%20Research/")

        // Relative image paths in a note resolve inside the scheme, including "../".
        let image = try XCTUnwrap(URL(string: "../assets/pasted.png", relativeTo: base)).absoluteURL
        XCTAssertEqual(WorkspaceResourceSchemeHandler.fileURL(for: image)?.path, "/Users/me/Notes/assets/pasted.png")
    }

    func testOnlyFilesInsideTheWorkspaceAreServed() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("monknot-resource-handler-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = sandbox.appendingPathComponent("workspace", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: workspace.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try Data([1]).write(to: workspace.appendingPathComponent("assets/image.png"))
        try Data([2]).write(to: outside.appendingPathComponent("secret.png"))
        try fileManager.createSymbolicLink(
            at: workspace.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let handler = WorkspaceResourceSchemeHandler()
        handler.rootURL = workspace
        let base = try XCTUnwrap(WorkspaceResourceSchemeHandler.pageBaseURL(forDirectory: workspace))
        func servable(_ relative: String) throws -> Bool {
            let url = try XCTUnwrap(URL(string: relative, relativeTo: base)).absoluteURL
            return handler.servableFileURL(for: url) != nil
        }

        XCTAssertTrue(try servable("assets/image.png"))
        XCTAssertFalse(try servable("../outside/secret.png"), "a path outside the workspace")
        XCTAssertFalse(try servable("escape/secret.png"), "a symbolic link out of the workspace")
        XCTAssertFalse(try servable("../workspace-sibling/image.png"), "a sibling sharing the root's prefix")

        handler.rootURL = nil
        XCTAssertFalse(try servable("assets/image.png"), "nothing is served without a workspace")
    }
}
