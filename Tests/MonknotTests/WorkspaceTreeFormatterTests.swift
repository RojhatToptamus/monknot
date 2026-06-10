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
}
