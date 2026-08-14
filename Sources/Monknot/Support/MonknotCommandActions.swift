import AppKit
import SwiftUI

struct MonknotCommandActions {
    let newMarkdown: () -> Void
    let newDailyNote: () -> Void
    let openFolder: () -> Void
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
    let toggleTerminal: () -> Void
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

    private var undoDestination: MonknotUndoCommandDestination {
        monknotUndoCommandDestination(
            isPDFDocumentActive: actions?.isPDFDocumentActive == true,
            hasNativeEditingFocus: MonknotNativePasteboardCommand.hasNativeEditingFocus,
            canPerformNative: MonknotNativeUndoCommand.canUndo,
            canPerformWorkspaceReplace: actions?.canUndoWorkspaceReplace == true,
            canPerformPDF: actions?.canUndoPDFAnnotation == true
        )
    }

    private var redoDestination: MonknotUndoCommandDestination {
        monknotUndoCommandDestination(
            isPDFDocumentActive: actions?.isPDFDocumentActive == true,
            hasNativeEditingFocus: MonknotNativePasteboardCommand.hasNativeEditingFocus,
            canPerformNative: MonknotNativeUndoCommand.canRedo,
            canPerformPDF: actions?.canRedoPDFAnnotation == true
        )
    }

    var body: some Commands {
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

            Button("Open Folder...") {
                actions?.openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(actions == nil)
        }

        CommandMenu("Workspace") {
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

            Button("Toggle Sidebar") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(actions == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                actions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(actions?.canCloseTab != true)

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

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                switch undoDestination {
                case .native:
                    _ = MonknotNativeUndoCommand.performUndoIfAvailable()
                case .workspaceReplace:
                    actions?.undoWorkspaceReplace()
                case .pdf:
                    actions?.undoPDFAnnotation()
                case .unavailable:
                    break
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(undoDestination == .unavailable)

            Button("Redo") {
                switch redoDestination {
                case .native:
                    _ = MonknotNativeUndoCommand.performRedoIfAvailable()
                case .workspaceReplace:
                    break
                case .pdf:
                    actions?.redoPDFAnnotation()
                case .unavailable:
                    break
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(redoDestination == .unavailable)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if let actions {
                    actions.cut()
                } else {
                    _ = MonknotNativePasteboardCommand.performCutIfAvailable()
                }
            }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(actions == nil && !MonknotNativePasteboardCommand.hasNativeEditingFocus)

            Button("Copy") {
                if let actions {
                    actions.copy()
                } else {
                    _ = MonknotNativePasteboardCommand.performCopyIfAvailable()
                }
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(actions == nil && !MonknotNativePasteboardCommand.hasNativeEditingFocus)

            Button("Copy Rendered Markdown") {
                actions?.copyRenderedMarkdown()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(actions?.canCopyRenderedMarkdown != true)

            Button("Copy Linked Excerpt") {
                actions?.copyPDFLinkedExcerpt()
            }
            .disabled(actions?.canCopyPDFLinkedExcerpt != true)

            Button("Paste") {
                if let actions {
                    actions.paste()
                } else {
                    _ = MonknotNativePasteboardCommand.performPasteIfAvailable()
                }
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(actions == nil && !MonknotNativePasteboardCommand.hasNativeEditingFocus)

            Divider()

            Button("Select All") {
                if let actions {
                    actions.selectAll()
                } else {
                    _ = MonknotNativePasteboardCommand.performSelectAllIfAvailable()
                }
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(actions == nil && !MonknotNativePasteboardCommand.hasNativeEditingFocus)
        }

        CommandGroup(replacing: .printItem) {
            Button("Export PDF...") {
                actions?.exportPDF()
            }
            .disabled(actions?.canExportPDF != true)

            Button("Export PDF Annotations as Markdown...") {
                actions?.exportPDFAnnotationsMarkdown()
            }
            .disabled(actions?.canExportPDFAnnotationsMarkdown != true)

            Button("Export All PDF Annotations as Markdown...") {
                actions?.exportAllPDFAnnotationsMarkdown()
            }
            .disabled(actions?.canExportAllPDFAnnotationsMarkdown != true)

            Button("Export Annotated PDF Copy...") {
                actions?.exportAnnotatedPDFCopy()
            }
            .disabled(actions?.canExportAnnotatedPDFCopy != true)
        }

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

            Button("Quick Open...") {
                actions?.showQuickOpen()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(actions?.canShowQuickOpen != true)

            Button("Go to Line...") {
                actions?.showGoToLine()
            }
            .disabled(actions?.canShowGoToLine != true)

            Button("Inspect Links") {
                actions?.toggleLinkInspection()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(actions?.canInspectLinks != true)

            Button("Find in Document") {
                actions?.showFind()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(actions?.canShowFind != true)

            Button("Find in Workspace") {
                actions?.showWorkspaceSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Find Next") {
                actions?.findNext()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(actions == nil)

            Button("Find Previous") {
                actions?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(actions == nil)

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
    case pdf
    case unavailable
}

func monknotUndoCommandDestination(
    isPDFDocumentActive: Bool,
    hasNativeEditingFocus: Bool,
    canPerformNative: Bool,
    canPerformWorkspaceReplace: Bool = false,
    canPerformPDF: Bool
) -> MonknotUndoCommandDestination {
    if hasNativeEditingFocus {
        return canPerformNative ? .native : .unavailable
    }
    if canPerformWorkspaceReplace {
        return .workspaceReplace
    }
    if isPDFDocumentActive {
        return canPerformPDF ? .pdf : .unavailable
    }
    return canPerformNative ? .native : .unavailable
}
