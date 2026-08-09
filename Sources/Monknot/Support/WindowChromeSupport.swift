import AppKit
import SwiftUI

extension NSUserInterfaceItemIdentifier {
    static let monknotDocumentFocusTarget = Self("Monknot.DocumentFocusTarget")
}

/// Aligns the NSWindow's appearance with our SwiftUI surface and suppresses
/// the AppKit-injected `.toolbarButton`, which duplicates our sidebar toggle.
/// AppKit remains the owner of the native traffic-light controls and their
/// horizontal placement, targets, accessibility, and window behavior.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var suppressToolbarButton: Bool = true
    var trafficLightRowHeight: CGFloat?
    var usesDarkAppearance: Bool?
    var windowTitle: String?
    var enablesStandardWindowControls = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            suppressToolbarButton: suppressToolbarButton,
            trafficLightRowHeight: trafficLightRowHeight,
            enablesStandardWindowControls: enablesStandardWindowControls
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
            if let windowTitle {
                window.title = windowTitle
                window.titleVisibility = .visible
            } else {
                window.titleVisibility = .hidden
            }
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
        let enablesStandardWindowControls: Bool
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(
            suppressToolbarButton: Bool,
            trafficLightRowHeight: CGFloat? = nil,
            enablesStandardWindowControls: Bool = false
        ) {
            self.suppressToolbarButton = suppressToolbarButton
            self.trafficLightRowHeight = trafficLightRowHeight
            self.enablesStandardWindowControls = enablesStandardWindowControls
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
            if enablesStandardWindowControls {
                enableStandardWindowControls(in: window)
            }
            if suppressToolbarButton {
                WindowBackgroundDragEnabler.suppressSystemToolbarButton(in: window)
            }
            alignTrafficLights(in: window)
        }

        private func enableStandardWindowControls(in window: NSWindow) {
            window.styleMask.formUnion([.closable, .miniaturizable, .resizable])
            [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton,
            ].forEach { buttonType in
                window.standardWindowButton(buttonType)?.isEnabled = true
            }
        }

        /// Keeps AppKit's real window buttons on the same optical centerline as
        /// Monknot's primary chrome row. Their horizontal positions, targets,
        /// accessibility, and native window behavior remain AppKit-owned.
        private func alignTrafficLights(in window: NSWindow) {
            guard let trafficLightRowHeight,
                  trafficLightRowHeight > 0
            else {
                return
            }

            let buttonTypes: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton,
            ]
            for buttonType in buttonTypes {
                guard let button = window.standardWindowButton(buttonType),
                      !button.isHidden,
                      let titlebarContainer = button.superview
                else {
                    continue
                }

                let titlebarTopY = titlebarContainer.isFlipped
                    ? titlebarContainer.bounds.minY
                    : titlebarContainer.bounds.maxY
                let originY = NativeWindowChromeGeometry.centeredButtonOriginY(
                    buttonHeight: button.frame.height,
                    chromeHeight: trafficLightRowHeight,
                    contentTopY: titlebarTopY,
                    isFlipped: titlebarContainer.isFlipped
                )

                // Full-size content can make Monknot's chrome taller than
                // AppKit's standard titlebar container at larger zoom levels.
                titlebarContainer.clipsToBounds = false
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

/// A deliberate title-bar gap. AppKit handles window dragging and the standard
/// zoom transition, including retention of the user's previous window frame.
/// Controls never mount this view, so their mouse events remain independent.
/// https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:)
/// https://developer.apple.com/documentation/appkit/nswindow/performzoom(_:)
struct WindowTitleBarDragArea: View {
    var doubleClickZoomsWindow = true

    var body: some View {
        NativeTitleBarDragRepresentable(doubleClickZoomsWindow: doubleClickZoomsWindow)
    }

    private struct NativeTitleBarDragRepresentable: NSViewRepresentable {
        let doubleClickZoomsWindow: Bool

        func makeNSView(context: Context) -> NSView {
            let view = NativeTitleBarDragView(frame: .zero)
            view.doubleClickZoomsWindow = doubleClickZoomsWindow
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard let dragView = nsView as? NativeTitleBarDragView else { return }
            dragView.doubleClickZoomsWindow = doubleClickZoomsWindow
        }
    }

    final class NativeTitleBarDragView: NSView {
        var doubleClickZoomsWindow = true

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }

            if event.clickCount == 2 {
                guard doubleClickZoomsWindow else { return }
                guard window.styleMask.contains(.resizable),
                      !window.styleMask.contains(.fullScreen) else {
                    return
                }
                window.performZoom(self)
                return
            }

            window.performDrag(with: event)
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
