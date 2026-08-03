import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

final class SidebarTreePresentationTests: XCTestCase {
    func testCompactsOnlyConsecutiveSingleFolderChains() {
        let file = SidebarNode(
            id: "/workspace/src/main/java/com/example/project/App.java",
            url: URL(fileURLWithPath: "/workspace/src/main/java/com/example/project/App.java"),
            name: "App.java",
            relativePath: "src/main/java/com/example/project/App.java",
            kind: .file
        )
        let project = folder("project", path: "src/main/java/com/example/project", children: [file])
        let example = folder("example", path: "src/main/java/com/example", children: [project])
        let com = folder("com", path: "src/main/java/com", children: [example])
        let java = folder("java", path: "src/main/java", children: [com])
        let main = folder("main", path: "src/main", children: [java])
        let test = folder("test", path: "src/test", children: [])
        let src = folder("src", path: "src", children: [main, test])
        let expanded = Set([src, main, java, com, example, project].map(\.id))

        let visible = SidebarTreePresentation.visibleNodes(
            from: [src],
            expandedFolderIDs: expanded
        )

        XCTAssertEqual(visible.map(\.displayName), [
            "src",
            "main/java/com/example/project",
            "App.java",
            "test",
        ])
        XCTAssertEqual(visible.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(visible[1].node.id, main.id)
        XCTAssertEqual(visible[1].dropTargetNode.id, project.id)
        XCTAssertEqual(visible[1].folderNodeIDs, [main.id, java.id, com.id, example.id, project.id])
    }

    func testCollapsedCompactPathKeepsItsUnderlyingHierarchyAndCanExpandAsOneRow() {
        let leaf = folder("example", path: "java/com/example", children: [])
        let com = folder("com", path: "java/com", children: [leaf])
        let java = folder("java", path: "java", children: [com])

        let collapsed = SidebarTreePresentation.visibleNodes(
            from: [java],
            expandedFolderIDs: []
        )

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].displayName, "java/com/example")
        XCTAssertFalse(collapsed[0].isExpanded(in: []))
        XCTAssertEqual(collapsed[0].node.children?.first?.id, com.id)

        let expandedIDs = Set(collapsed[0].folderNodeIDs)
        XCTAssertTrue(collapsed[0].isExpanded(in: expandedIDs))
    }

    func testRecentDocumentsViewportUsesFiveCompleteRowsAtCommonSidebarHeight() {
        let rowHeight: CGFloat = 30

        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.visibleRowCount(
                entryCount: 8,
                availableSidebarHeight: 600,
                rowHeight: rowHeight
            ),
            5
        )
        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.viewportHeight(
                entryCount: 8,
                availableSidebarHeight: 600,
                rowHeight: rowHeight
            ),
            rowHeight * 5
        )
    }

    func testRecentDocumentsViewportShrinksByWholeRowsInShortSidebar() {
        let rowHeight: CGFloat = 30

        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.visibleRowCount(
                entryCount: 8,
                availableSidebarHeight: 240,
                rowHeight: rowHeight
            ),
            2
        )
        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.viewportHeight(
                entryCount: 8,
                availableSidebarHeight: 240,
                rowHeight: rowHeight
            ),
            rowHeight * 2
        )
    }

    func testRecentDocumentsViewportDoesNotReserveBlankRows() {
        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.visibleRowCount(
                entryCount: 2,
                availableSidebarHeight: 800,
                rowHeight: 30
            ),
            2
        )
        XCTAssertEqual(
            SidebarRecentDocumentsLayoutPolicy.visibleRowCount(
                entryCount: 0,
                availableSidebarHeight: 800,
                rowHeight: 30
            ),
            0
        )
    }

    private func folder(_ name: String, path: String, children: [SidebarNode]) -> SidebarNode {
        SidebarNode(
            id: "/workspace/\(path)",
            url: URL(fileURLWithPath: "/workspace/\(path)"),
            name: name,
            relativePath: path,
            kind: .folder,
            children: children
        )
    }
}
