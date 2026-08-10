import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
final class TerminalInteractionBridgeTests: XCTestCase {
    func testCollectionWithoutSessionOrDirectoryRejectsInsertionWithoutPublishing() {
        let sessions = TerminalSessionCollectionStore()
        defer { sessions.stopAll() }

        XCTAssertThrowsError(try sessions.requestInsertion("safe text")) { error in
            XCTAssertEqual(error as? TerminalSessionInsertionError, .sessionUnavailable)
        }
        XCTAssertNil(sessions.activeSession)
    }

    func testSessionQueuesAndConsumesInsertionExactlyOnceWithoutAddingReturn() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TerminalSessionStore(initialDirectory: directory)
        defer { session.stop() }

        let first = try session.requestInsertion("printf safe")
        XCTAssertEqual(first.text, "printf safe")
        XCTAssertEqual(session.insertionRequest, first)
        XCTAssertFalse(first.text.hasSuffix("\n"))

        XCTAssertThrowsError(try session.requestInsertion("second")) { error in
            XCTAssertEqual(error as? TerminalSessionInsertionError, .requestPending)
        }
        XCTAssertNil(session.consumeInsertionRequest(serial: first.serial + 1))
        XCTAssertEqual(session.consumeInsertionRequest(serial: first.serial), first)
        XCTAssertNil(session.consumeInsertionRequest(serial: first.serial))

        let second = try session.requestInsertion("second")
        XCTAssertGreaterThan(second.serial, first.serial)
        XCTAssertEqual(second.text, "second")
    }

    func testSessionRejectsUnsafeTextBeforePublishingARequest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TerminalSessionStore(initialDirectory: directory)
        defer { session.stop() }

        XCTAssertThrowsError(try session.requestInsertion("unsafe\r"))
        XCTAssertNil(session.insertionRequest)
        XCTAssertThrowsError(try session.requestInsertion("unsafe\u{1B}"))
        XCTAssertNil(session.insertionRequest)
    }

    func testCollectionQuotesCanonicalWorkspacePathBeforeQueueing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Reader's Note.md")
        try "# Note\n".write(to: file, atomically: true, encoding: .utf8)

        let sessions = TerminalSessionCollectionStore(initialDirectory: directory)
        defer { sessions.stopAll() }
        let request = try sessions.requestPathInsertion(
            file,
            workspaceURL: directory,
            in: directory
        )

        let canonicalPath = file.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(request.text, TerminalShellArgument.quote(canonicalPath))
        XCTAssertFalse(request.text.hasSuffix("\n"))
        XCTAssertEqual(sessions.activeSession?.insertionRequest, request)
    }

    func testCollectionRejectsPathOutsideWorkspaceWithoutCreatingTerminal() throws {
        let directory = try makeTemporaryDirectory()
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)

        let sessions = TerminalSessionCollectionStore(initialDirectory: directory)
        defer { sessions.stopAll() }
        XCTAssertThrowsError(
            try sessions.requestPathInsertion(outside, workspaceURL: directory)
        ) { error in
            XCTAssertEqual(
                error as? TerminalWorkspacePathResolutionError,
                .outsideWorkspace
            )
        }
        XCTAssertNil(sessions.activeSession)
    }

    func testTerminalHTMLUsesSafePasteLinkActivationAndExplicitTeardown() {
        let html = TerminalWebView.html(
            theme: .defaultDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("term.registerLinkProvider"))
        XCTAssertTrue(html.contains("event.metaKey"))
        XCTAssertTrue(html.contains("(?=$|[\\s,:;)\\]}])"))
        XCTAssertTrue(html.contains("term.paste(data)"))
        XCTAssertTrue(html.contains("data.includes('\\n') && !term.modes.bracketedPasteMode"))
        XCTAssertTrue(html.contains("window.monknotDispose = function()"))
        XCTAssertTrue(html.contains("resizeObserver.disconnect()"))
        XCTAssertTrue(html.contains("window.removeEventListener('resize', resizeListener)"))
        XCTAssertTrue(html.contains("inputDisposable.dispose()"))
        XCTAssertTrue(html.contains("pathLinkDisposable.dispose()"))
        XCTAssertTrue(html.contains("term.dispose()"))
        XCTAssertFalse(html.contains("term.paste(data + '\\n')"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalInteractionBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
