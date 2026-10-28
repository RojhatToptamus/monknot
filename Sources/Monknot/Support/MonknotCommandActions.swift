import AppKit
import MonknotCore
import SwiftUI

struct MonknotCommandActions {
    let newMarkdown: () -> Void
    let newDailyNote: () -> Void
    let newFile: () -> Void
    let newFolder: () -> Void
    let canCreateItems: Bool
    let openFolder: () -> Void
    let workspaceNames: [String]
    let switchWorkspaceAtIndex: (Int) -> Void
    let exportPDF: () -> Void
    let canExportPDF: Bool
    let exportPDFAnnotationsMarkdown: () -> Void
    let canExportPDFAnnotationsMarkdown: Bool
    let exportAllPDFAnnotationsMarkdown: () -> Void
    let canExportAllPDFAnnotationsMarkdown: Bool
    let exportAnnotatedPDFCopy: () -> Void
    let canExportAnnotatedPDFCopy: Bool
    let saveDocument: () -> Void
    let saveAllDocuments: () -> Void
    let canSaveAllDocuments: Bool
    let undoPDFAnnotation: () -> Void
    let canUndoPDFAnnotation: Bool
    let redoPDFAnnotation: () -> Void
    let canRedoPDFAnnotation: Bool
    let isPDFDocumentActive: Bool
    let cut: () -> Void
    let copy: () -> Void
    let copyRenderedMarkdown: () -> Void
    let canCopyRenderedMarkdown: Bool
    let paste: () -> Void
    let selectAll: () -> Void
    let refreshWorkspace: () -> Void
    let navigateBack: () -> Void
    let canNavigateBack: Bool
    let navigateForward: () -> Void
    let canNavigateForward: Bool
    let closeTab: () -> Void
    let canCloseTab: Bool
    let reopenClosedTab: () -> Void
    let canReopenClosedTab: Bool
    let togglePinTab: () -> Void
    let canTogglePinTab: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let showFind: () -> Void
    let canShowFind: Bool
    let showWorkspaceSearch: () -> Void
    let showQuickOpen: () -> Void
    let canShowQuickOpen: Bool
    let showGoToLine: () -> Void
    let canShowGoToLine: Bool
    let toggleLinkInspection: () -> Void
    let canInspectLinks: Bool
    let findNext: () -> Void
    let findPrevious: () -> Void
    let isSearchCaseSensitive: Bool
    let setSearchCaseSensitive: (Bool) -> Void
    let isSearchWholeWord: Bool
    let setSearchWholeWord: (Bool) -> Void
    let canConfigureSearch: Bool
    let toggleTerminal: () -> Void
    let toggleTerminalFullscreen: () -> Void
    let canToggleTerminalFullscreen: Bool
    let toggleSidebar: () -> Void
    let toggleSplitView: () -> Void
    let canToggleSplitView: Bool
    let togglePDFNavigator: () -> Void
    let canTogglePDFNavigator: Bool
    let copyPDFLinkedExcerpt: () -> Void
    let canCopyPDFLinkedExcerpt: Bool
    let showKeyboardShortcutsHelp: () -> Void
    let undoWorkspaceReplace: () -> Void
    let canUndoWorkspaceReplace: Bool
    let undoFileOperation: () -> Void
    let redoFileOperation: () -> Void
    /// The sidebar's last move or copy, as Edit › Undo names it ("Move “a.md”"); nil when there is
    /// none to undo now.
    let fileOperationUndoActionName: String?
    let fileOperationRedoActionName: String?
    /// Whether a move or copy waiting to be undone is newer than the workspace Replace that can be
    /// undone, even while it cannot run (another operation is under way).
    let fileOperationUndoPrecedesWorkspaceReplace: Bool
}

private struct MonknotCommandActionsKey: FocusedValueKey {
    typealias Value = MonknotCommandActions
}

extension FocusedValues {
    var monknotCommandActions: MonknotCommandActions? {
        get { self[MonknotCommandActionsKey.self] }
        set { self[MonknotCommandActionsKey.self] = newValue }
    }
}

struct MonknotCommandMenu: Commands {
    @FocusedValue(\.monknotCommandActions) private var actions
    @AppStorage(EditorTextCheckingOptions.spellingPreferenceKey)
    private var checksSpelling = EditorTextCheckingOptions.defaultChecksSpelling
    @AppStorage(EditorTextCheckingOptions.grammarPreferenceKey)
    private var checksGrammar = EditorTextCheckingOptions.defaultChecksGrammar
    @AppStorage(PDFPageAppearance.preferenceKey)
    private var pdfPageAppearance = PDFPageAppearance.original

    private var undoDestination: MonknotUndoCommandDestination {
        monknotUndoCommandDestination(
            isPDFDocumentActive: actions?.isPDFDocumentActive == true,
            hasNativeEditingFocus: MonknotNativePasteboardCommand.hasNativeEditingFocus,
            terminalHasFocus: MonknotNativeUndoCommand.terminalHasFocus,
            documentViewHasFocus: MonknotNativeUndoCommand.documentViewHasFocus,
            canPerformNative: MonknotNativeUndoCommand.canUndo,
            canPerformWorkspaceReplace: actions?.canUndoWorkspaceReplace == true,
            canPerformFileOperation: actions?.fileOperationUndoActionName != nil,
            fileOperationIsNewer: actions?.fileOperationUndoPrecedesWorkspaceReplace == true,
            canPerformPDF: actions?.canUndoPDFAnnotation == true
        )
    }

    private var redoDestination: MonknotUndoCommandDestination {
        monknotUndoCommandDestination(
            isPDFDocumentActive: actions?.isPDFDocumentActive == true,
            hasNativeEditingFocus: MonknotNativePasteboardCommand.hasNativeEditingFocus,
            terminalHasFocus: MonknotNativeUndoCommand.terminalHasFocus,
            documentViewHasFocus: MonknotNativeUndoCommand.documentViewHasFocus,
            canPerformNative: MonknotNativeUndoCommand.canRedo,
            canPerformFileOperation: actions?.fileOperationRedoActionName != nil,
            canPerformPDF: actions?.canRedoPDFAnnotation == true
        )
    }

    /// "Undo Move “a.md”" while Undo takes back a move or copy; otherwise "Undo".
    private var undoTitle: String {
        guard undoDestination == .fileOperation, let name = actions?.fileOperationUndoActionName else { return "Undo" }
        return "Undo \(name)"
    }

    private var redoTitle: String {
        guard redoDestination == .fileOperation, let name = actions?.fileOperationRedoActionName else { return "Redo" }
        return "Redo \(name)"
    }

    /// One property per menu group, so each type-checks quickly.
    var body: some Commands {
        newItemCommands
        workspaceMenu
        saveCommands
        undoRedoCommands
        pasteboardCommands
        writingCommands
        exportCommands
        viewCommands
        helpCommands
    }

    private var newItemCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Markdown") {
                actions?.newMarkdown()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(actions == nil)

            Button("Daily Note") {
                actions?.newDailyNote()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("New File…") {
                actions?.newFile()
            }
            .disabled(actions?.canCreateItems != true)

            Button("New Folder…") {
                actions?.newFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(actions?.canCreateItems != true)

            Button("Add Workspace…") {
                actions?.openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(actions == nil)
        }
    }

    private var workspaceMenu: some Commands {
        CommandMenu("Workspace") {
            if let actions {
                ForEach(Array(actions.workspaceNames.prefix(9).enumerated()), id: \.offset) { index, name in
                    Button(name) {
                        actions.switchWorkspaceAtIndex(index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: [.control, .command]
                    )
                }

                if !actions.workspaceNames.isEmpty {
                    Divider()
                }
            }

            Button("Refresh") {
                actions?.refreshWorkspace()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button("Pin or Unpin Tab") {
                actions?.togglePinTab()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(actions?.canTogglePinTab != true)

            Divider()

            Button("Toggle Terminal") {
                actions?.toggleTerminal()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(actions == nil)

            Button("Toggle Terminal Fullscreen") {
                actions?.toggleTerminalFullscreen()
            }
            .keyboardShortcut(.return, modifiers: [.command, .control])
            .disabled(actions?.canToggleTerminalFullscreen != true)

            Button("Toggle Sidebar") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(actions == nil)
        }
    }

    private var saveCommands: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                actions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(actions?.canCloseTab != true)

            Button("Reopen Closed Tab") {
                actions?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions?.canReopenClosedTab != true)

            Button("Save") {
                actions?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(actions == nil)

            Button("Save All") {
                actions?.saveAllDocuments()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(actions?.canSaveAllDocuments != true)
        }
    }

    private var undoRedoCommands: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                switch undoDestination {
                case .native:
                    _ = MonknotNativeUndoCommand.performUndoIfAvailable()
                case .workspaceReplace:
                    actions?.undoWorkspaceReplace()
                case .fileOperation:
                    actions?.undoFileOperation()
                case .pdf:
                    actions?.undoPDFAnnotation()
                case .unavailable:
                    break
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(undoDestination == .unavailable)

            Button(redoTitle) {
                switch redoDestination {
                case .native:
                    _ = MonknotNativeUndoCommand.performRedoIfAvailable()
                case .workspaceReplace:
                    break
                case .fileOperation:
                    actions?.redoFileOperation()
                case .pdf:
                    actions?.redoPDFAnnotation()
                case .unavailable:
                    break
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(redoDestination == .unavailable)
        }
    }

    private var pasteboardCommands: some Commands {
        CommandGroup(replacing: .pasteboard) {
            editingButton("Cut", key: "x", perform: { $0.cut() }) {
                MonknotNativePasteboardCommand.performCutIfAvailable()
            }

            editingButton("Copy", key: "c", perform: { $0.copy() }) {
                MonknotNativePasteboardCommand.performCopyIfAvailable()
            }

            Button("Copy Rendered Markdown") {
                actions?.copyRenderedMarkdown()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(actions?.canCopyRenderedMarkdown != true)

            Button("Copy Linked Excerpt") {
                actions?.copyPDFLinkedExcerpt()
            }
            .disabled(actions?.canCopyPDFLinkedExcerpt != true)

            editingButton("Paste", key: "v", perform: { $0.paste() }) {
                MonknotNativePasteboardCommand.performPasteIfAvailable()
            }

            Divider()

            editingButton("Select All", key: "a", perform: { $0.selectAll() }) {
                MonknotNativePasteboardCommand.performSelectAllIfAvailable()
            }
        }
    }

    /// Cut, Copy, Paste and Select All go through the workspace window's actions, or straight to the
    /// focused text when no workspace window is focused.
    private func editingButton(
        _ title: String,
        key: KeyEquivalent,
        perform: @escaping (MonknotCommandActions) -> Void,
        performNatively: @escaping () -> Bool
    ) -> some View {
        Button(title) {
            if let actions {
                perform(actions)
            } else {
                _ = performNatively()
            }
        }
        .keyboardShortcut(key, modifiers: [.command])
        .disabled(actions == nil && !MonknotNativePasteboardCommand.hasNativeEditingFocus)
    }

    private var writingCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            if #available(macOS 15.2, *) {
                Button("Show Writing Tools…") {
                    _ = MonknotNativeWritingToolsCommand.showWritingTools()
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(!MonknotNativeWritingToolsCommand.canShowWritingTools)

                Divider()
            }

            Menu("Spelling and Grammar") {
                Button("Check Document Now") {
                    _ = MonknotNativeSpellingCommand.checkSpelling()
                }
                .keyboardShortcut(";", modifiers: [.command])
                .disabled(!MonknotNativeSpellingCommand.canCheckDocument)

                Divider()

                Toggle("Check Spelling While Typing", isOn: $checksSpelling)
                Toggle("Check Grammar While Typing", isOn: $checksGrammar)
            }
        }
    }

    private var exportCommands: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Export PDF…") {
                actions?.exportPDF()
            }
            .disabled(actions?.canExportPDF != true)

            Button("Export PDF Annotations as Markdown…") {
                actions?.exportPDFAnnotationsMarkdown()
            }
            .disabled(actions?.canExportPDFAnnotationsMarkdown != true)

            Button("Export All PDF Annotations as Markdown…") {
                actions?.exportAllPDFAnnotationsMarkdown()
            }
            .disabled(actions?.canExportAllPDFAnnotationsMarkdown != true)

            Button("Export Annotated PDF Copy…") {
                actions?.exportAnnotatedPDFCopy()
            }
            .disabled(actions?.canExportAnnotatedPDFCopy != true)
        }
    }

    private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Toggle Split Editor") {
                actions?.toggleSplitView()
            }
            .keyboardShortcut("\\", modifiers: [.command])
            .disabled(actions?.canToggleSplitView != true)

            Button("Toggle PDF Navigator") {
                actions?.togglePDFNavigator()
            }
            .disabled(actions?.canTogglePDFNavigator != true)

            Picker("PDF Pages", selection: $pdfPageAppearance) {
                ForEach(PDFPageAppearance.allCases, id: \.self) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }

            Divider()

            Button("Back") {
                actions?.navigateBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(actions?.canNavigateBack != true)

            Button("Forward") {
                actions?.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(actions?.canNavigateForward != true)

            Divider()

            Button("Quick Open…") {
                actions?.showQuickOpen()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(actions?.canShowQuickOpen != true)

            Button("Go to Line…") {
                actions?.showGoToLine()
            }
            .disabled(actions?.canShowGoToLine != true)

            Button("Inspect Links") {
                actions?.toggleLinkInspection()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(actions?.canInspectLinks != true)

            Button("Find") {
                if !MonknotNativeTerminalSearchCommand.performIfFocused(.show) {
                    actions?.showFind()
                }
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(
                actions?.canShowFind != true
                    && !MonknotNativeTerminalSearchCommand.hasTerminalFocus
            )

            Button("Find in Workspace") {
                actions?.showWorkspaceSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Find Next") {
                if !MonknotNativeTerminalSearchCommand.performIfFocused(.next) {
                    actions?.findNext()
                }
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(actions == nil)

            Button("Find Previous") {
                if !MonknotNativeTerminalSearchCommand.performIfFocused(.previous) {
                    actions?.findPrevious()
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Toggle(
                "Match Case",
                isOn: Binding(
                    get: { actions?.isSearchCaseSensitive == true },
                    set: { actions?.setSearchCaseSensitive($0) }
                )
            )
            .disabled(actions?.canConfigureSearch != true)

            Toggle(
                "Match Whole Word",
                isOn: Binding(
                    get: { actions?.isSearchWholeWord == true },
                    set: { actions?.setSearchWholeWord($0) }
                )
            )
            .disabled(actions?.canConfigureSearch != true)

            Divider()

            Button("Zoom In") {
                if !MonknotNativePDFZoomCommand.performIfFocused(.zoomIn) {
                    actions?.zoomIn()
                }
            }
            .keyboardShortcut("=", modifiers: [.command])
            .disabled(actions == nil)

            Button("Zoom Out") {
                if !MonknotNativePDFZoomCommand.performIfFocused(.zoomOut) {
                    actions?.zoomOut()
                }
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(actions == nil)

            Button("Actual Size") {
                if !MonknotNativePDFZoomCommand.performIfFocused(.actualSize) {
                    actions?.resetZoom()
                }
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(actions == nil)

            Menu("Interface Zoom") {
                Button("Zoom In") {
                    actions?.zoomIn()
                }

                Button("Zoom Out") {
                    actions?.zoomOut()
                }

                Divider()

                Button("Reset Zoom") {
                    actions?.resetZoom()
                }
            }
            .disabled(actions == nil)
        }
    }

    private var helpCommands: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                actions?.showKeyboardShortcutsHelp()
            }
            .disabled(actions == nil)
        }
    }
}

enum MonknotUndoCommandDestination: Equatable {
    case native
    case workspaceReplace
    case fileOperation
    case pdf
    case unavailable
}

func monknotUndoCommandDestination(
    isPDFDocumentActive: Bool,
    hasNativeEditingFocus: Bool,
    terminalHasFocus: Bool = false,
    documentViewHasFocus: Bool = false,
    canPerformNative: Bool,
    canPerformWorkspaceReplace: Bool = false,
    canPerformFileOperation: Bool = false,
    fileOperationIsNewer: Bool = false,
    canPerformPDF: Bool
) -> MonknotUndoCommandDestination {
    // A workspace Replace is undone only while no move or copy made after it waits to be undone:
    // its undo writes notes back by path, and the newer operation may have moved them.
    let replaceIsNext = canPerformWorkspaceReplace && !fileOperationIsNewer
    // The terminal keeps ⌘Z and ⇧⌘Z for its shell. The window's undo manager it would otherwise
    // reach holds the editor's edits.
    if terminalHasFocus {
        return .unavailable
    }
    if hasNativeEditingFocus {
        if canPerformNative {
            return .native
        }
        // Nothing to undo in the focused text: the workspace Replace All is next, as its
        // confirmation promises that ⌘Z undoes it. A file move never is: the text keeps ⌘Z.
        return replaceIsNext ? .workspaceReplace : .unavailable
    }
    // Moves and copies are undone with focus anywhere but text, the terminal or a document view,
    // which keep their own undo. Of a move and a Replace, the newer goes first.
    if canPerformFileOperation, !documentViewHasFocus, fileOperationIsNewer || !canPerformWorkspaceReplace {
        return .fileOperation
    }
    if replaceIsNext {
        return .workspaceReplace
    }
    if isPDFDocumentActive {
        return canPerformPDF ? .pdf : .unavailable
    }
    return canPerformNative ? .native : .unavailable
}
