import AppKit
import SwiftUI

/// Aligns the NSWindow's appearance with our SwiftUI surface, keeps the native
/// window controls centered in Monknot's primary chrome row, and suppresses
/// the AppKit-injected `.toolbarButton`, which duplicates our sidebar toggle.
/// Uses AppKit's standard controls rather than recreating the traffic lights:
/// https://developer.apple.com/documentation/appkit/nswindow/standardwindowbutton(_:)
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var chromeHeight: CGFloat
    var suppressToolbarButton: Bool = true
    var usesDarkAppearance: Bool?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            chromeHeight: chromeHeight,
            suppressToolbarButton: suppressToolbarButton
        )
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
            if let usesDarkAppearance {
                window.appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
            }

            coordinator.observeWindow(window)
            coordinator.configureWindowChrome(in: window)
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

    fileprivate static func alignStandardWindowButtons(
        in window: NSWindow,
        chromeHeight: CGFloat
    ) {
        guard chromeHeight > 0 else { return }

        let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton,
            .miniaturizeButton,
            .zoomButton
        ]
        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType),
                  !button.isHidden,
                  let superview = button.superview
            else {
                continue
            }

            let titlebarTopY = superview.isFlipped
                ? superview.bounds.minY
                : superview.bounds.maxY
            let targetOriginY = NativeWindowChromeGeometry.centeredButtonOriginY(
                buttonHeight: button.frame.height,
                chromeHeight: chromeHeight,
                contentTopY: titlebarTopY,
                isFlipped: superview.isFlipped
            )
            guard abs(button.frame.minY - targetOriginY) > 0.25 else { continue }

            superview.clipsToBounds = false
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: targetOriginY))
        }
    }

    final class Coordinator {
        var chromeHeight: CGFloat
        let suppressToolbarButton: Bool
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var pendingChromeUpdate: DispatchWorkItem?

        init(chromeHeight: CGFloat, suppressToolbarButton: Bool) {
            self.chromeHeight = chromeHeight
            self.suppressToolbarButton = suppressToolbarButton
        }

        deinit {
            pendingChromeUpdate?.cancel()
            removeObservers()
        }

        func observeWindow(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            removeObservers()
            observedWindow = window

            let center = NotificationCenter.default
            let windowLayoutNames: [NSNotification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didUpdateNotification
            ]
            for name in windowLayoutNames {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let window, let self else { return }
                    self.scheduleWindowChromeUpdate(in: window)
                }
                observers.append(token)
            }
        }

        func configureWindowChrome(in window: NSWindow) {
            if suppressToolbarButton {
                WindowBackgroundDragEnabler.suppressSystemToolbarButton(in: window)
            }
            WindowBackgroundDragEnabler.alignStandardWindowButtons(
                in: window,
                chromeHeight: chromeHeight
            )
        }

        private func scheduleWindowChromeUpdate(in window: NSWindow) {
            pendingChromeUpdate?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                self.configureWindowChrome(in: window)
            }
            pendingChromeUpdate = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver(_:))
            observers.removeAll()
        }
    }
}

enum NativeWindowChromeGeometry {
    static func centeredButtonOriginY(
        buttonHeight: CGFloat,
        chromeHeight: CGFloat,
        contentTopY: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return contentTopY + (chromeHeight - buttonHeight) / 2
        }
        return contentTopY - (chromeHeight + buttonHeight) / 2
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
