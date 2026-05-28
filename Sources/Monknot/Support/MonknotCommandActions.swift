import AppKit
import SwiftUI

struct MonknotCommandActions {
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let exportPDF: () -> Void
    let canExportPDF: Bool
    let saveDocument: () -> Void
    let cut: () -> Void
    let copy: () -> Void
    let paste: () -> Void
    let selectAll: () -> Void
    let refreshWorkspace: () -> Void
    let closeTab: () -> Void
    let canCloseTab: Bool
    let togglePinTab: () -> Void
    let canTogglePinTab: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let showFind: () -> Void
    let showWorkspaceSearch: () -> Void
    let findNext: () -> Void
    let findPrevious: () -> Void
    let toggleTerminal: () -> Void
    let toggleSidebar: () -> Void
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Markdown") {
                actions?.newMarkdown()
            }
            .keyboardShortcut("n", modifiers: [.command])
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
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(actions?.canExportPDF != true)
        }

        CommandGroup(after: .toolbar) {
            Button("Find in Document") {
                actions?.showFind()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(actions == nil)

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
                actions?.zoomIn()
            }
            .keyboardShortcut("=", modifiers: [.command])
            .disabled(actions == nil)

            Button("Zoom Out") {
                actions?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(actions == nil)

            Button("Actual Size") {
                actions?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(actions == nil)
        }
    }
}
