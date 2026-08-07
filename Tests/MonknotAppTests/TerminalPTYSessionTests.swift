import Darwin
import Foundation
import XCTest
@testable import MonknotApp

final class TerminalPTYSessionTests: XCTestCase {
    func testInteractiveLoginShellUsesWorkspaceEnvironmentAndPTYControls() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotTerminalPTY-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "terminal fixture\n".write(
            to: workspace.appendingPathComponent("terminal-fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let recorder = TerminalPTYRecorder()
        let session = TerminalPTYSession(
            outputHandler: { recorder.append($0) },
            exitHandler: { _ in }
        )
        defer { session.stop() }

        try session.start(workingDirectory: workspace)
        session.resize(columns: 120, rows: 40)
        session.write("stty -echo; printf '__MONKNOT_%s__\\n' READY\n")
        XCTAssertNotNil(recorder.waitFor("__MONKNOT_READY__", timeout: 10), recorder.snapshot)
        recorder.clear()
        session.write(
            """
            printf '__MONKNOT_%s__%s\\n' LOGIN \"$([[ -o login ]] && echo yes || echo no)\"
            printf '__MONKNOT_%s__%s\\n' INTERACTIVE \"$([[ -o interactive ]] && echo yes || echo no)\"
            printf '__MONKNOT_%s__%s\\n' PWD \"$PWD\"
            printf '__MONKNOT_%s__hello\\n' ECHO
            printf '__MONKNOT_%s__' LS; command ls -1 | tr '\\n' ','; printf '\\n'
            printf '__MONKNOT_%s__' WHICH_GIT; which git
            git --version | sed 's/^/__MONKNOT_GIT_VERSION__/'
            printf '__MONKNOT_%s__%s\\n' PATH \"$PATH\"
            for tool in claude codex node brew; do
              if command -v \"$tool\" >/dev/null 2>&1; then
                printf '__MONKNOT_%s__%s=available\\n' TOOL \"$tool\"
                if [[ \"$tool\" != brew ]]; then
                  \"$tool\" --version 2>&1 | head -n 1 | sed \"s/^/__MONKNOT_VERSION__${tool}=/\"
                fi
              else
                printf '__MONKNOT_%s__%s=unavailable\\n' TOOL \"$tool\"
              fi
            done
            printf '__MONKNOT_%s__' SIZE; stty size
            printf '__MONKNOT_%s__\\n' BEFORE_INTERRUPT
            sleep 30
            """ + "\n"
        )

        let beforeInterrupt = try XCTUnwrap(
            recorder.waitFor("__MONKNOT_BEFORE_INTERRUPT__", timeout: 15),
            recorder.snapshot
        )
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_LOGIN__yes"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_INTERACTIVE__yes"), beforeInterrupt)
        let resolvedWorkspacePath = canonicalPath(workspace)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_PWD__\(resolvedWorkspacePath)"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_ECHO__hello"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_LS__terminal-fixture.txt,"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_WHICH_GIT__/usr/bin/git"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_GIT_VERSION__git version"), beforeInterrupt)
        XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_SIZE__40 120"), beforeInterrupt)

        let outputLines = beforeInterrupt
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map(String.init)
        let path = try XCTUnwrap(
            outputLines
                .first { $0.contains("__MONKNOT_PATH__") }?
                .components(separatedBy: "__MONKNOT_PATH__")
                .last
        )
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
            XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"), path)
        }
        if FileManager.default.fileExists(atPath: "/usr/local/bin") {
            XCTAssertTrue(path.split(separator: ":").contains("/usr/local/bin"), path)
        }
        for tool in ["claude", "codex", "node", "brew"] {
            let availableMarker = "__MONKNOT_TOOL__\(tool)=available"
            let unavailableMarker = "__MONKNOT_TOOL__\(tool)=unavailable"
            let isAvailable = beforeInterrupt.contains(availableMarker)
            let isUnavailable = beforeInterrupt.contains(unavailableMarker)
            XCTAssertNotEqual(
                isAvailable,
                isUnavailable,
                "Expected exactly one availability marker for \(tool).\n\(beforeInterrupt)"
            )
            if isAvailable, tool != "brew" {
                XCTAssertTrue(beforeInterrupt.contains("__MONKNOT_VERSION__\(tool)="), beforeInterrupt)
            }
        }

        session.write("\u{3}")
        session.write("printf '__MONKNOT_%s__\\n' AFTER_INTERRUPT\n")
        XCTAssertNotNil(
            recorder.waitFor("__MONKNOT_AFTER_INTERRUPT__", timeout: 5),
            recorder.snapshot
        )
    }

    func testTwoTerminalSessionsRunIndependently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotTerminalPTYMultiple-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstRecorder = TerminalPTYRecorder()
        let secondRecorder = TerminalPTYRecorder()
        let first = TerminalPTYSession(
            outputHandler: { firstRecorder.append($0) },
            exitHandler: { _ in }
        )
        let second = TerminalPTYSession(
            outputHandler: { secondRecorder.append($0) },
            exitHandler: { _ in }
        )
        defer {
            first.stop()
            second.stop()
        }

        try first.start(workingDirectory: firstDirectory)
        try second.start(workingDirectory: secondDirectory)
        first.write("printf '__%s__%s\\n' FIRST \"$PWD\"\n")
        second.write("printf '__%s__%s\\n' SECOND \"$PWD\"\n")

        let firstOutput = try XCTUnwrap(firstRecorder.waitFor("__FIRST__", timeout: 10))
        let secondOutput = try XCTUnwrap(secondRecorder.waitFor("__SECOND__", timeout: 10))
        XCTAssertTrue(
            firstOutput.contains("__FIRST__\(canonicalPath(firstDirectory))"),
            firstOutput
        )
        XCTAssertTrue(
            secondOutput.contains("__SECOND__\(canonicalPath(secondDirectory))"),
            secondOutput
        )
    }
}

private func canonicalPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private final class TerminalPTYRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var output = ""

    var snapshot: String {
        condition.lock()
        defer { condition.unlock() }
        return output
    }

    func append(_ text: String) {
        condition.lock()
        output += text
        condition.broadcast()
        condition.unlock()
    }

    func clear() {
        condition.lock()
        output = ""
        condition.unlock()
    }

    func waitFor(_ marker: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while !output.contains(marker) {
            if !condition.wait(until: deadline) {
                return nil
            }
        }
        return output
    }
}
