import AppKit
import SwiftUI

struct WindowBackgroundDragEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(from: nsView)
    }

    private func updateWindow(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.isMovableByWindowBackground = true
        }
    }
}
