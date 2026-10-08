import Foundation
import XCTest
@testable import MonknotCore

final class DocumentTabLabelTests: XCTestCase {
    func testMiddleElisionKeepsTheHeadTheEndAndTheExtension() {
        // Characters as the unit; design.md's own example keeps 13 head and 4 end characters. The end
        // before the extension survives, so `Untitled 4` and `Untitled 5` stay distinct.
        XCTAssertEqual(
            DocumentTabLabel.middleElided("improving-onboarding-conversion-rate.md", toFit: 21) { CGFloat($0.count) },
            "improving-onb\u{2026}rate.md"
        )
        XCTAssertEqual(
            DocumentTabLabel.middleElided("Untitled draft number 4.md", toFit: 14) { CGFloat($0.count) },
            "Untitled\u{2026} 4.md"
        )
        XCTAssertEqual(DocumentTabLabel.middleElided("short.md", toFit: 14) { CGFloat($0.count) }, "short.md")
    }

    func testDuplicateNamesGetTheShortestDistinguishingParent() {
        let paths = [
            "README.md", "alpha/README.md", "beta/README.md",
            "a/x/notes.md", "b/x/notes.md", "c/y/notes.md",
            "inbox/unique.md",
        ]
        let tabs = paths.map { path in
            WorkspaceTabItem(
                documentID: "/workspace/\(path)",
                displayName: (path as NSString).lastPathComponent,
                relativePath: path,
                kind: .markdown
            )
        }

        let labels = DocumentTabLabel.labels(for: tabs)

        XCTAssertEqual(
            paths.map { labels["/workspace/\($0)"] },
            [
                "README.md", "alpha/README.md", "beta/README.md",
                "a/x/notes.md", "b/x/notes.md", "y/notes.md",
                "unique.md",
            ]
        )
    }
}
