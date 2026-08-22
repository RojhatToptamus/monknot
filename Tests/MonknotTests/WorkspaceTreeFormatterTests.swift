import XCTest
@testable import MonknotCore

final class WorkspaceTreeFormatterTests: XCTestCase {
    func testCompactTreeRendersFoldersAndFiles() {
        let root = SidebarNode(
            id: "/tmp/workspace",
            url: URL(fileURLWithPath: "/tmp/workspace"),
            name: "workspace",
            relativePath: "",
            kind: .folder,
            children: [
                SidebarNode(
                    id: "/tmp/workspace/notes",
                    url: URL(fileURLWithPath: "/tmp/workspace/notes"),
                    name: "notes",
                    relativePath: "notes",
                    kind: .folder,
                    children: [
                        SidebarNode(
                            id: "/tmp/workspace/notes/todo.md",
                            url: URL(fileURLWithPath: "/tmp/workspace/notes/todo.md"),
                            name: "todo.md",
                            relativePath: "notes/todo.md",
                            kind: .file
                        )
                    ]
                ),
                SidebarNode(
                    id: "/tmp/workspace/README.md",
                    url: URL(fileURLWithPath: "/tmp/workspace/README.md"),
                    name: "README.md",
                    relativePath: "README.md",
                    kind: .file
                )
            ]
        )

        let tree = WorkspaceTreeFormatter().compactTree(from: root)

        XCTAssertTrue(tree.contains("notes/"))
        XCTAssertTrue(tree.contains("todo.md"))
        XCTAssertTrue(tree.contains("README.md"))
        XCTAssertTrue(tree.hasPrefix("."))
    }

    func testCompactTreePreservesOrderIndentationAndEmptyState() {
        let empty = SidebarNode(
            id: "/tmp/empty",
            url: URL(fileURLWithPath: "/tmp/empty"),
            name: "empty",
            relativePath: "",
            kind: .folder,
            children: []
        )
        XCTAssertEqual(WorkspaceTreeFormatter().compactTree(from: empty), ".")

        let nested = SidebarNode(
            id: "/tmp/workspace",
            url: URL(fileURLWithPath: "/tmp/workspace"),
            name: "workspace",
            relativePath: "",
            kind: .folder,
            children: [
                SidebarNode(
                    id: "/tmp/workspace/B.md",
                    url: URL(fileURLWithPath: "/tmp/workspace/B.md"),
                    name: "B.md",
                    relativePath: "B.md",
                    kind: .file
                ),
                SidebarNode(
                    id: "/tmp/workspace/Folder",
                    url: URL(fileURLWithPath: "/tmp/workspace/Folder"),
                    name: "Folder",
                    relativePath: "Folder",
                    kind: .folder,
                    children: [
                        SidebarNode(
                            id: "/tmp/workspace/Folder/A.md",
                            url: URL(fileURLWithPath: "/tmp/workspace/Folder/A.md"),
                            name: "A.md",
                            relativePath: "Folder/A.md",
                            kind: .file
                        )
                    ]
                ),
            ]
        )
        XCTAssertEqual(
            WorkspaceTreeFormatter().compactTree(from: nested),
            ".\n├── B.md\n└── Folder/\n    └── A.md"
        )
    }
}
