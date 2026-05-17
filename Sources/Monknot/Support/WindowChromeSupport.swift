import AppKit
import SwiftUI

/// Aligns the NSWindow's appearance with our SwiftUI surface and suppresses
/// the AppKit-injected `.toolbarButton`, which duplicates our own sidebar
/// toggle. Standard traffic-light positioning stays under AppKit's control;
/// moving those buttons manually causes visible jumps during split-view
/// relayout.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var layoutToken: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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
            coordinator.suppressDuplicateToolbarButton(in: window)
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

    final class Coordinator {
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

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
                    self.suppressDuplicateToolbarButton(in: window)
                }
                observers.append(token)
            }
        }

        func suppressDuplicateToolbarButton(in window: NSWindow) {
            WindowBackgroundDragEnabler.suppressSystemToolbarButton(in: window)
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

struct WindowCloseGuard: NSViewRepresentable {
    var shouldClose: () async -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installIfPossible(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.installIfPossible(from: nsView)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () async -> Bool
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?
        private var isConfirmedClose = false

        init(shouldClose: @escaping () async -> Bool) {
            self.shouldClose = shouldClose
        }

        deinit {
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
        }

        func installIfPossible(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                guard self.window !== window else { return }

                if self.window?.delegate === self {
                    self.window?.delegate = self.previousDelegate
                }

                self.window = window
                self.previousDelegate = window.delegate
                window.delegate = self
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isConfirmedClose {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }

            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender else { return }
                guard await self.shouldClose() else { return }

                self.isConfirmedClose = true
                sender.performClose(nil)
                self.isConfirmedClose = false
            }

            return false
        }
    }
}
