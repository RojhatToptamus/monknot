import Foundation
import XCTest

final class MonknotExportCLIProcessTests: XCTestCase {
    func testOneShotExportReturnsDocumentsAndSuccess() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "# Note\n".write(
            to: fixture.appendingPathComponent("Note.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try run(arguments: ["--workspace", fixture.path, "--json"])

        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.output.contains("Note.md"), result.output)
    }

    func testMalformedJSONReturnsStructuredErrorAndFailure() throws {
        let result = try run(arguments: ["--stdio"], standardInput: Data("not-json\n".utf8))

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.error.contains("error"), result.error)
    }

    func testMissingWorkspaceAndConflictingArgumentsReturnUsageFailure() throws {
        for arguments in [
            ["--workspace"],
            ["--workspace", "/tmp", "--stdio"],
            ["--stdio", "--mcp"],
        ] {
            let result = try run(arguments: arguments)
            XCTAssertEqual(result.status, 2, "\(arguments): \(result.error)")
            XCTAssertTrue(result.error.contains("Invalid arguments"), result.error)
        }
    }

    func testMissingPathAndUnreadableFileReturnServiceFailures() throws {
        let missing = try run(arguments: ["--workspace", "/path/that/does/not/exist", "--json"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertFalse(missing.error.isEmpty)

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data([0xFF, 0xFE]).write(to: fixture.appendingPathComponent("binary.txt"))
        let request = """
        {"command":"read_file","root":"\(fixture.path)","relativePath":"binary.txt"}
        """
        let unreadable = try run(arguments: ["--stdio"], standardInput: Data("\(request)\n".utf8))
        XCTAssertEqual(unreadable.status, 1)
        XCTAssertTrue(unreadable.error.contains("not valid UTF-8 text"), unreadable.error)
    }

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotExportCLIProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        arguments: [String],
        standardInput: Data = Data()
    ) throws -> (status: Int32, output: String, error: String) {
        let executable = Bundle(for: MonknotExportCLIProcessTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("monknot-export")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(standardInput)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
