import XCTest
@testable import MonknotCore

final class WorkspaceReadOnlyExportTests: XCTestCase {
    func testCapabilitiesCommandReturnsSupportedCommands() throws {
        let request = Data(#"{"command":"capabilities","root":"/tmp"}"#.utf8)
        let responseData = try WorkspaceReadOnlyExportService().handle(requestData: request)
        let response = try JSONDecoder().decode(WorkspaceReadOnlyExportResponse.self, from: responseData)

        XCTAssertEqual(response.capabilities?.protocolVersion, 1)
        XCTAssertTrue(response.capabilities?.commands.contains("read_file") == true)
        XCTAssertTrue(response.capabilities?.commands.contains("tree") == true)
    }

    func testListDocumentsCommandReturnsJSONExport() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("README.md")
        try "# Hello".write(to: note, atomically: true, encoding: .utf8)

        let request = """
        {"command":"list_documents","root":"\(root.path)"}
        """
        let responseData = try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))
        let response = try JSONDecoder().decode(WorkspaceReadOnlyExportResponse.self, from: responseData)

        XCTAssertEqual(response.documents?.count, 1)
        XCTAssertEqual(response.documents?[0].relativePath, "README.md")
        XCTAssertTrue(response.documents?[0].canEditText == true)
        XCTAssertTrue(response.documents?[0].canSearch == true)
    }

    func testTreeCommandReturnsCompactTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let notesDir = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try "# Hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "todo".write(to: notesDir.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        let request = """
        {"command":"tree","root":"\(root.path)"}
        """
        let responseData = try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))
        let response = try JSONDecoder().decode(WorkspaceReadOnlyExportResponse.self, from: responseData)

        XCTAssertNotNil(response.tree)
        XCTAssertTrue(response.tree?.contains("README.md") == true)
        XCTAssertTrue(response.tree?.contains("notes/") == true)
        XCTAssertTrue(response.tree?.contains("todo.md") == true)
    }

    func testSearchCommandReturnsHits() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("notes.md")
        try "alpha\nneedle here".write(to: note, atomically: true, encoding: .utf8)

        let request = """
        {"command":"search","root":"\(root.path)","query":"needle"}
        """
        let responseData = try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))
        let response = try JSONDecoder().decode(WorkspaceReadOnlyExportResponse.self, from: responseData)

        XCTAssertEqual(response.results?.count, 1)
        XCTAssertEqual(response.results?.first?.relativePath, "notes.md")
        XCTAssertEqual(response.results?.first?.line, 2)
        XCTAssertEqual(response.skippedLargeFileCount, 0)
    }

    func testReadFileCommandReturnsContent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("notes/todo.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "line one\nline two".write(to: note, atomically: true, encoding: .utf8)

        let request = """
        {"command":"read_file","root":"\(root.path)","relativePath":"notes/todo.md"}
        """
        let responseData = try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))
        let response = try JSONDecoder().decode(WorkspaceReadOnlyExportResponse.self, from: responseData)

        XCTAssertEqual(response.file?.relativePath, "notes/todo.md")
        XCTAssertEqual(response.file?.lineCount, 2)
        XCTAssertEqual(response.file?.content, "line one\nline two")
    }

    func testReadFileRejectsPathTraversal() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = """
        {"command":"read_file","root":"\(root.path)","relativePath":"../secret.txt"}
        """
        XCTAssertThrowsError(try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))) { error in
            guard case WorkspaceReadOnlyExportService.Error.invalidRelativePath("../secret.txt") = error else {
                return XCTFail("Expected invalidRelativePath, got \(error)")
            }
        }
    }

    func testReadFileRejectsAmbiguousRelativePathComponents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("notes/todo.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "todo".write(to: note, atomically: true, encoding: .utf8)

        for relativePath in ["/notes/todo.md", "notes/./todo.md", "notes/../notes/todo.md", "notes//todo.md"] {
            let request = """
            {"command":"read_file","root":"\(root.path)","relativePath":"\(relativePath)"}
            """
            XCTAssertThrowsError(try WorkspaceReadOnlyExportService().handle(requestData: Data(request.utf8))) { error in
                guard case WorkspaceReadOnlyExportService.Error.invalidRelativePath(relativePath) = error else {
                    return XCTFail("Expected invalidRelativePath for \(relativePath), got \(error)")
                }
            }
        }
    }

    func testUnsupportedCommandThrows() throws {
        let request = Data(#"{"command":"delete_everything","root":"/tmp"}"#.utf8)
        XCTAssertThrowsError(try WorkspaceReadOnlyExportService().handle(requestData: request)) { error in
            guard case WorkspaceReadOnlyExportService.Error.unsupportedCommand("delete_everything") = error else {
                return XCTFail("Expected unsupportedCommand, got \(error)")
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-export-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
