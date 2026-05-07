import AppKit
import SwiftUI

/// Aligns NSWindow backing with the app theme so transparent title-bar regions
/// do not reveal a different system gray than SwiftUI’s `surfaceColor`.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var layoutToken: String
    var toolbarButtonSize: CGSize

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
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(surfaceColor)
            window.isOpaque = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }

            alignNativeTitlebarSidebarToggle(in: window)
            DispatchQueue.main.async {
                alignNativeTitlebarSidebarToggle(in: window)
            }
        }
    }

    private func alignNativeTitlebarSidebarToggle(in window: NSWindow) {
        guard let contentView = window.contentView,
              let button = window.standardWindowButton(.toolbarButton)
        else {
            return
        }

        button.isHidden = false
        button.isEnabled = true
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown
        align(button, withTopOf: contentView)
    }

    private func align(_ button: NSButton, withTopOf contentView: NSView) {
        guard let targetSuperview = button.superview else { return }

        let topInButtonSuperview = contentView.convert(
            NSPoint(x: contentView.bounds.minX, y: contentView.bounds.maxY),
            to: targetSuperview
        ).y
        let toolbarCenterY = topInButtonSuperview - 22

        var frame = button.frame
        frame.size = NSSize(width: toolbarButtonSize.width, height: toolbarButtonSize.height)
        frame.origin.y = toolbarCenterY - frame.height / 2
        button.frame = frame.integral
    }
}
