import SwiftUI

struct MarkprevCommandActions {
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let saveDocument: () -> Void
    let refreshWorkspace: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let toggleTerminal: () -> Void
}

private struct MarkprevCommandActionsKey: FocusedValueKey {
    typealias Value = MarkprevCommandActions
}

extension FocusedValues {
    var markprevCommandActions: MarkprevCommandActions? {
        get { self[MarkprevCommandActionsKey.self] }
        set { self[MarkprevCommandActionsKey.self] = newValue }
    }
}

struct MarkprevCommandMenu: Commands {
    @FocusedValue(\.markprevCommandActions) private var actions

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

            Button("Toggle Terminal") {
                actions?.toggleTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(actions == nil)
        }

        CommandGroup(after: .toolbar) {
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
