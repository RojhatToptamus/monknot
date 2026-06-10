import XCTest
@testable import MonknotCore

final class WorkspaceTemplateServiceTests: XCTestCase {
    func testBootstrapStarterWorkspaceCreatesExpectedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = try WorkspaceTemplateService.bootstrapStarterWorkspace(at: root)

        XCTAssertEqual(readmeURL.lastPathComponent, "README.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/Project Brief.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/Ideas.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/.gitkeep").path))
    }

    func testBootstrapStarterWorkspaceDoesNotOverwriteExistingReadme() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = root.appendingPathComponent("README.md")
        try "Existing".write(to: readmeURL, atomically: true, encoding: .utf8)

        _ = try WorkspaceTemplateService.bootstrapStarterWorkspace(at: root)

        XCTAssertEqual(try String(contentsOf: readmeURL, encoding: .utf8), "Existing")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-template-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
