import MonknotCore

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

private func context(
    hasWorkspace: Bool = true,
    selectedDocumentKind: WorkspaceDocumentKind? = nil,
    canCloseTab: Bool = false,
    canReopenClosedTab: Bool = false,
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
        canReopenClosedTab: canReopenClosedTab,
        canTogglePinTab: canTogglePinTab,
        canExportPDF: canExportPDF,
        canUndoPDFAnnotation: canUndoPDFAnnotation,
        canRedoPDFAnnotation: canRedoPDFAnnotation,
        isDocumentSearchPresented: isDocumentSearchPresented,
        isBusy: isBusy
    )
}

private func action(
    _ key: String,
    _ modifiers: MonknotKeyboardShortcutModifiers,
    keyCode: UInt16? = nil,
    context: MonknotKeyboardShortcutContext = context()
) -> MonknotKeyboardShortcutAction? {
    MonknotKeyboardShortcutRouter.action(
        for: MonknotKeyboardShortcutEvent(key: key, modifiers: modifiers, keyCode: keyCode),
        context: context
    )
}

expect(
    action("s", [.command], context: context(selectedDocumentKind: .markdown)) == .saveDocument,
    "Command-S should save an active editable document"
)
expect(
    action("s", [.command], context: context(selectedDocumentKind: nil)) == nil,
    "Command-S should not be consumed without an active document"
)
expect(
    action("x", [.command], context: context(selectedDocumentKind: .markdown)) == .cutDocument,
    "Command-X should cut the selected workspace file when no native text target handles it"
)
expect(
    action("c", [.command], context: context(selectedDocumentKind: .markdown)) == .copyDocument,
    "Command-C should copy the selected workspace file when an active document is selected"
)
expect(
    action("x", [.command], context: context(selectedDocumentKind: nil)) == nil,
    "Command-X should not be consumed without an active document"
)
expect(
    action("c", [.command], context: context(selectedDocumentKind: nil)) == nil,
    "Command-C should not be consumed without an active document"
)
expect(
    action("x", [.command], context: context(selectedDocumentKind: .markdown, isBusy: true)) == nil,
    "Command-X should not start a file cut during busy workspace operations"
)
expect(
    action("c", [.command], context: context(selectedDocumentKind: .markdown, isBusy: true)) == nil,
    "Command-C should not start a file copy during busy workspace operations"
)
expect(
    action("z", [.command], context: context(selectedDocumentKind: .pdf, canUndoPDFAnnotation: true)) == .undoPDFAnnotation,
    "Command-Z should undo PDF annotations when a PDF has undo history"
)
expect(
    action("z", [.command, .shift], context: context(selectedDocumentKind: .pdf, canRedoPDFAnnotation: true)) == .redoPDFAnnotation,
    "Shift-Command-Z should redo PDF annotations when a PDF has redo history"
)
expect(
    action("z", [.command], context: context(selectedDocumentKind: .markdown, canUndoPDFAnnotation: true)) == nil,
    "Command-Z should not steal NSTextView undo for Markdown"
)
expect(
    action("z", [.command], context: context(selectedDocumentKind: .pdf, canUndoPDFAnnotation: false)) == nil,
    "Command-Z should not be consumed for PDFs without undo history"
)
expect(
    action("f", [.command], context: context(selectedDocumentKind: .text)) == .showDocumentSearch,
    "Command-F should open document search for active text documents"
)
expect(
    action("f", [.command, .shift], context: context(hasWorkspace: true)) == .showWorkspaceSearch,
    "Shift-Command-F should open workspace search"
)
expect(
    action("g", [.command, .shift], context: context(selectedDocumentKind: .markdown)) == .findPrevious,
    "Shift-Command-G should find the previous document match"
)
expect(
    action("w", [.command], context: context(canCloseTab: true)) == .closeTab,
    "Command-W should close the active tab when one can be closed"
)
expect(
    action("t", [.command, .shift], context: context(canReopenClosedTab: true)) == .reopenClosedTab,
    "Shift-Command-T should reopen the most recently closed available tab"
)
expect(
    action("n", [.command], context: context(hasWorkspace: true, isBusy: true)) == nil,
    "Command-N should not start a new Markdown file during busy workspace operations"
)
expect(action("=", [.command]) == .zoomIn, "Command-= should zoom in")
expect(action("-", [.command]) == .zoomOut, "Command-- should zoom out")
expect(action("0", [.command]) == .resetZoom, "Command-0 should reset zoom")
expect(action("j", [.command, .option]) == .toggleTerminal, "Option-Command-J should toggle the terminal")
expect(action("s", [.command, .control]) == .toggleSidebar, "Control-Command-S should toggle the sidebar")
expect(action("o", [.command]) == .openFolder, "Command-O should open a folder")
expect(action("?", []) == nil, "Question mark should remain available for typing")
expect(action("?", [.shift]) == nil, "Question mark should remain available for typing")
expect(action("/", [.shift]) == nil, "Shift-/ should remain available for typing a question mark")
expect(action("a", [.command], context: context(selectedDocumentKind: .markdown)) == nil, "Command-A should remain a native Select All shortcut")
expect(action("f", [.control], context: context(selectedDocumentKind: .markdown)) == nil, "Control-F should remain a native text movement shortcut")
expect(
    action(
        "",
        [],
        keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
        context: context(isDocumentSearchPresented: true)
    ) == nil,
    "Nonmodal document search must not globally claim Escape"
)

if failures.isEmpty {
    print("MonknotShortcutSmokeTests passed")
} else {
    for failure in failures {
        print("FAIL: \(failure)")
    }
    fatalError("MonknotShortcutSmokeTests failed with \(failures.count) failure(s)")
}
