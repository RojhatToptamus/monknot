import AppKit
import SwiftUI

extension NSUserInterfaceItemIdentifier {
    static let monknotDocumentFocusTarget = Self("Monknot.DocumentFocusTarget")
    static let monknotSidebarFocusRegion = Self("Monknot.SidebarFocusRegion")
    static let monknotTerminalFocusRegion = Self("Monknot.TerminalFocusRegion")
}

/// Aligns the NSWindow's appearance with our SwiftUI surface and suppresses
/// the AppKit-injected `.toolbarButton`, which duplicates our sidebar toggle.
/// AppKit remains the owner of the native traffic-light controls and their
/// inter-button spacing, targets, accessibility, and window behavior.
struct WindowBackgroundDragEnabler: NSViewRepresentable {
    var surfaceColor: Color
    var suppressToolbarButton: Bool = true
    var trafficLightRowHeight: CGFloat?
    var trafficLightLeadingInset: CGFloat?
    var usesDarkAppearance: Bool?
    var windowTitle: String?
    var enablesStandardWindowControls = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            suppressToolbarButton: suppressToolbarButton,
            trafficLightRowHeight: trafficLightRowHeight,
            trafficLightLeadingInset: trafficLightLeadingInset,
            enablesStandardWindowControls: enablesStandardWindowControls
        )
    }

    func makeNSView(context: Context) -> WindowBackgroundDragAttachmentView {
        let view = WindowBackgroundDragAttachmentView(frame: .zero)
        updateWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: WindowBackgroundDragAttachmentView, context: Context) {
        context.coordinator.trafficLightRowHeight = trafficLightRowHeight
        context.coordinator.trafficLightLeadingInset = trafficLightLeadingInset
        updateWindow(from: nsView, coordinator: context.coordinator)
    }

    private func updateWindow(
        from view: WindowBackgroundDragAttachmentView,
        coordinator: Coordinator
    ) {
        let configureWindow = { [weak coordinator] (window: NSWindow) in
            guard let coordinator else { return }
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
        view.configureWindow = configureWindow
        view.configureAttachedWindow()
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
        var trafficLightLeadingInset: CGFloat?
        let enablesStandardWindowControls: Bool
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(
            suppressToolbarButton: Bool,
            trafficLightRowHeight: CGFloat? = nil,
            trafficLightLeadingInset: CGFloat? = nil,
            enablesStandardWindowControls: Bool = false
        ) {
            self.suppressToolbarButton = suppressToolbarButton
            self.trafficLightRowHeight = trafficLightRowHeight
            self.trafficLightLeadingInset = trafficLightLeadingInset
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
                guard let button = window.standardWindowButton(buttonType) else { return }
                button.isHidden = false
                button.isEnabled = true
            }
        }

        /// Keeps AppKit's real window buttons on the same optical centerline as
        /// Monknot's primary chrome row. Their relative spacing, targets,
        /// accessibility, and native window behavior remain AppKit-owned.
        private func alignTrafficLights(in window: NSWindow) {
            guard let trafficLightRowHeight,
                  trafficLightRowHeight > 0,
                  let referenceButton = window.standardWindowButton(.closeButton),
                  !referenceButton.isHidden,
                  let titlebarView = referenceButton.superview,
                  let titlebarContainer = titlebarView.superview,
                  let themeFrame = titlebarContainer.superview
            else {
                return
            }

            // Full-size content lets the custom chrome extend below AppKit's
            // default title-bar bounds. Keep the native title-bar hierarchy as
            // tall as that chrome so its real buttons remain hit-testable at
            // the same centerline where AppKit draws them.
            var containerFrame = titlebarContainer.frame
            let containerOriginY = themeFrame.isFlipped
                ? themeFrame.bounds.minY
                : themeFrame.bounds.maxY - trafficLightRowHeight
            if abs(containerFrame.minY - containerOriginY) > 0.25
                || abs(containerFrame.height - trafficLightRowHeight) > 0.25
            {
                containerFrame.origin.y = containerOriginY
                containerFrame.size.height = trafficLightRowHeight
                titlebarContainer.frame = containerFrame
            }
            if titlebarView.frame != titlebarContainer.bounds {
                titlebarView.frame = titlebarContainer.bounds
            }

            let horizontalOffset: CGFloat
            if let trafficLightLeadingInset {
                let nativeOpticalInset = max(
                    0,
                    (referenceButton.frame.width
                        - NativeWindowChromeGeometry.trafficLightDiameter) / 2
                )
                horizontalOffset = trafficLightLeadingInset
                    - nativeOpticalInset
                    - referenceButton.frame.minX
            } else {
                horizontalOffset = 0
            }

            let buttonTypes: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton,
            ]
            for buttonType in buttonTypes {
                guard let button = window.standardWindowButton(buttonType),
                      !button.isHidden,
                      button.superview === titlebarView
                else {
                    continue
                }

                let titlebarTopY = titlebarView.isFlipped
                    ? titlebarView.bounds.minY
                    : titlebarView.bounds.maxY
                let originY = NativeWindowChromeGeometry.centeredButtonOriginY(
                    buttonHeight: button.frame.height,
                    chromeHeight: trafficLightRowHeight,
                    contentTopY: titlebarTopY,
                    isFlipped: titlebarView.isFlipped
                )

                titlebarView.clipsToBounds = false
                let originX = button.frame.minX + horizontalOffset
                guard abs(button.frame.minX - originX) > 0.25
                    || abs(button.frame.minY - originY) > 0.25
                else {
                    continue
                }
                button.setFrameOrigin(NSPoint(x: originX, y: originY))
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver(_:))
            observers.removeAll()
        }
    }
}

/// Applies window-owned chrome only after AppKit has attached the bridge view.
/// A one-shot queued lookup can run before `view.window` exists and leave the
/// window unconfigured until an unrelated SwiftUI update occurs.
final class WindowBackgroundDragAttachmentView: NSView {
    var configureWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureAttachedWindow()
    }

    func configureAttachedWindow() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.configureWindow?(window)
        }
    }
}

enum NativeWindowChromeGeometry {
    static let trafficLightDiameter: CGFloat = 12

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

@MainActor
final class ApplicationTerminationCoordinator {
    typealias Handler = () async -> Bool

    private var handlers: [UUID: Handler] = [:]
    private var terminationTask: Task<Void, Never>?

    func register(id: UUID, handler: @escaping Handler) {
        handlers[id] = handler
    }

    func unregister(id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func resolveRegisteredHandlers() async -> Bool {
        for handler in Array(handlers.values) {
            guard await handler() else { return false }
        }
        return true
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard !handlers.isEmpty else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self, weak application] in
            guard let self else {
                application?.reply(toApplicationShouldTerminate: true)
                return
            }

            let shouldTerminate = await resolveRegisteredHandlers()
            terminationTask = nil
            application?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let terminationCoordinator: ApplicationTerminationCoordinator
    var shouldClose: () async -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            terminationCoordinator: terminationCoordinator,
            shouldClose: shouldClose
        )
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () async -> Bool
        private let terminationCoordinator: ApplicationTerminationCoordinator
        private let terminationHandlerID = UUID()
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?
        private var isConfirmedClose = false

        init(
            terminationCoordinator: ApplicationTerminationCoordinator,
            shouldClose: @escaping () async -> Bool
        ) {
            self.terminationCoordinator = terminationCoordinator
            self.shouldClose = shouldClose
        }

        deinit {
            let terminationCoordinator = terminationCoordinator
            let terminationHandlerID = terminationHandlerID
            Task { @MainActor in
                terminationCoordinator.unregister(id: terminationHandlerID)
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

            uninstall()

            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            terminationCoordinator.register(id: terminationHandlerID) { [weak self] in
                await self?.shouldClose() ?? true
            }
        }

        func uninstall() {
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
            terminationCoordinator.unregister(id: terminationHandlerID)
            window = nil
            previousDelegate = nil
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
