import XCTest
import MonknotCore

final class MonknotKeyboardShortcutRouterTests: XCTestCase {
    func testSaveShortcutRequiresASelectedDocument() {
        XCTAssertEqual(
            action(for: "s", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .saveDocument
        )

        XCTAssertNil(
            action(for: "s", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )
    }

    func testPDFUndoRedoShortcutsDoNotStealTextUndo() {
        XCTAssertEqual(
            action(
                for: "z",
                modifiers: [.command],
                context: shortcutContext(selectedDocumentKind: .pdf, canUndoPDFAnnotation: true)
            ),
            .undoPDFAnnotation
        )
        XCTAssertEqual(
            action(
                for: "z",
                modifiers: [.command, .shift],
                context: shortcutContext(selectedDocumentKind: .pdf, canRedoPDFAnnotation: true)
            ),
            .redoPDFAnnotation
        )

        XCTAssertNil(
            action(
                for: "z",
                modifiers: [.command],
                context: shortcutContext(selectedDocumentKind: .markdown, canUndoPDFAnnotation: true)
            )
        )
        XCTAssertNil(
            action(
                for: "z",
                modifiers: [.command, .shift],
                context: shortcutContext(selectedDocumentKind: .text, canRedoPDFAnnotation: true)
            )
        )
    }

    func testPDFUndoRedoShortcutsRespectUndoAvailability() {
        XCTAssertNil(
            action(for: "z", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .pdf))
        )
        XCTAssertNil(
            action(for: "z", modifiers: [.command, .shift], context: shortcutContext(selectedDocumentKind: .pdf))
        )
    }

    func testWorkspaceAndTabShortcutsRespectContext() {
        XCTAssertEqual(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: true)),
            .newMarkdown
        )
        XCTAssertNil(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: true, isBusy: true))
        )
        XCTAssertNil(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: false))
        )

        XCTAssertEqual(
            action(for: "w", modifiers: [.command], context: shortcutContext(canCloseTab: true)),
            .closeTab
        )
        XCTAssertNil(
            action(for: "w", modifiers: [.command], context: shortcutContext(canCloseTab: false))
        )

        XCTAssertEqual(
            action(for: "p", modifiers: [.command, .shift], context: shortcutContext(canTogglePinTab: true)),
            .togglePinTab
        )
        XCTAssertNil(
            action(for: "p", modifiers: [.command, .shift], context: shortcutContext(canTogglePinTab: false))
        )
    }

    func testPasteShortcutRequiresWorkspaceAndIdleState() {
        XCTAssertEqual(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: true)),
            .importPasteboard
        )
        XCTAssertNil(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: false))
        )
        XCTAssertNil(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: true, isBusy: true))
        )
    }

    func testFindSearchAndEscapeShortcutsRespectContext() {
        XCTAssertEqual(
            action(for: "f", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .showDocumentSearch
        )
        XCTAssertEqual(
            action(for: "f", modifiers: [.control], context: shortcutContext(selectedDocumentKind: .markdown)),
            .showDocumentSearch
        )
        XCTAssertNil(
            action(for: "f", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )

        XCTAssertEqual(
            action(for: "f", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: true)),
            .showWorkspaceSearch
        )
        XCTAssertNil(
            action(for: "f", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: false))
        )

        XCTAssertEqual(
            action(for: "g", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .findNext
        )
        XCTAssertEqual(
            action(for: "g", modifiers: [.command, .shift], context: shortcutContext(selectedDocumentKind: .markdown)),
            .findPrevious
        )
        XCTAssertEqual(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isDocumentSearchPresented: true)
            ),
            .dismissDocumentSearch
        )
        XCTAssertNil(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isDocumentSearchPresented: false)
            )
        )
    }

    func testZoomTerminalSidebarAndExportShortcuts() {
        XCTAssertEqual(action(for: "=", modifiers: [.command]), .zoomIn)
        XCTAssertEqual(action(for: "+", modifiers: [.command]), .zoomIn)
        XCTAssertEqual(action(for: "-", modifiers: [.command]), .zoomOut)
        XCTAssertEqual(action(for: "0", modifiers: [.command]), .resetZoom)
        XCTAssertEqual(action(for: "t", modifiers: [.command, .option]), .toggleTerminal)
        XCTAssertEqual(action(for: "s", modifiers: [.command, .control]), .toggleSidebar)
        XCTAssertEqual(action(for: "o", modifiers: [.command, .shift]), .openFolder)

        XCTAssertEqual(
            action(for: "p", modifiers: [.command], context: shortcutContext(canExportPDF: true)),
            .exportPDF
        )
        XCTAssertNil(
            action(for: "p", modifiers: [.command], context: shortcutContext(canExportPDF: false))
        )
    }

    private func action(
        for key: String,
        modifiers: MonknotKeyboardShortcutModifiers,
        keyCode: UInt16? = nil,
        context: MonknotKeyboardShortcutContext? = nil
    ) -> MonknotKeyboardShortcutAction? {
        MonknotKeyboardShortcutRouter.action(
            for: MonknotKeyboardShortcutEvent(key: key, modifiers: modifiers, keyCode: keyCode),
            context: context ?? shortcutContext()
        )
    }

    private func shortcutContext(
        hasWorkspace: Bool = true,
        selectedDocumentKind: WorkspaceDocumentKind? = nil,
        canCloseTab: Bool = false,
        canTogglePinTab: Bool = false,
        canExportPDF: Bool = false,
        canUndoPDFAnnotation: Bool = false,
        canRedoPDFAnnotation: Bool = false,
        isDocumentSearchPresented: Bool = false,
        isBusy: Bool = false
    ) -> MonknotKeyboardShortcutContext {
        MonknotKeyboardShortcutContext(
            hasWorkspace: hasWorkspace,
            hasSelectedDocument: selectedDocumentKind != nil,
            selectedDocumentKind: selectedDocumentKind,
            canCloseTab: canCloseTab,
            canTogglePinTab: canTogglePinTab,
            canExportPDF: canExportPDF,
            canUndoPDFAnnotation: canUndoPDFAnnotation,
            canRedoPDFAnnotation: canRedoPDFAnnotation,
            isDocumentSearchPresented: isDocumentSearchPresented,
            isBusy: isBusy
        )
    }
}
