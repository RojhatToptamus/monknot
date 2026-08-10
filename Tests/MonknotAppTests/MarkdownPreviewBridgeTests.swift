import Foundation
import XCTest
@testable import MonknotApp

final class MarkdownPreviewBridgeTests: XCTestCase {
    private let identity = MarkdownPreviewRenderIdentity(documentID: "/workspace/Note.md", renderID: 7)

    func testBridgeParsesLinkTaskAndTerminalPasteMessages() {
        XCTAssertEqual(
            MarkdownPreviewView.Coordinator.bridgeInteraction(
                from: payload(action: "link", extra: [
                    "kind": "wikilink",
                    "destination": "Daily Note#Plan",
                ]),
                expectedIdentity: identity
            ),
            .link(MarkdownPreviewLinkRequest(
                identity: identity,
                kind: .wikilink,
                destination: "Daily Note#Plan"
            ))
        )
        XCTAssertEqual(
            MarkdownPreviewView.Coordinator.bridgeInteraction(
                from: payload(action: "task", extra: [
                    "sourceLine": 12,
                    "expectedChecked": false,
                    "desiredChecked": true,
                ]),
                expectedIdentity: identity
            ),
            .task(MarkdownPreviewTaskRequest(
                identity: identity,
                sourceLine: 12,
                expectedChecked: false,
                desiredChecked: true
            ))
        )
        XCTAssertEqual(
            MarkdownPreviewView.Coordinator.bridgeInteraction(
                from: payload(action: "terminalPaste", extra: [
                    "text": "printf 'safe'",
                    "sourceLine": 20,
                ]),
                expectedIdentity: identity
            ),
            .terminalPaste(MarkdownPreviewTerminalPasteRequest(
                identity: identity,
                text: "printf 'safe'",
                sourceLine: 20
            ))
        )
    }

    func testReferenceStyleDestinationUsesExistingMarkdownLinkBridge() {
        XCTAssertEqual(
            MarkdownPreviewView.Coordinator.bridgeInteraction(
                from: payload(action: "link", extra: [
                    "kind": "markdown",
                    "destination": "Folder/Guide.md#Setup",
                ]),
                expectedIdentity: identity
            ),
            .link(MarkdownPreviewLinkRequest(
                identity: identity,
                kind: .markdown,
                destination: "Folder/Guide.md#Setup"
            ))
        )
    }

    func testBridgeRejectsStaleMalformedAndOversizedMessages() {
        var stale = payload(action: "link", extra: ["destination": "Other.md"])
        stale["renderID"] = 6
        XCTAssertNil(MarkdownPreviewView.Coordinator.bridgeInteraction(
            from: stale,
            expectedIdentity: identity
        ))
        XCTAssertNil(MarkdownPreviewView.Coordinator.bridgeInteraction(
            from: payload(action: "task", extra: [
                "sourceLine": 0,
                "expectedChecked": false,
                "desiredChecked": true,
            ]),
            expectedIdentity: identity
        ))
        XCTAssertNil(MarkdownPreviewView.Coordinator.bridgeInteraction(
            from: payload(action: "terminalPaste", extra: [
                "text": String(repeating: "a", count: 1_000_001),
            ]),
            expectedIdentity: identity
        ))
    }

    func testSelectionRequiresCurrentIdentityAndAllowsEmptySelectionToClearState() {
        let selectionPayload: [String: Any] = [
            "documentID": identity.documentID,
            "renderID": identity.renderID,
            "text": "",
            "sourceLine": 0,
        ]
        XCTAssertEqual(
            MarkdownPreviewView.Coordinator.bridgeSelection(
                from: selectionPayload,
                expectedIdentity: identity
            ),
            MarkdownPreviewSelection(identity: identity, text: "", sourceLine: nil)
        )

        var stale = selectionPayload
        stale["documentID"] = "/workspace/Other.md"
        XCTAssertNil(MarkdownPreviewView.Coordinator.bridgeSelection(
            from: stale,
            expectedIdentity: identity
        ))
    }

    func testOnlyFootnoteAndBackreferenceAnchorsMayNavigateInsideWebKit() throws {
        let currentURL = try XCTUnwrap(URL(string: "file:///workspace/Note.md"))
        XCTAssertTrue(MarkdownPreviewView.Coordinator.allowsActivatedNavigation(
            to: try XCTUnwrap(URL(string: "file:///workspace/Note.md#fn-note")),
            currentURL: currentURL
        ))
        XCTAssertTrue(MarkdownPreviewView.Coordinator.allowsActivatedNavigation(
            to: try XCTUnwrap(URL(string: "file:///workspace/Note.md#fnref-note")),
            currentURL: currentURL
        ))
        XCTAssertFalse(MarkdownPreviewView.Coordinator.allowsActivatedNavigation(
            to: try XCTUnwrap(URL(string: "file:///workspace/Other.md#fn-note")),
            currentURL: currentURL
        ))
        XCTAssertFalse(MarkdownPreviewView.Coordinator.allowsActivatedNavigation(
            to: try XCTUnwrap(URL(string: "https://example.com/#fn-note")),
            currentURL: currentURL
        ))
    }

    private func payload(action: String, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "action": action,
            "documentID": identity.documentID,
            "renderID": identity.renderID,
        ]
        result.merge(extra) { _, replacement in replacement }
        return result
    }
}
