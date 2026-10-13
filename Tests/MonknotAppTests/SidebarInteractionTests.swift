import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Sidebar pointer interactions and clipboard/undo command routing.
@MainActor
final class SidebarInteractionTests: WorkspaceStoreTestCase {
    // MARK: - Clipboard target classification

    func testNativeTextTargetClassification() {
        let window = makeWindow()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let webChild = NSView(frame: .zero)
        webView.addSubview(webChild)
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let plain = NSView(frame: .zero)
        [textView, textField, webView, pdfView, plain].forEach { window.contentView?.addSubview($0) }

        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(textView))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(textField))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(webView))
        XCTAssertTrue(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(webChild))
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(plain))
        // A focused PDF gets clipboard commands and Select All through the focused-document path.
        XCTAssertFalse(MonknotNativePasteboardCommand.monknotIsNativeTextTarget(pdfView))
    }

    // MARK: - Undo routing

    func testUndoAndRedoWithTerminalFocusLeaveTheEditorsEditsAlone() {
        // The terminal shares the window's undo manager, which holds the editor's edits.
        for canPerformNative in [true, false] {
            XCTAssertEqual(
                monknotUndoCommandDestination(
                    isPDFDocumentActive: false,
                    hasNativeEditingFocus: true,
                    terminalHasFocus: true,
                    canPerformNative: canPerformNative,
                    canPerformWorkspaceReplace: true,
                    canPerformPDF: false
                ),
                .unavailable
            )
            XCTAssertEqual(
                monknotUndoCommandDestination(
                    isPDFDocumentActive: true,
                    hasNativeEditingFocus: false,
                    terminalHasFocus: true,
                    canPerformNative: canPerformNative,
                    canPerformPDF: true
                ),
                .unavailable
            )
        }
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: false,
                hasNativeEditingFocus: true,
                terminalHasFocus: false,
                canPerformNative: true,
                canPerformPDF: false
            ),
            .native
        )
    }

    // MARK: - Sidebar drag to move

    func testShortDragOfNestedFileDoesNotMoveIt() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let rowFrame = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "a.md"))
        let start = NSPoint(x: rowFrame.midX, y: rowFrame.midY)
        // 10 points down ends on b.md, a file in the same folder.
        await fixture.drag(from: start, to: NSPoint(x: start.x, y: start.y - 10))
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("a.md") }, ["docs/a.md"])
    }

    func testDragRootFileOntoFolderRowMovesIt() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "other"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        _ = await waitUntil { fixture.listing().contains("other/top.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("top.md") }, ["other/top.md"])
    }

    func testDragNestedFileOntoAnotherFolderRowMovesItThere() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "other"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        _ = await waitUntil { fixture.listing().contains("other/b.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("b.md") }, ["other/b.md"])
    }

    func testDragOntoFileRowMovesIntoThatFilesFolder() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        _ = await waitUntil { fixture.listing().contains("docs/top.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("top.md") }, ["docs/top.md"])
    }

    func testDragIntoEmptyTreeSpaceMovesToTheRoot() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        let lastRow = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "top.md"))
        let empty = NSPoint(x: lastRow.midX, y: lastRow.minY - 40)
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: empty)
        _ = await waitUntil { fixture.listing().contains("b.md") }

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("b.md") }, ["b.md"])
    }

    func testDragEndingOnItsOwnRowNeitherMovesNorOpensTheFile() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let selected = fixture.store.selectedDocumentID
        let row = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        await fixture.drag(from: NSPoint(x: row.midX, y: row.midY), to: NSPoint(x: row.midX + 30, y: row.midY))
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(fixture.listing().filter { $0.hasSuffix("b.md") }, ["docs/b.md"])
        XCTAssertEqual(fixture.store.selectedDocumentID, selected)
    }

    func testClickWithoutMovementStillOpensTheFile() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "b.md"))
        await fixture.drag(from: NSPoint(x: row.midX, y: row.midY), to: NSPoint(x: row.midX, y: row.midY))
        let opened = await waitUntil {
            fixture.store.selectedDocumentID == fixture.workspaceURL.appendingPathComponent("docs/b.md").path
        }

        XCTAssertTrue(opened)
    }

    func testDragFolderOntoItsOwnChildDoesNothing() async throws {
        let fixture = try await makeSidebarFixture()
        defer { fixture.close() }
        let source = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "docs"))
        let target = try XCTUnwrap(fixture.frameOfRow(labelPrefix: "inner"))
        await fixture.drag(from: NSPoint(x: source.midX, y: source.midY), to: NSPoint(x: target.midX, y: target.midY))
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertTrue(fixture.listing().contains("docs/inner/c.md"))
    }

    // MARK: - Move target resolution

    func testMoveTargetRules() {
        let root = URL(fileURLWithPath: "/workspace")
        let tree = SidebarNode(id: root.path, url: root, name: "workspace", relativePath: "", kind: .folder, children: [
            folder("A", in: root, children: [
                folder("B", in: root.appendingPathComponent("A"), children: [
                    file("deep.md", in: root.appendingPathComponent("A/B")),
                    file("other.md", in: root.appendingPathComponent("A/B")),
                ]),
            ]),
            folder("C", in: root, children: [file("c.md", in: root.appendingPathComponent("C"))]),
            file("top.md", in: root),
        ])
        let rows = SidebarTreePresentation.visibleNodes(
            from: tree.children ?? [],
            expandedFolderIDs: [root.appendingPathComponent("A").path, root.appendingPathComponent("A/B").path, root.appendingPathComponent("C").path]
        )
        XCTAssertEqual(rows.map(\.displayName), ["A/B", "deep.md", "other.md", "C", "c.md", "top.md"])

        var frames: [String: CGRect] = [:]
        for (index, row) in rows.enumerated() {
            frames[row.id] = CGRect(x: 6, y: 6 + CGFloat(index) * 32, width: 200, height: 30)
        }
        func target(_ dragged: String, onto rowName: String) -> SidebarMoveDropTarget? {
            let draggedRow = rows.first { $0.displayName == dragged }!
            let frame = frames[rows.first { $0.displayName == rowName }!.id]!
            return SidebarMoveDropTarget.resolve(
                draggedRowID: draggedRow.id,
                location: CGPoint(x: frame.midX, y: frame.midY),
                rows: rows,
                rowFrames: frames,
                treeSize: CGSize(width: 212, height: 400),
                workspaceURL: root
            )
        }
        func emptySpaceTarget(_ dragged: String, y: CGFloat) -> SidebarMoveDropTarget? {
            SidebarMoveDropTarget.resolve(
                draggedRowID: rows.first { $0.displayName == dragged }!.id,
                location: CGPoint(x: 100, y: y),
                rows: rows,
                rowFrames: frames,
                treeSize: CGSize(width: 212, height: 400),
                workspaceURL: root
            )
        }

        // A compact folder row is its deepest folder.
        XCTAssertEqual(target("top.md", onto: "A/B")?.folderID, root.appendingPathComponent("A/B").path)
        XCTAssertEqual(target("top.md", onto: "c.md")?.folderID, root.appendingPathComponent("C").path)
        XCTAssertEqual(target("deep.md", onto: "top.md"), .root)
        XCTAssertNil(target("deep.md", onto: "other.md"), "Same folder")
        XCTAssertNil(target("deep.md", onto: "deep.md"), "Own row")
        XCTAssertNil(target("A/B", onto: "deep.md"), "Into itself")
        XCTAssertNil(target("A/B", onto: "A/B"), "Own row")
        XCTAssertEqual(target("A/B", onto: "C")?.folderID, root.appendingPathComponent("C").path)
        XCTAssertEqual(emptySpaceTarget("deep.md", y: 300), .root)
        XCTAssertNil(emptySpaceTarget("top.md", y: 300), "Already at the root")
        XCTAssertNil(emptySpaceTarget("deep.md", y: 500), "Below the visible tree")
        XCTAssertNil(emptySpaceTarget("deep.md", y: 37), "Between two rows")
    }

    // MARK: - File clipboard

    func testSidebarCopyPastedIntoEditorLinksTheWorkspaceFile() throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotSidebarClipboard")
        let note = root.appendingPathComponent("note.md")
        let other = root.appendingPathComponent("other.md")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)
        try "# Other".write(to: other, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotSidebarClipboard-\(UUID().uuidString)"))
        defer {
            WorkspacePasteboardExportService.clearFileTransferPasteboard(pasteboard)
            pasteboard.releaseGlobally()
        }

        try WorkspacePasteboardExportService.copyFile(at: other, to: pasteboard)
        let urls = try XCTUnwrap(WorkspacePasteboardExportService.workspaceFileURLs(on: pasteboard))
        let plan = try MarkdownImageAssetService.planFileDrop(urls, workspaceURL: root, markdownDocumentURL: note)

        XCTAssertEqual(plan.items.map(\.isExternal), [false])
    }

    // MARK: - Helpers

    private func folder(_ name: String, in parent: URL, children: [SidebarNode]) -> SidebarNode {
        let url = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        return SidebarNode(id: url.path, url: url, name: name, relativePath: name, kind: .folder, children: children)
    }

    private func file(_ name: String, in parent: URL) -> SidebarNode {
        let url = parent.appendingPathComponent(name).standardizedFileURL
        return SidebarNode(id: url.path, url: url, name: name, relativePath: name, kind: .file)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    private func waitUntil(timeout: TimeInterval = 4, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeSidebarFixture() async throws -> SidebarFixture {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotSidebarDrag")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        for path in ["docs/a.md", "docs/b.md", "docs/inner/c.md", "other/x.md", "top.md"] {
            try "# \(path)".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        let store = makeWorkspaceStore()
        store.openWorkspace(root, selecting: root.appendingPathComponent("docs/a.md"))
        let opened = await waitUntil { store.documents.count == 5 && !store.isBusy && store.rootNode != nil }
        XCTAssertTrue(opened)

        let defaults = UserDefaults(suiteName: "Monknot.SidebarDrag.\(UUID().uuidString)")!
        let library = WorkspaceLibraryStore(userDefaults: defaults)
        let search = WorkspaceSearchState()
        let view = SidebarView(
            store: store,
            workspaceLibrary: library,
            workspaceSearch: search,
            searchOptions: .constant(MonknotSearchOptions()),
            theme: .defaultDark,
            zoomScale: 1,
            openFolder: {},
            switchWorkspace: { _ in },
            removeWorkspace: { _ in },
            manageWorkspaces: {},
            newMarkdown: {},
            exportPDF: { _ in },
            openDocument: { id in _ = store.selectDocument(id: id) },
            openWorkspaceSearchResult: { _ in },
            showWorkspaceSearch: {},
            dismissWorkspaceSearch: {},
            workspaceSearchFocusChanged: { _ in },
            copyPath: { _ in },
            copyRelativePath: { _ in }
        )
        .frame(width: 280, height: 600)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        return SidebarFixture(window: window, host: host, store: store, workspaceURL: root)
    }
}

@MainActor
private struct SidebarFixture {
    let window: NSWindow
    let host: NSView
    let store: WorkspaceStore
    let workspaceURL: URL

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func treeDocumentView() -> NSView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil,
               String(describing: type(of: scroll)).contains("SidebarNativeScrollView") {
                return scroll
            }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host)?.documentView
    }

    func visibleRows() -> [VisibleSidebarNode] {
        let docsID = store.rootNode?.children?.first(where: { $0.name == "docs" })?.id
        return SidebarTreePresentation.visibleNodes(
            from: store.rootNode?.children ?? [],
            expandedFolderIDs: Set([docsID].compactMap { $0 })
        )
    }

    func listing() -> [String] {
        (FileManager.default.subpaths(atPath: workspaceURL.path) ?? []).sorted()
    }

    /// Window-coordinate frame of the row named `labelPrefix`, from the sidebar's row geometry.
    func frameOfRow(labelPrefix: String) -> NSRect? {
        guard let documentView = treeDocumentView(),
              let index = visibleRows().firstIndex(where: { $0.displayName == labelPrefix })
        else { return nil }
        let theme = AppTheme.defaultDark
        let rowHeight = MonknotMetrics.scale(30, theme: theme, zoomScale: 1)
        let spacing = MonknotMetrics.scale(2, theme: theme, zoomScale: 1)
        let top = MonknotMetrics.scale(6, theme: theme, zoomScale: 1)
        let y = top + CGFloat(index) * (rowHeight + spacing)
        let local = NSRect(x: 20, y: y, width: documentView.bounds.width - 40, height: rowHeight)
        let flippedLocal = documentView.isFlipped
            ? local
            : NSRect(x: local.minX, y: documentView.bounds.height - local.maxY, width: local.width, height: local.height)
        return documentView.convert(flippedLocal, to: nil)
    }

    /// Mouse down at `start`, twelve drag steps, mouse up at `end`; equal points make a click.
    func drag(from start: NSPoint, to end: NSPoint) async {
        var timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent? {
            timestamp += 0.016
            return NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        guard let down = event(.leftMouseDown, start, 1) else { return }
        window.sendEvent(down)
        try? await Task.sleep(nanoseconds: 30_000_000)
        if start != end {
            let steps = 12
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                if let dragged = event(.leftMouseDragged, point, 1 + step) {
                    window.sendEvent(dragged)
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        if let up = event(.leftMouseUp, end, 100) {
            window.sendEvent(up)
        }
    }
}
