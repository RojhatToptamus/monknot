import XCTest
@testable import MonknotApp
@testable import MonknotCore

final class MonknotLaunchCaptureParserTests: XCTestCase {
    func testParsesWorkspaceURLCaptureArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/Monknot Workspace", isDirectory: true)

        let request = try XCTUnwrap(MonknotLaunchCaptureParser.request(arguments: [
            "monknot",
            "--workspace",
            root.path,
            "--capture-url",
            "https://example.com/research/important-finding#section"
        ]))

        XCTAssertEqual(request.workspaceURL, root.standardizedFileURL)
        guard case .capturedMarkdown(let markdown, let suggestedName) = request.item.payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Important Finding.md"), suggestedName)
        XCTAssertTrue(markdown.contains("Source: https://example.com/research/important-finding"))
        XCTAssertFalse(markdown.contains("#section"))
    }

    func testParsesWorkspaceTextCaptureArguments() throws {
        let request = try XCTUnwrap(MonknotLaunchCaptureParser.request(arguments: [
            "monknot",
            "--workspace",
            "/tmp/notes",
            "--capture-text",
            "A useful clipped paragraph",
            "--capture-title",
            "Clipped Paragraph"
        ]))

        guard case .capturedMarkdown(let markdown, let suggestedName) = request.item.payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Clipped Paragraph.md"), suggestedName)
        XCTAssertTrue(markdown.contains("# Clipped Paragraph"))
        XCTAssertTrue(markdown.contains("A useful clipped paragraph"))
    }

    func testRequiresWorkspaceForLaunchCapture() {
        XCTAssertNil(MonknotLaunchCaptureParser.request(arguments: [
            "monknot",
            "--capture-url",
            "https://example.com"
        ]))
    }

    func testParsesURLSchemeCaptureURL() throws {
        var components = URLComponents()
        components.scheme = MonknotCaptureURLBuilder.scheme
        components.host = MonknotCaptureURLBuilder.host
        components.queryItems = [
            URLQueryItem(name: "workspace", value: "/tmp/Monknot Workspace"),
            URLQueryItem(name: "url", value: "https://docs.example.dev/guides/custom_provider_setup#section")
        ]

        let request = try XCTUnwrap(components.url.flatMap(MonknotLaunchCaptureParser.request(url:)))

        XCTAssertEqual(request.workspaceURL.path, "/tmp/Monknot Workspace")
        guard case .capturedMarkdown(let markdown, let suggestedName) = request.item.payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Custom Provider Setup.md"), suggestedName)
        XCTAssertTrue(markdown.contains("Source: https://docs.example.dev/guides/custom_provider_setup"))
        XCTAssertFalse(markdown.contains("#section"))
    }

    func testParsesCaptureURLBuiltByCoreBuilder() throws {
        let url = try MonknotCaptureURLBuilder().captureURL(
            workspacePath: "/tmp/Monknot Workspace",
            sourceURL: "https://example.com/research/important finding?q=a b#section",
            title: "Readable Browser Title"
        )

        let request = try XCTUnwrap(MonknotLaunchCaptureParser.request(url: url))

        XCTAssertEqual(request.workspaceURL.path, "/tmp/Monknot Workspace")
        guard case .capturedMarkdown(let markdown, let suggestedName) = request.item.payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Readable Browser Title.md"), suggestedName)
        XCTAssertTrue(markdown.contains("# Readable Browser Title"))
        XCTAssertTrue(markdown.contains("Source: https://example.com/research/important%20finding?q=a%20b"))
        XCTAssertFalse(markdown.contains("#section"))
    }

    func testURLSchemeCaptureRequiresMonknotCaptureHostAndWorkspace() {
        XCTAssertNil(MonknotLaunchCaptureParser.request(url: URL(string: "monknot://open?workspace=/tmp/a&text=hello")!))
        XCTAssertNil(MonknotLaunchCaptureParser.request(url: URL(string: "https://example.com/capture?workspace=/tmp/a&text=hello")!))
        XCTAssertNil(MonknotLaunchCaptureParser.request(url: URL(string: "monknot://capture?text=hello")!))
    }

    func testWorkspaceWindowRequestPreservesCaptureItemAcrossCodableRoundTrip() throws {
        let item = WorkspacePasteboardImportItem.capturedMarkdown(
            "# Captured\n\nSource: https://example.com\n",
            suggestedName: "Captured.md"
        )
        let request = MonknotWorkspaceWindowRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            captureItem: item
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MonknotWorkspaceWindowRequest.self, from: data)

        XCTAssertEqual(decoded.workspaceURL?.path, "/tmp/workspace")
        XCTAssertEqual(decoded.captureItem, item)
    }
}
