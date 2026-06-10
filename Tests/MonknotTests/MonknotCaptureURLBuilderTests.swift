import XCTest
@testable import MonknotCore

final class MonknotCaptureURLBuilderTests: XCTestCase {
    func testBuildsURLCaptureURLWithPercentEncodedQueryItems() throws {
        let url = try MonknotCaptureURLBuilder().captureURL(
            workspacePath: "/tmp/Monknot Workspace",
            sourceURL: "https://example.com/research/important finding?q=a b#section"
        )

        XCTAssertEqual(url.scheme, "monknot")
        XCTAssertEqual(url.host, "capture")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.firstValue(named: "workspace"), "/tmp/Monknot Workspace")
        XCTAssertEqual(
            components.queryItems?.firstValue(named: "url"),
            "https://example.com/research/important finding?q=a b#section"
        )
        XCTAssertTrue(url.absoluteString.contains("Monknot%20Workspace"), url.absoluteString)
    }

    func testBuildsTextCaptureURL() throws {
        let url = try MonknotCaptureURLBuilder().captureURL(
            workspacePath: "/tmp/notes",
            text: "Captured paragraph",
            title: "Inbox Title"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.firstValue(named: "workspace"), "/tmp/notes")
        XCTAssertEqual(components.queryItems?.firstValue(named: "text"), "Captured paragraph")
        XCTAssertEqual(components.queryItems?.firstValue(named: "title"), "Inbox Title")
    }

    func testRequiresWorkspaceAndSinglePayload() {
        XCTAssertThrowsError(try MonknotCaptureURLBuilder().captureURL(workspacePath: "", text: "hello")) { error in
            XCTAssertEqual(error as? MonknotCaptureURLBuilder.Error, .missingWorkspace)
        }
        XCTAssertThrowsError(try MonknotCaptureURLBuilder().captureURL(workspacePath: "/tmp/a")) { error in
            XCTAssertEqual(error as? MonknotCaptureURLBuilder.Error, .missingPayload)
        }
        XCTAssertThrowsError(try MonknotCaptureURLBuilder().captureURL(workspacePath: "/tmp/a", sourceURL: "https://example.com", text: "hello")) { error in
            XCTAssertEqual(error as? MonknotCaptureURLBuilder.Error, .multiplePayloads)
        }
        XCTAssertThrowsError(try MonknotCaptureURLBuilder().captureURL(workspacePath: "/tmp/a", sourceURL: "not-a-url")) { error in
            XCTAssertEqual(error as? MonknotCaptureURLBuilder.Error, .invalidSourceURL)
        }
    }
}

private extension Array where Element == URLQueryItem {
    func firstValue(named name: String) -> String? {
        first { $0.name == name }?.value
    }
}
