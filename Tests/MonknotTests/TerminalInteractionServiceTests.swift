import XCTest
@testable import MonknotCore

final class TerminalInteractionServiceTests: XCTestCase {
    func testSourceLocationValidationRejectsStaleLinesAndColumns() {
        let text = "alpha\r\n😀beta\n"

        XCTAssertEqual(
            TerminalSourceLocationValidator.location(line: 2, column: 3, in: text),
            MarkdownSourceLocation(line: 2, offset: 2)
        )
        XCTAssertNil(TerminalSourceLocationValidator.location(line: 2, column: 8, in: text))
        XCTAssertNil(TerminalSourceLocationValidator.location(line: 4, column: 1, in: text))
        XCTAssertNil(TerminalSourceLocationValidator.location(line: 0, column: 1, in: text))
    }

    func testParsesPathLineAndColumnWithoutLosingSpaces() {
        XCTAssertEqual(
            TerminalFileReferenceParser.parse(#""Sources/My File.swift":42:7"#),
            TerminalFileReference(path: "Sources/My File.swift", line: 42, column: 7)
        )
        XCTAssertEqual(
            TerminalFileReferenceParser.parse("README.md:9"),
            TerminalFileReference(path: "README.md", line: 9)
        )
        XCTAssertEqual(
            TerminalFileReferenceParser.parse("Sources/App.swift"),
            TerminalFileReference(path: "Sources/App.swift")
        )
    }

    func testParserRejectsURLsInvalidLocationsAndControlCharacters() {
        XCTAssertNil(TerminalFileReferenceParser.parse("https://example.com/file.swift:4:2"))
        XCTAssertNil(TerminalFileReferenceParser.parse("file.swift:0:2"))
        XCTAssertNil(TerminalFileReferenceParser.parse("file.swift:2:0"))
        XCTAssertNil(TerminalFileReferenceParser.parse("file.swift:-1"))
        XCTAssertNil(TerminalFileReferenceParser.parse("file\u{1B}.swift:2"))
        XCTAssertNil(TerminalFileReferenceParser.parse(""))
    }

    func testResolvesExactWorkspaceRelativeAndAbsoluteReferences() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let source = fixture.root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "print(\"ok\")\n".write(to: source, atomically: true, encoding: .utf8)

        let relative = try TerminalWorkspacePathResolver.resolve(
            TerminalFileReference(path: "Sources/App.swift", line: 1, column: 3),
            workspaceURL: fixture.root
        )
        XCTAssertEqual(relative.url, source.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(relative.line, 1)
        XCTAssertEqual(relative.column, 3)

        let absolute = try TerminalWorkspacePathResolver.resolve(
            TerminalFileReference(path: source.path, line: 1),
            workspaceURL: fixture.root
        )
        XCTAssertEqual(absolute.url, relative.url)
    }

    func testResolvesBenignDotComponentsWithoutWeakeningTraversalBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let source = fixture.root.appendingPathComponent("Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let value = 1\n".write(to: source, atomically: true, encoding: .utf8)

        let reference = try XCTUnwrap(
            TerminalFileReferenceParser.parse("./Sources/Foo.swift:12:3")
        )
        let resolved = try TerminalWorkspacePathResolver.resolve(
            reference,
            workspaceURL: fixture.root
        )

        XCTAssertEqual(resolved.url, source.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(resolved.line, 12)
        XCTAssertEqual(resolved.column, 3)

        XCTAssertThrowsError(
            try TerminalWorkspacePathResolver.resolve(
                TerminalFileReference(path: "./../outside.swift", line: 1),
                workspaceURL: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? TerminalWorkspacePathResolutionError, .outsideWorkspace)
        }
    }

    func testSuffixResolutionRejectsAmbiguousWorkspaceFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let first = fixture.root.appendingPathComponent("One/Shared.swift")
        let second = fixture.root.appendingPathComponent("Two/Shared.swift")
        for url in [first, second] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
        }

        XCTAssertThrowsError(
            try TerminalWorkspacePathResolver.resolve(
                TerminalFileReference(path: "Shared.swift", line: 1),
                workspaceURL: fixture.root,
                knownDocumentURLs: [first, second]
            )
        ) { error in
            guard case TerminalWorkspacePathResolutionError.ambiguous(let paths) = error else {
                return XCTFail("Expected ambiguity, got \(error)")
            }
            XCTAssertEqual(
                Set(paths),
                Set([first, second].map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            )
        }

        let unique = try TerminalWorkspacePathResolver.resolve(
            TerminalFileReference(path: "One/Shared.swift", line: 1),
            workspaceURL: fixture.root,
            knownDocumentURLs: [first, second]
        )
        XCTAssertEqual(unique.url.path, first.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testRelativeRootMatchDoesNotSilentlyWinOverAnotherWorkspaceSuffix() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let workspace = fixture.root
        let rootFile = workspace.appendingPathComponent("Target.swift")
        let nestedDirectory = workspace.appendingPathComponent("Sources", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("Target.swift")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "root".write(to: rootFile, atomically: true, encoding: .utf8)
        try "nested".write(to: nestedFile, atomically: true, encoding: .utf8)

        let reference = try XCTUnwrap(TerminalFileReferenceParser.parse("Target.swift:1"))
        XCTAssertThrowsError(
            try TerminalWorkspacePathResolver.resolve(
                reference,
                workspaceURL: workspace,
                knownDocumentURLs: [rootFile, nestedFile]
            )
        ) { error in
            guard case .ambiguous(let paths) = error as? TerminalWorkspacePathResolutionError else {
                return XCTFail("Expected an ambiguous path error, got \(error)")
            }
            XCTAssertEqual(
                Set(paths),
                Set([rootFile, nestedFile].map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            )
        }
    }

    func testResolverRejectsTraversalAndSymlinkEscapes() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try "outside\n".write(to: fixture.outsideFile, atomically: true, encoding: .utf8)
        let link = fixture.root.appendingPathComponent("escaped.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outsideFile)

        for path in [fixture.outsideFile.path, "../outside.swift", "escaped.swift"] {
            XCTAssertThrowsError(
                try TerminalWorkspacePathResolver.resolve(
                    TerminalFileReference(path: path, line: 1),
                    workspaceURL: fixture.root
                )
            ) { error in
                XCTAssertEqual(
                    error as? TerminalWorkspacePathResolutionError,
                    .outsideWorkspace
                )
            }
        }
    }

    func testCanonicalWorkspaceURLAllowsFoldersButNeverLeavesWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(
            try TerminalWorkspacePathResolver.canonicalWorkspaceURL(
                for: folder,
                workspaceURL: fixture.root
            ),
            folder.standardizedFileURL.resolvingSymlinksInPath()
        )

        try "outside\n".write(to: fixture.outsideFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try TerminalWorkspacePathResolver.canonicalWorkspaceURL(
                for: fixture.outsideFile,
                workspaceURL: fixture.root
            )
        )
    }

    func testShellArgumentQuotingAlwaysProducesOneLiteralArgument() {
        XCTAssertEqual(TerminalShellArgument.quote(""), "''")
        XCTAssertEqual(TerminalShellArgument.quote("Notes/My File.md"), "'Notes/My File.md'")
        XCTAssertEqual(TerminalShellArgument.quote("it's.md"), "'it'\\''s.md'")
        XCTAssertEqual(TerminalShellArgument.quote("資料.md"), "'資料.md'")
    }

    func testInsertionRequestRejectsEmptyInvalidSerialAndUnsafeControls() {
        XCTAssertThrowsError(try TerminalInsertionRequest(serial: 0, text: "text"))
        XCTAssertThrowsError(try TerminalInsertionRequest(serial: 1, text: ""))
        XCTAssertThrowsError(
            try TerminalInsertionRequest(
                serial: 1,
                text: String(repeating: "x", count: TerminalInsertionRequest.maximumTextBytes + 1)
            )
        )
        for text in ["return\r", "escape\u{1B}", "nul\u{0}", "delete\u{7F}"] {
            XCTAssertThrowsError(try TerminalInsertionRequest(serial: 1, text: text))
        }

        XCTAssertNoThrow(try TerminalInsertionRequest(serial: 1, text: "tab\tallowed"))
        XCTAssertNoThrow(try TerminalInsertionRequest(serial: 1, text: "line\nallowed"))
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalInteractionServiceTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(
            parent: parent,
            root: root,
            outsideFile: parent.appendingPathComponent("outside.swift")
        )
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let outsideFile: URL

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
