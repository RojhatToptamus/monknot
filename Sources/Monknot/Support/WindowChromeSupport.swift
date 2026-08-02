import AppKit
import SwiftUI

extension NSUserInterfaceItemIdentifier {
    static let monknotDocumentFocusTarget = Self("Monknot.DocumentFocusTarget")
}

/// Aligns the NSWindow's appearance with our SwiftUI surface and suppresses
/// the AppKit-injected `.toolbarButton`, which duplicates our sidebar toggle.
/// AppKit remains the sole owner of the traffic-light frames and all native
/// move, resize, minimize, zoom, and full-screen behavior.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var suppressToolbarButton: Bool = true
    var trafficLightRowHeight: CGFloat?
    var usesDarkAppearance: Bool?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            suppressToolbarButton: suppressToolbarButton,
            trafficLightRowHeight: trafficLightRowHeight
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.trafficLightRowHeight = trafficLightRowHeight
        updateWindow(from: nsView, coordinator: context.coordinator)
    }

    private func updateWindow(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Deliberate title-bar gaps opt in to dragging below. Making the
            // whole background draggable lets transparent controls and editor
            // gaps accidentally move the window.
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(surfaceColor)
            window.isOpaque = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
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

    final class Coordinator {
        let suppressToolbarButton: Bool
        var trafficLightRowHeight: CGFloat?
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(
            suppressToolbarButton: Bool,
            trafficLightRowHeight: CGFloat? = nil
        ) {
            self.suppressToolbarButton = suppressToolbarButton
            self.trafficLightRowHeight = trafficLightRowHeight
        }

        deinit {
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
                    guard let self, let window else { return }
                    self.configureWindowChrome(in: window)
                }
                observers.append(token)
            }
        }

        func configureWindowChrome(in window: NSWindow) {
            if suppressToolbarButton {
                WindowBackgroundDragEnabler.suppressSystemToolbarButton(in: window)
            }
            alignTrafficLights(in: window)
        }

        /// Keeps AppKit's real window buttons on the same optical centerline as
        /// Monknot's primary chrome row. Their horizontal positions, targets,
        /// accessibility, and native window behavior remain AppKit-owned.
        private func alignTrafficLights(in window: NSWindow) {
            guard let trafficLightRowHeight,
                  trafficLightRowHeight > 0,
                  let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarContainer = closeButton.superview
            else {
                return
            }

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0 }

            let largestHalfHeight = (buttons.map(\.frame.height).max() ?? 0) / 2
            let desiredCenterFromTop = trafficLightRowHeight / 2
            let maximumVisibleCenterFromTop = max(
                largestHalfHeight,
                titlebarContainer.bounds.height - largestHalfHeight
            )
            let centerFromTop = min(
                max(desiredCenterFromTop, largestHalfHeight),
                maximumVisibleCenterFromTop
            )

            for button in buttons where button.superview === titlebarContainer {
                let originY = titlebarContainer.bounds.maxY
                    - centerFromTop
                    - button.frame.height / 2
                guard abs(button.frame.minY - originY) > 0.25 else { continue }
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: originY))
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver(_:))
            observers.removeAll()
        }
    }
}

/// A deliberate title-bar gap. macOS 15+ uses SwiftUI's native
/// `WindowDragGesture`; macOS 14 falls back to AppKit's title-bar hit testing.
/// Neither path overrides mouse-down handling, so AppKit retains the user's
/// system double-click preference (Fill, Zoom, Minimize, or No Action).
/// https://developer.apple.com/documentation/swiftui/windowdraggesture
/// https://support.apple.com/guide/mac-help/mchlp1119/mac
struct WindowTitleBarDragArea: View {
    @ViewBuilder
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
        } else {
            NativeTitleBarDragRepresentable()
        }
    }

    private struct NativeTitleBarDragRepresentable: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            NativeTitleBarDragView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    final class NativeTitleBarDragView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            true
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
                self.install(on: window)
            }
        }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }

            if self.window?.delegate === self {
                self.window?.delegate = previousDelegate
            }

            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector)
                || previousDelegate?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true {
                return previousDelegate
            }
            return super.forwardingTarget(for: aSelector)
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
