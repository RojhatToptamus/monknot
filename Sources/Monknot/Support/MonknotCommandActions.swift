import SwiftUI

struct MonknotCommandActions {
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let exportPDF: () -> Void
    let canExportPDF: Bool
    let saveDocument: () -> Void
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
        CommandMenu("Workspace") {
            Button("New Markdown") {
                actions?.newMarkdown()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(actions == nil)

            Button("Open Folder...") {
                actions?.openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Save") {
                actions?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(actions == nil)

            Button("Refresh") {
                actions?.refreshWorkspace()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button("Close Tab") {
                actions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(actions?.canCloseTab != true)

            Button("Pin or Unpin Tab") {
                actions?.togglePinTab()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(actions?.canTogglePinTab != true)

            Divider()

            Button("Toggle Terminal") {
                actions?.toggleTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(actions == nil)

            Button("Toggle Sidebar") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(actions == nil)
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
            .keyboardShortcut("+", modifiers: [.command])
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
