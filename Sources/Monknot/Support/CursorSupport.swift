import AppKit
import SwiftUI

extension View {
    func monknotPointerCursor(enabled: Bool = true) -> some View {
        modifier(PointerCursorModifier(isEnabled: enabled))
    }
}

private struct PointerCursorModifier: ViewModifier {
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    let isEnabled: Bool
    @State private var isHovering = false
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
            }
            .onChange(of: usePointerCursors) { _, _ in
                updateCursor()
            }
            .onChange(of: isEnabled) { _, _ in
                updateCursor()
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func updateCursor() {
        if usePointerCursors, isEnabled, isHovering {
            pushCursorIfNeeded()
        } else {
            popCursorIfNeeded()
        }
    }

    private func pushCursorIfNeeded() {
        guard !isCursorPushed else { return }
        NSCursor.pointingHand.push()
        isCursorPushed = true
    }

    private func popCursorIfNeeded() {
        guard isCursorPushed else { return }
        NSCursor.pop()
        isCursorPushed = false
    }
}
