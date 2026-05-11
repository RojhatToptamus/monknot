import AppKit
import SwiftUI

/// Aligns the NSWindow's appearance with our SwiftUI surface (transparent
/// title bar painting through to `surfaceColor`), suppresses the AppKit-
/// injected `.toolbarButton` (duplicate of our own SwiftUI sidebar toggle),
/// and manually centers the close/min/zoom traffic lights vertically inside
/// the unified title-bar zone.
///
/// Why manual centering: SwiftUI's `.toolbar { ToolbarItem(placement:
/// .principal) ... }` (used in `ContentView`) successfully grows the
/// title-bar zone to `chromeHeight`, but AppKit does NOT re-center the
/// standard window buttons inside the grown zone — they stay at the OS
/// default y ≈ 14pt. We move them to chromeHeight/2 from the top so they
/// line up with our SwiftUI chrome icons.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var layoutToken: String
    var chromeHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(chromeHeight: chromeHeight)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.chromeHeight = chromeHeight
        updateWindow(from: nsView, coordinator: context.coordinator)
    }

    private func updateWindow(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(surfaceColor)
            window.isOpaque = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
                window.toolbarStyle = .unified
            }

            coordinator.observeWindow(window)
            Self.suppressSystemToolbarButton(in: window)
            Self.centerStandardButtons(in: window, chromeHeight: coordinator.chromeHeight)
        }
    }

    /// AppKit reinstalls `.toolbarButton` whenever the window changes state.
    /// Hide + remove it on every relevant notification so our own SwiftUI
    /// sidebar toggle is the only one visible.
    fileprivate static func suppressSystemToolbarButton(in window: NSWindow) {
        guard let button = window.standardWindowButton(.toolbarButton) else { return }
        button.isHidden = true
        button.removeFromSuperview()
    }

    /// Center the close / minimize / zoom buttons vertically inside the
    /// title-bar superview, with their center at `chromeHeight/2` from the
    /// top of that superview. SwiftUI's `.toolbar` principal item makes the
    /// superview tall enough that the resulting frame fits without clipping.
    fileprivate static func centerStandardButtons(in window: NSWindow, chromeHeight: CGFloat) {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type),
                  let superview = button.superview else { continue }

            // Cocoa coords: y=0 is the bottom of `superview`. We want the
            // button center at `chromeHeight/2` pt from the TOP, which is
            // `superview.bounds.height - chromeHeight/2` from the bottom.
            let centerYInSuperview = superview.bounds.height - (chromeHeight / 2)
            var frame = button.frame
            frame.origin.y = centerYInSuperview - (frame.height / 2)
            button.frame = frame.integral
        }
    }

    final class Coordinator {
        var chromeHeight: CGFloat
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(chromeHeight: CGFloat) {
            self.chromeHeight = chromeHeight
        }

        deinit {
            removeObservers()
        }

        func observeWindow(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            removeObservers()
            observedWindow = window

            let center = NotificationCenter.default
            let names: [NSNotification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didUpdateNotification
            ]
            for name in names {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let window, let self else { return }
                    WindowBackgroundDragEnabler.suppressSystemToolbarButton(in: window)
                    WindowBackgroundDragEnabler.centerStandardButtons(in: window, chromeHeight: self.chromeHeight)
                }
                observers.append(token)
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver(_:))
            observers.removeAll()
        }
    }
}

struct WindowDoubleClickZoomArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DoubleClickZoomView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DoubleClickZoomView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard event.buttonNumber == 0 else {
                super.mouseDown(with: event)
                return
            }

            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
