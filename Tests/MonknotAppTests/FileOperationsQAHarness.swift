import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// A real `SidebarView` hosted in a window over a real `WorkspaceStore`, driven the way a person
/// drives it: right-clicks build the row's real context menu, menu items are performed, and rows
/// are identified by what their own "Copy Path" item reports.
///
/// The sidebar's Copy, Cut and Paste use the harness's own private `pasteboard`, never
/// `NSPasteboard.general`. Never performs Reveal in Finder; the store's Move to Trash, from
/// `makeWorkspaceStore`, leaves the user's Trash alone.
@MainActor
final class QASidebarHarness {
    let store: WorkspaceStore
    let window: NSWindow
    let host: NSView
    let root: URL
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotQASidebar-\(UUID().uuidString)"))
    var copiedPaths: [URL] = []
    var copiedRelativePaths: [URL] = []
    var exportedPDFs: [String] = []
    var openedDocumentIDs: [String] = []

    init(store: WorkspaceStore, root: URL, theme: AppTheme = .defaultDark) {
        self.store = store
        self.root = root
        let defaults = UserDefaults(suiteName: "Monknot.QASidebar.\(UUID().uuidString)")!
        let library = WorkspaceLibraryStore(userDefaults: defaults)
        let search = WorkspaceSearchState()
        var copiedPathsSink: (URL) -> Void = { _ in }
        var copiedRelativeSink: (URL) -> Void = { _ in }
        var exportSink: (WorkspaceDocument) -> Void = { _ in }
        var openSink: (String) -> Void = { _ in }
        let view = SidebarView(
            store: store,
            workspaceLibrary: library,
            workspaceSearch: search,
            searchOptions: .constant(MonknotSearchOptions()),
            theme: theme,
            zoomScale: 1,
            openFolder: {},
            switchWorkspace: { _ in },
            removeWorkspace: { _ in },
            manageWorkspaces: {},
            newMarkdown: {},
            exportPDF: { exportSink($0) },
            openDocument: { id in openSink(id) },
            openWorkspaceSearchResult: { _ in },
            showWorkspaceSearch: {},
            dismissWorkspaceSearch: {},
            workspaceSearchFocusChanged: { _ in },
            copyPath: { copiedPathsSink($0) },
            copyRelativePath: { copiedRelativeSink($0) },
            newItemRequest: .constant(nil),
            pasteboard: pasteboard
        )
        .frame(width: 280, height: 640)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 640)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.host = host

        copiedPathsSink = { [weak self] in self?.copiedPaths.append($0.standardizedFileURL) }
        copiedRelativeSink = { [weak self] in self?.copiedRelativePaths.append($0.standardizedFileURL) }
        exportSink = { [weak self] in self?.exportedPDFs.append($0.id) }
        openSink = { [weak self] id in
            self?.openedDocumentIDs.append(id)
            _ = store.selectDocument(id: id)
        }
    }

    func close() {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
        window.contentView = nil
        pasteboard.releaseGlobally()
    }

    // MARK: Geometry

    private func treeScrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil,
               String(describing: type(of: scroll)).contains("SidebarNativeScrollView") {
                return scroll
            }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host)
    }

    var treeDocumentView: NSView? { treeScrollView()?.documentView }

    /// Window-coordinate rect of the tree row at `index` (0-based), from the row primitive's geometry.
    func rowRect(_ index: Int) -> NSRect? {
        guard let documentView = treeDocumentView else { return nil }
        let theme = AppTheme.defaultDark
        let rowHeight = MonknotMetrics.scale(30, theme: theme, zoomScale: 1)
        let spacing = MonknotMetrics.scale(2, theme: theme, zoomScale: 1)
        let top = MonknotMetrics.scale(6, theme: theme, zoomScale: 1)
        let y = top + CGFloat(index) * (rowHeight + spacing)
        let local = NSRect(x: 20, y: y, width: documentView.bounds.width - 40, height: rowHeight)
        let flipped = documentView.isFlipped
            ? local
            : NSRect(x: local.minX, y: documentView.bounds.height - local.maxY, width: local.width, height: local.height)
        return documentView.convert(flipped, to: nil)
    }

    func rowCenter(_ index: Int) -> NSPoint? {
        rowRect(index).map { NSPoint(x: $0.midX, y: $0.midY) }
    }

    /// A point in the tree's empty space below the last row.
    func emptyTreePoint() -> NSPoint? {
        guard let scroll = treeScrollView() else { return nil }
        let frame = scroll.convert(scroll.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.minY + 12)
    }

    // MARK: Context menus

    func rightMouseDown(at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    /// The context menu AppKit would show for a right-click at `point`: the hit view's menu, or
    /// the first one up its superview chain (NSView forwards an unanswered right-click upward).
    func contextMenu(at point: NSPoint) -> NSMenu? {
        guard let event = rightMouseDown(at: point),
              let contentView = window.contentView
        else { return nil }
        var view: NSView? = hitView(at: point, in: contentView)
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                return menu
            }
            view = current.superview
        }
        return nil
    }

    /// `hitTest` takes a point in the receiver's superview's coordinates.
    func hitView(at windowPoint: NSPoint, in contentView: NSView) -> NSView? {
        let point = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        return contentView.hitTest(point)
    }

    func contextMenu(row index: Int) -> NSMenu? {
        rowCenter(index).flatMap(contextMenu(at:))
    }

    static func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    static func item(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        menu?.items.first { $0.title == title }
    }

    @discardableResult
    func perform(_ title: String, in menu: NSMenu?) -> Bool {
        guard let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// The item the row at `index` acts on, as its own "Copy Path" item reports it.
    func rowURL(_ index: Int) -> URL? {
        guard let menu = contextMenu(row: index) else { return nil }
        let before = copiedPaths.count
        guard perform("Copy Path", in: menu), copiedPaths.count > before else { return nil }
        return copiedPaths.last
    }

    /// Workspace-relative paths of the tree rows on screen, top to bottom.
    func visibleRowPaths(maxRows: Int = 16) -> [String] {
        var result: [String] = []
        for index in 0..<maxRows {
            guard let url = rowURL(index), url != root.standardizedFileURL else { break }
            let rel = String(url.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if result.last == rel { break }
            result.append(rel)
        }
        return result
    }

    // MARK: Sheets

    var sheetWindow: NSWindow? { window.attachedSheet }

    func sheetTextField() -> NSTextField? {
        guard let content = sheetWindow?.contentView else { return nil }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(content)
    }

    /// Replaces the sheet's name with `name` the way typing does, then presses Return.
    func submitSheet(name: String, expectClose: Bool = true) async {
        guard let sheet = sheetWindow, let field = sheetTextField() else { return }
        sheet.makeKey()
        sheet.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 50_000_000)
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
        } else {
            field.stringValue = name
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let returnDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
        if let returnDown { sheet.sendEvent(returnDown) }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard expectClose else { return }
        let deadline = Date().addingTimeInterval(2)
        while window.attachedSheet != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Opens the sheet a menu item presents, waiting for any previous sheet to finish closing.
    func performAndWaitForSheet(_ title: String, in menu: NSMenu?) async -> Bool {
        var deadline = Date().addingTimeInterval(2)
        while window.attachedSheet != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard perform(title, in: menu) else { return false }
        deadline = Date().addingTimeInterval(2)
        while window.attachedSheet == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        return window.attachedSheet != nil
    }

    // MARK: Mouse

    func click(at point: NSPoint) async {
        await drag(from: point, to: point)
    }

    func drag(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
        var timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent? {
            timestamp += 0.016
            return NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: modifiers,
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

/// A scanner that can be held, so a file operation stays in flight while a test acts.
final class QAGatedScanner: WorkspaceDocumentScanning, @unchecked Sendable {
    private let base = WorkspaceDocumentScanner()
    private let lock = NSLock()
    private var gate: DispatchSemaphore?

    func hold() {
        lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock()
    }

    func release() {
        lock.lock(); let current = gate; gate = nil; lock.unlock()
        current?.signal()
    }

    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        lock.lock(); let current = gate; lock.unlock()
        if let current {
            _ = current.wait(timeout: .now() + 10)
            current.signal()
        }
        return try base.scan(rootURL: rootURL)
    }
}

/// Shared helpers for the file-operation and sidebar menu suites: real stores on temporary workspaces.
@MainActor
class FileOperationsQATestCase: WorkspaceStoreTestCase {
    // MARK: - Helpers

    func wait(timeout: TimeInterval = 6, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func makeRoot() throws -> URL {
        try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotQA").standardizedFileURL
    }

    func write(_ text: String, _ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func mkdir(_ relativePath: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    func names(_ relativePath: String, in root: URL) -> Set<String> {
        let path = relativePath.isEmpty ? root.path : root.appendingPathComponent(relativePath).path
        return Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
    }

    func openStore(
        _ root: URL,
        scanner: (any WorkspaceDocumentScanning)? = nil,
        selecting: String? = nil,
        keepWatcher: Bool = false
    ) async throws -> WorkspaceStore {
        let store = scanner.map { makeWorkspaceStore(scanner: $0) } ?? makeWorkspaceStore()
        store.openWorkspace(root, selecting: selecting.map { root.appendingPathComponent($0) })
        let loaded = await wait { !store.isBusy && store.rootNode != nil && store.workspaceURL != nil }
        XCTAssertTrue(loaded, "Workspace did not load")
        if !keepWatcher {
            store.testing_stopFileWatcher()
        }
        return store
    }

    func idle(_ store: WorkspaceStore) async {
        _ = await wait { !store.isBusy }
    }

    func settle(_ store: WorkspaceStore) async {
        _ = await wait { !store.isBusy }
        if let review = store.pendingMarkdownLinkMoveReview {
            store.confirmMarkdownLinkMoveReview(id: review.id)
            _ = await wait { !store.isBusy }
        }
    }

    func doc(_ store: WorkspaceStore, _ relativePath: String) -> WorkspaceDocument? {
        store.documents.first { $0.relativePath == relativePath }
    }

    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MonknotQA-\(UUID().uuidString)"))
    }

    func harness(_ store: WorkspaceStore, _ root: URL) async -> QASidebarHarness {
        let harness = QASidebarHarness(store: store, root: root)
        try? await Task.sleep(nanoseconds: 500_000_000)
        return harness
    }
}

/// A Finder drag as AppKit hands it to a drop target, over a private pasteboard.
final class QAFakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var window: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        self.pasteboard = pasteboard
        self.location = location
        self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic, .link] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4243 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension QASidebarHarness {
    /// The sidebar-wide Finder drop target (`FileURLDropTarget`).
    func sidebarDropView() -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("DropView") { return view }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host)
    }

    /// The tree scroll view's frame in window coordinates; Recents sit below it.
    func treeFrameInWindow() -> NSRect? {
        guard let documentView = treeDocumentView, let clip = documentView.superview, let scroll = clip.superview else { return nil }
        return scroll.convert(scroll.bounds, to: nil)
    }

    /// Context menus of the Recents rows, top to bottom (rows answer with an "Open" item).
    func recentsRowMenus() -> [NSMenu] {
        guard let tree = treeFrameInWindow() else { return [] }
        var menus: [NSMenu] = []
        var lastRowTop: CGFloat?
        var y = tree.minY - 2
        while y > 34 {
            if let menu = contextMenu(at: NSPoint(x: tree.midX, y: y)),
               menu.items.contains(where: { $0.title == "Open" }) {
                if lastRowTop == nil || lastRowTop! - y >= 30 {
                    menus.append(menu)
                    lastRowTop = y
                }
            }
            y -= 4
        }
        return menus
    }
}
