import AppKit
import MonknotCore
import SwiftUI

// MARK: - Placement

/// What a popover holds, which decides where its edge sits beside its control (design.md §5.9).
enum MonknotPopoverContentKind {
    /// Controls (Stroke Width, Text Style): the surface's leading edge on the control's.
    case form
    /// Menu rows in the 6 list inset (the workspace switcher): the surface sits 6 outside the
    /// control, so its rows share the control's edges and glyph column.
    case list

    var leadingOutsetBase: CGFloat {
        switch self {
        case .form: return 0
        case .list: return MonknotMetrics.menuListInsetBase
        }
    }
}

/// Where a popover's surface goes, in screen coordinates (design.md §5.9): 4 below its control with
/// their leading edges together; with no room below, 4 above it; where it would cross the screen's
/// trailing edge, or the window's while ending on the control's keeps it inside the window, their
/// trailing edges together, as a control's menu does (§5.1).
/// Only a surface that would still leave the screen is moved in, to 6 clear of its edge, so one that
/// fits keeps its edges on its control's. It grows from the corner that faces the control.
struct MonknotPopoverPlacement: Equatable {
    static let screenMargin: CGFloat = 6

    let surface: NSRect
    let growAnchor: UnitPoint
    let isAbove: Bool

    init(
        size: CGSize,
        control: NSRect,
        gap: CGFloat,
        leadingOutset: CGFloat,
        visibleFrame screen: NSRect,
        window: NSRect? = nil
    ) {
        let margin = Self.screenMargin
        var x = control.minX - leadingOutset
        var isTrailing = false
        let trailingX = control.maxX + leadingOutset - size.width
        let crossesWindow = window.map { x + size.width > $0.maxX && trailingX >= $0.minX } ?? false
        if x + size.width > screen.maxX || crossesWindow {
            x = trailingX
            isTrailing = true
        }
        if x < screen.minX || x + size.width > screen.maxX {
            x = min(max(x, screen.minX + margin), max(screen.minX + margin, screen.maxX - margin - size.width))
        }
        var y = control.minY - gap - size.height
        var isAbove = false
        if y < screen.minY, control.maxY + gap + size.height <= screen.maxY {
            y = control.maxY + gap
            isAbove = true
        }
        if y < screen.minY || y + size.height > screen.maxY {
            y = min(max(y, screen.minY + margin), max(screen.minY + margin, screen.maxY - margin - size.height))
        }
        surface = NSRect(x: x, y: y, width: size.width, height: size.height)
        self.isAbove = isAbove
        switch (isAbove, isTrailing) {
        case (false, false): growAnchor = .topLeading
        case (false, true): growAnchor = .topTrailing
        case (true, false): growAnchor = .bottomLeading
        case (true, true): growAnchor = .bottomTrailing
        }
    }
}

// MARK: - List

/// A row of a list popover that the keys move over (design.md §5.9), in the order it shows.
struct MonknotPopoverListRow {
    let id: String
    /// What typing matches, from its start.
    let title: String
    var isEnabled = true
    let choose: () -> Void
    /// What ⌫ does while the row is highlighted (a saved workspace's Remove); nil where it does nothing.
    var remove: (() -> Void)?
}

/// A list popover's one highlight (design.md §5.6, §5.9): the row the keys chose, the row the pointer
/// moved onto, or the row with keyboard focus, whichever moved last. Its rows draw it through
/// `MonknotMenuRowButtonStyle(isHighlighted:)`, so no row adds a hover of its own.
@MainActor
final class MonknotPopoverListModel: ObservableObject {
    /// What has keyboard focus in the list (Full Keyboard Access): a row, or a control inside one.
    enum Focus: Equatable {
        case row(String)
        case control
    }

    /// Set by the popover's control each time it draws.
    var rows: [MonknotPopoverListRow] = [] {
        didSet {
            if let highlighted, !isEnabled(highlighted) {
                self.highlighted = nil
            }
        }
    }

    @Published private(set) var highlighted: String?
    /// The row the pointer last moved onto, enabled or not: a workspace row shows Remove there.
    @Published private(set) var pointerRow: String?
    /// Counts the keys' and keyboard focus's moves, so the list scrolls the highlighted row into view
    /// and moves keyboard focus with it.
    @Published private(set) var keyboardMoves = 0
    private(set) var focus: Focus?
    /// Where the pointer was when the keys last moved the highlight, or the list opened: rows that
    /// scroll or appear under a pointer that holds still do not take the highlight from the keys.
    private var heldPointer: CGPoint?
    /// What a typed name can hold; Tab, the arrows and the function keys are not part of one.
    private static let nameCharacters = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols)
    private var typeSelection = ""
    private var typeSelectionTime: TimeInterval = 0

    var enabledRows: [MonknotPopoverListRow] {
        rows.filter(\.isEnabled)
    }

    func isEnabled(_ id: String) -> Bool {
        rows.contains { $0.id == id && $0.isEnabled }
    }

    var highlightedRow: MonknotPopoverListRow? {
        highlighted.flatMap { id in rows.first { $0.id == id && $0.isEnabled } }
    }

    private var focusedRowID: String? {
        if case .row(let id) = focus, isEnabled(id) {
            return id
        }
        return nil
    }

    /// The list opened under the pointer at `location`: it takes no row until it moves.
    func holdPointer(at location: CGPoint = NSEvent.mouseLocation) {
        heldPointer = location
    }

    /// Whether the pointer has moved since the keys last moved the highlight.
    private func pointerHasMoved(to location: CGPoint) -> Bool {
        guard let held = heldPointer else { return true }
        guard location != held else { return false }
        heldPointer = nil
        return true
    }

    /// The pointer moved over the row `id`: it takes the highlight, or clears it over a row that cannot
    /// be chosen, as in a context menu.
    func pointerMoved(onto id: String, at location: CGPoint = NSEvent.mouseLocation) {
        guard pointerHasMoved(to: location) else { return }
        if pointerRow != id {
            pointerRow = id
        }
        let target = isEnabled(id) ? id : nil
        if highlighted != target {
            highlighted = target
        }
    }

    /// The pointer left the row `id`: the highlight goes back to the row with keyboard focus, if any.
    func pointerLeft(_ id: String, at location: CGPoint = NSEvent.mouseLocation) {
        guard pointerHasMoved(to: location), pointerRow == id else { return }
        pointerRow = nil
        let fallback = focusedRowID
        if highlighted != fallback {
            highlighted = fallback
        }
    }

    /// Keyboard focus moved in the list: a focused row takes the highlight and scrolls into view. A
    /// control inside the highlighted row (Remove) leaves it there.
    func focusMoved(to focus: Focus?) {
        guard self.focus != focus else { return }
        self.focus = focus
        if case .row(let id) = focus, isEnabled(id) {
            highlightFromKeyboard(id)
        }
    }

    private func highlightFromKeyboard(_ id: String?) {
        heldPointer = NSEvent.mouseLocation
        if pointerRow != nil {
            pointerRow = nil
        }
        if highlighted != id {
            highlighted = id
        }
        keyboardMoves += 1
    }

    /// ↓ or ↑: the next or previous enabled row, without wrapping; from no highlight, the first or last.
    func moveHighlight(forward: Bool) {
        let enabled = enabledRows.map(\.id)
        guard !enabled.isEmpty else { return }
        guard let current = highlighted, let index = enabled.firstIndex(of: current) else {
            highlightFromKeyboard(forward ? enabled.first : enabled.last)
            return
        }
        highlightFromKeyboard(enabled[forward ? min(index + 1, enabled.count - 1) : max(index - 1, 0)])
    }

    /// Home or End: the first or last enabled row.
    func highlightEnd(last: Bool) {
        let enabled = enabledRows.map(\.id)
        guard !enabled.isEmpty else { return }
        highlightFromKeyboard(last ? enabled.last : enabled.first)
    }

    /// Whether a name is being typed, its last character less than a second ago, so a space extends it
    /// instead of choosing.
    func isTypeSelecting(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        !typeSelection.isEmpty && time - typeSelectionTime <= 1
    }

    /// Typing highlights the first enabled row whose title starts with what was typed; a pause of a
    /// second starts over. False for characters that cannot start a name.
    func typeSelect(_ characters: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let scalar = characters.unicodeScalars.first,
              characters == " " || Self.nameCharacters.contains(scalar)
        else { return false }
        if time - typeSelectionTime > 1 {
            typeSelection = ""
        }
        typeSelectionTime = time
        typeSelection += characters.lowercased()
        if let match = enabledRows.first(where: { $0.title.lowercased().hasPrefix(typeSelection) }) {
            highlightFromKeyboard(match.id)
        }
        return true
    }

    /// ⌫ on the highlighted row: removes it, and the highlight moves to the row that takes its place.
    func removeHighlighted() {
        guard let row = highlightedRow, let remove = row.remove else { return }
        let enabled = enabledRows.map(\.id)
        let index = enabled.firstIndex(of: row.id)
        let successor = index.flatMap { index in
            index + 1 < enabled.count ? enabled[index + 1] : (index > 0 ? enabled[index - 1] : nil)
        }
        remove()
        highlightFromKeyboard(successor)
    }
}

// MARK: - Surface

/// What the popover's surface draws: its content, and whether it has grown in yet.
@MainActor
final class MonknotPopoverModel: ObservableObject {
    @Published var content: AnyView
    @Published var theme: AppTheme
    @Published var zoomScale: Double
    @Published var growAnchor: UnitPoint = .topLeading
    /// False until the surface has been drawn once, so it grows in from its control.
    @Published var isShown = false
    /// A list's rows and its one highlight, which the content reads from its environment.
    let list = MonknotPopoverListModel()

    init(content: AnyView, theme: AppTheme, zoomScale: Double) {
        self.content = content
        self.theme = theme
        self.zoomScale = zoomScale
    }
}

/// The popover's floating surface (design.md §5.9): the context menu's — `surf2`, radius 12, `e2`, no
/// arrow — around the caller's content, which brings its own inset (the 6 list inset, or a form's 12).
struct MonknotPopoverSurface: View {
    @ObservedObject var model: MonknotPopoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = model.theme
        model.content
            .fixedSize()
            .monknotFloatingSurface(
                .e2,
                cornerRadius: theme.chromeRadius(MonknotMetrics.cardCornerRadius, zoomScale: model.zoomScale),
                fill: theme.elevatedSurfaceColor,
                theme: theme
            )
            .scaleEffect(model.isShown || reduceMotion ? 1 : MonknotMotion.surfaceEntranceScale, anchor: model.growAnchor)
            .opacity(model.isShown ? 1 : 0)
            .padding(MonknotPopoverController.shadowMargin)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .environmentObject(model.list)
    }
}

/// Tells the controller when the content asks for another size (a workspace removed from the
/// switcher), so the panel follows it.
final class MonknotPopoverHostingView: NSHostingView<MonknotPopoverSurface> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

// MARK: - Panel

/// The borderless panel a popover floats in. Unlike a context menu's, it becomes key, so its controls
/// take keyboard focus; it never becomes main, so the window it belongs to keeps its active titlebar
/// and chrome.
final class MonknotPopoverPanel: NSPanel {
    weak var controller: MonknotPopoverController?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.close()
    }
}

/// The panel's content view: VoiceOver reads it as a popover named for its control.
final class MonknotPopoverContainerView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .popover
    }
}

// MARK: - Controller

/// Shows every popover in the chrome on Monknot's floating surface (design.md §5.9): the workspace
/// switcher and the PDF bar's Stroke Width and Text Style. One shows at a time. It closes as a context
/// menu does — a click outside, Esc, scrolling outside, the window moving, resizing or closing, another
/// window or app taking focus — and gives keyboard focus back to the window and the control it had.
@MainActor
final class MonknotPopoverController {
    static let shared = MonknotPopoverController()

    /// How far beyond the surface its shadow reaches; the panel is this much larger on every side.
    static let shadowMargin: CGFloat = MonknotContextMenuController.shadowMargin
    /// The gap between the control and the surface.
    static let gapBase: CGFloat = 4
    /// Set by tests to take focus as Full Keyboard Access does, without changing the system setting.
    static var fullKeyboardAccessOverride: Bool?

    private static var isFullKeyboardAccessEnabled: Bool {
        fullKeyboardAccessOverride ?? NSApp.isFullKeyboardAccessEnabled
    }

    private struct Presentation {
        let id: UUID
        let panel: MonknotPopoverPanel
        let model: MonknotPopoverModel
        let hosting: MonknotPopoverHostingView
        weak var anchor: NSView?
        weak var window: NSWindow?
        /// What had keyboard focus in the window, given back when the popover closes.
        weak var restoredResponder: NSResponder?
        let contentKind: MonknotPopoverContentKind
        let onClose: (() -> Void)?
    }

    private var presentation: Presentation?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var isRelayoutScheduled = false

    var isOpen: Bool {
        presentation != nil
    }

    func isPresenting(_ id: UUID) -> Bool {
        presentation?.id == id
    }

    // MARK: Opening

    /// Shows `content` below `anchor` (above it where the screen ends) and gives it keyboard focus.
    /// Opened from the keyboard it appears at once; otherwise it grows in from the control over
    /// 150 ms. A list's `listRows` are what its keys move over. Nil when `anchor` is not in a window.
    @discardableResult
    func present(
        _ content: AnyView,
        label: String,
        from anchor: NSView,
        contentKind: MonknotPopoverContentKind,
        listRows: [MonknotPopoverListRow] = [],
        theme: AppTheme,
        zoomScale: Double,
        opensFromKeyboard: Bool = false,
        onClose: (() -> Void)? = nil
    ) -> UUID? {
        guard let window = anchor.window else { return nil }
        close(animated: false, restoresFocus: false)
        MonknotContextMenuController.shared.close(animated: false)

        let model = MonknotPopoverModel(content: content, theme: theme, zoomScale: zoomScale)
        model.list.rows = listRows
        model.list.holdPointer()
        let hosting = MonknotPopoverHostingView(rootView: MonknotPopoverSurface(model: model))
        let margin = Self.shadowMargin
        let panelSize = hosting.fittingSize
        let size = CGSize(width: max(1, panelSize.width - 2 * margin), height: max(1, panelSize.height - 2 * margin))
        let placement = Self.placement(size: size, anchor: anchor, in: window, contentKind: contentKind, theme: theme, zoomScale: zoomScale)
        model.growAnchor = placement.growAnchor

        let panelFrame = placement.surface.insetBy(dx: -margin, dy: -margin)
        let panel = MonknotPopoverPanel(contentRect: panelFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.controller = self
        panel.isFloatingPanel = false
        panel.level = window.level
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        panel.title = label

        let container = MonknotPopoverContainerView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.setAccessibilityLabel(label)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        let id = UUID()
        presentation = Presentation(
            id: id,
            panel: panel,
            model: model,
            hosting: hosting,
            anchor: anchor,
            window: window,
            restoredResponder: window.firstResponder,
            contentKind: contentKind,
            onClose: onClose
        )
        hosting.onSizeChange = { [weak self] in
            self?.scheduleRelayout(id)
        }

        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // With Full Keyboard Access, focus starts on the first control: entered the way Tab enters a
        // view, so SwiftUI focuses its first focusable control.
        if Self.isFullKeyboardAccessEnabled {
            panel.recalculateKeyViewLoop()
            panel.selectKeyView(following: container)
            if !((panel.firstResponder as? NSView)?.isDescendant(of: hosting) ?? false) {
                panel.makeFirstResponder(hosting)
            }
        }
        observe(window: window, panel: panel)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if opensFromKeyboard {
            model.isShown = true
        } else {
            DispatchQueue.main.async { [weak model] in
                guard let model else { return }
                withAnimation(MonknotMotion.surfaceEntrance(reduceMotion: reduceMotion)) {
                    model.isShown = true
                }
            }
        }
        NSAccessibility.post(element: container, notification: .created)
        return id
    }

    /// The content, list rows, theme and zoom of the popover `id` as its control draws now.
    func update(_ id: UUID, content: AnyView, listRows: [MonknotPopoverListRow] = [], theme: AppTheme, zoomScale: Double) {
        guard let presentation, presentation.id == id else { return }
        presentation.model.content = content
        presentation.model.list.rows = listRows
        if presentation.model.theme != theme {
            presentation.model.theme = theme
        }
        if presentation.model.zoomScale != zoomScale {
            presentation.model.zoomScale = zoomScale
        }
        scheduleRelayout(id)
    }

    private static func placement(
        size: CGSize,
        anchor: NSView,
        in window: NSWindow,
        contentKind: MonknotPopoverContentKind,
        theme: AppTheme,
        zoomScale: Double
    ) -> MonknotPopoverPlacement {
        let control = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        return MonknotPopoverPlacement(
            size: size,
            control: control,
            gap: MonknotMetrics.interfaceDensity(gapBase, theme: theme, zoomScale: zoomScale),
            leadingOutset: MonknotMetrics.interfaceDensity(contentKind.leadingOutsetBase, theme: theme, zoomScale: zoomScale),
            visibleFrame: visible,
            window: window.frame
        )
    }

    /// Fits the panel to its content once the content has settled, keeping it beside its control.
    private func scheduleRelayout(_ id: UUID) {
        guard !isRelayoutScheduled else { return }
        isRelayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRelayoutScheduled = false
            self.relayout(id)
        }
    }

    private func relayout(_ id: UUID) {
        guard let presentation, presentation.id == id,
              let window = presentation.window,
              let anchor = presentation.anchor, anchor.window === window
        else { return }
        let margin = Self.shadowMargin
        let fitting = presentation.hosting.fittingSize
        let size = CGSize(width: max(1, fitting.width - 2 * margin), height: max(1, fitting.height - 2 * margin))
        let placement = Self.placement(
            size: size,
            anchor: anchor,
            in: window,
            contentKind: presentation.contentKind,
            theme: presentation.model.theme,
            zoomScale: presentation.model.zoomScale
        )
        let frame = placement.surface.insetBy(dx: -margin, dy: -margin)
        if presentation.panel.frame != frame {
            presentation.panel.setFrame(frame, display: true)
        }
        if presentation.model.growAnchor != placement.growAnchor {
            presentation.model.growAnchor = placement.growAnchor
        }
    }

    // MARK: Closing

    private func observe(window: NSWindow, panel: NSPanel) {
        let center = NotificationCenter.default
        let closeOn: [(NSNotification.Name, Any?)] = [
            (NSWindow.willCloseNotification, window),
            (NSWindow.didResizeNotification, window),
            (NSWindow.didMoveNotification, window),
            (NSWindow.willEnterFullScreenNotification, window),
            (NSWindow.willExitFullScreenNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
        ]
        observers = closeOn.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.close(restoresFocus: notification.name != NSWindow.willCloseNotification)
                }
            }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoresFocus: false) }
        })
        // The menu bar acts on the key window, so it goes back to the window first.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu, menu === NSApp.mainMenu else { return }
                self?.close()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Checked once the new key window is known: the colour picker the popover opened keeps it
            // open; any other window closes it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.panelResignedKey() }
            }
        })

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
        ]) { [weak self] event in
            guard let self else { return event }
            // AppKit calls local event-monitor handlers on the main thread.
            let consumes = MainActor.assumeIsolated { self.consumes(event) }
            return consumes ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoresFocus: false) }
        }
    }

    private func panelResignedKey() {
        guard let presentation, !presentation.panel.isKeyWindow else { return }
        guard let key = NSApp.keyWindow else { return }
        if belongsToPopover(key) {
            return
        }
        // Whatever took focus keeps it.
        close(restoresFocus: false)
    }

    /// The popover's own panel, or a window it opened: the colour well's picker, or a popover of the
    /// popover's.
    private func belongsToPopover(_ window: NSWindow?) -> Bool {
        guard let window, let panel = presentation?.panel else { return false }
        if window === panel || window is NSColorPanel {
            return true
        }
        var parent = window.parent
        while let current = parent {
            if current === panel {
                return true
            }
            parent = current.parent
        }
        return false
    }

    /// Whether the popover takes `event` for itself, so nothing else sees it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let presentation else { return false }
        // A menu open over the popover (a pop-up inside it) is the topmost surface and takes the
        // keys and clicks first: Esc closes the menu, not the popover.
        if MonknotContextMenuController.shared.isOpen {
            return false
        }
        // A window hidden without closing takes its popover with it; nothing else is held up by it.
        guard let window = presentation.window, window.isVisible, presentation.anchor?.window === window else {
            close(animated: false, restoresFocus: false)
            return false
        }
        let isInside = belongsToPopover(event.window)
        switch event.type {
        case .keyDown:
            guard event.window === presentation.panel || event.window === presentation.window else { return false }
            // Caps Lock changes no key's meaning here.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            if event.keyCode == 53, modifiers.subtracting([.function]).isEmpty {
                close()
                return true
            }
            if modifiers.contains(.command) {
                if event.charactersIgnoringModifiers == "." {
                    close()
                    return true
                }
                // Text being edited in the popover keeps its own Copy, Paste and Select All.
                if event.window === presentation.panel, presentation.panel.firstResponder is NSText {
                    return false
                }
                // A shortcut closes the popover and goes to the window, as though it were not open.
                guard let window = presentation.window else { return false }
                close()
                if event.window === presentation.panel {
                    repost(event, to: window)
                    return true
                }
                return false
            }
            // A list takes the menu keys; a form's keys, and text being edited, stay with their control.
            let list = presentation.model.list
            if event.window === presentation.panel, !list.rows.isEmpty, !(presentation.panel.firstResponder is NSText) {
                return handleListKey(event, modifiers: modifiers, list: list)
            }
            return false
        case .scrollWheel:
            if isInside {
                return false
            }
            // Only the user scrolling closes it, not a trackpad's events around a click or momentum
            // left over from before it opened.
            if MonknotContextMenuController.isDeliberateScroll(event) {
                close()
            }
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isInside {
                return false
            }
            // A click outside closes it and does nothing else, so a click on its own control closes it.
            close(restoresFocus: event.window === presentation.window)
            return true
        default:
            return false
        }
    }

    /// A list's keys are a context menu's (design.md §5.8, §5.9): ↑ ↓ and ⌃P ⌃N move the one highlight
    /// over its enabled rows without wrapping, Home and End jump, typing highlights the first row that
    /// starts with what was typed, ↩ or Space chooses, and ⌫ removes a highlighted row that can be
    /// removed. False leaves the key to the focused control: Tab, and Space while a control inside a
    /// row (Remove) has focus.
    private func handleListKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, list: MonknotPopoverListModel) -> Bool {
        let plain = modifiers.subtracting([.function, .numericPad]).isEmpty
        let control = modifiers == .control
        switch event.keyCode {
        case 125 where plain, 45 where control:
            list.moveHighlight(forward: true)
        case 126 where plain, 35 where control:
            list.moveHighlight(forward: false)
        case 115 where plain, 116 where plain:
            list.highlightEnd(last: false)
        case 119 where plain, 121 where plain:
            list.highlightEnd(last: true)
        case 49 where plain && list.isTypeSelecting():
            // A space in a name being typed.
            _ = list.typeSelect(" ")
        case 49 where plain && list.focus == .control:
            return false
        case 36 where plain, 76 where plain, 49 where plain:
            guard let row = list.highlightedRow else {
                // Nothing highlighted: the focused control's key, or, as in a context menu, it closes.
                if list.focus != nil {
                    return false
                }
                close()
                return true
            }
            close()
            // The action runs once the popover has started to leave, as a context menu's does.
            DispatchQueue.main.async {
                row.choose()
            }
        case 51 where plain:
            // Held down, it removes one row, not each one the highlight moves to.
            if !event.isARepeat {
                list.removeHighlighted()
            }
        default:
            guard modifiers.subtracting(.shift).isEmpty else { return false }
            return list.typeSelect(event.charactersIgnoringModifiers ?? "")
        }
        return true
    }

    private func repost(_ event: NSEvent, to window: NSWindow) {
        guard let copy = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return }
        NSApp.postEvent(copy, atStart: true)
    }

    /// Closes the popover `id`, if it is still the one showing.
    func close(_ id: UUID, animated: Bool = true) {
        guard presentation?.id == id else { return }
        close(animated: animated)
    }

    /// Closes the open popover: a 90 ms fade, or at once. With `restoresFocus`, the window it belongs
    /// to becomes key again and the control that had focus gets it back.
    func close(animated: Bool = true, restoresFocus: Bool = true) {
        guard let presentation else { return }
        self.presentation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        let panel = presentation.panel
        presentation.hosting.onSizeChange = nil
        panel.controller = nil
        let window = presentation.window
        window?.removeChildWindow(panel)
        if restoresFocus, let window, window.isVisible, panel.isKeyWindow || NSApp.keyWindow == nil {
            window.makeKey()
            if let responder = presentation.restoredResponder, Self.responder(responder, isIn: window) {
                window.makeFirstResponder(responder)
            }
        }
        presentation.onClose?()
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotContextMenuController.exitDuration
            panel.animator().alphaValue = 0
        }
        // Ordered out on a timer rather than in the animation's completion, which never runs while the
        // screen is locked or asleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + MonknotContextMenuController.exitDuration + 0.02) {
            panel.orderOut(nil)
        }
    }

    private static func responder(_ responder: NSResponder, isIn window: NSWindow) -> Bool {
        if responder === window {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return view.window === window
    }

    // MARK: Testing

    var openPanel: NSPanel? {
        presentation?.panel
    }

    var openSurfaceFrame: NSRect? {
        guard let panel = presentation?.panel else { return nil }
        return panel.frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
    }

    var openModel: MonknotPopoverModel? {
        presentation?.model
    }

    var openLabel: String? {
        presentation?.panel.title
    }

    /// The control the open popover belongs to, in screen coordinates.
    var openControlFrame: NSRect? {
        guard let anchor = presentation?.anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    /// Handles `event` as the popover's event monitor would, for tests that cannot post real events.
    func handleForTesting(_ event: NSEvent) -> Bool {
        consumes(event)
    }
}

// MARK: - SwiftUI

extension View {
    /// Shows `content` on Monknot's popover surface below this control while `isPresented` is true
    /// (design.md §5.9), and sets it back to false when the popover closes. The control should show its
    /// open state (`press`) while it is true. A list passes the rows its keys move over, which its
    /// content highlights through the `MonknotPopoverListModel` in its environment.
    func monknotPopover<Content: View>(
        isPresented: Binding<Bool>,
        label: String,
        contentKind: MonknotPopoverContentKind = .form,
        listRows: [MonknotPopoverListRow] = [],
        theme: AppTheme,
        zoomScale: Double,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(
            MonknotPopoverAnchor(
                isPresented: isPresented,
                label: label,
                contentKind: contentKind,
                listRows: listRows,
                theme: theme,
                zoomScale: zoomScale,
                content: { AnyView(content()) }
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
    }

    /// Tells a list popover when the pointer moves over this row `id` and off it, so the row takes the
    /// list's one highlight as the pointer moves (design.md §5.9).
    func monknotPopoverListHover(_ id: String, in list: MonknotPopoverListModel) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                list.pointerMoved(onto: id)
            case .ended:
                list.pointerLeft(id)
            }
        }
    }
}

/// The control's frame, as AppKit sees it: the popover opens beside it and closes with it.
struct MonknotPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let label: String
    let contentKind: MonknotPopoverContentKind
    let listRows: [MonknotPopoverListRow]
    let theme: AppTheme
    let zoomScale: Double
    let content: () -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let controller = MonknotPopoverController.shared
        if isPresented {
            if let id = coordinator.presentationID, controller.isPresenting(id) {
                controller.update(id, content: content(), listRows: listRows, theme: theme, zoomScale: zoomScale)
            } else if !coordinator.isPresentationScheduled {
                // Presented on the next turn, so the control draws its open fill first and no window
                // changes inside a view update.
                coordinator.isPresentationScheduled = true
                let opensFromKeyboard = [.keyDown, .keyUp].contains(NSApp.currentEvent?.type)
                DispatchQueue.main.async { [weak view, weak coordinator] in
                    guard let coordinator else { return }
                    coordinator.isPresentationScheduled = false
                    guard coordinator.parent.isPresented else { return }
                    guard let view, view.window != nil else {
                        coordinator.parent.isPresented = false
                        return
                    }
                    coordinator.present(from: view, opensFromKeyboard: opensFromKeyboard)
                }
            }
        } else if let id = coordinator.presentationID {
            coordinator.presentationID = nil
            // Closed on the next turn: giving focus back changes responders, which must not happen
            // inside a view update.
            DispatchQueue.main.async {
                controller.close(id)
            }
        }
    }

    /// The popover closes with its control, and its binding goes back to false even though the
    /// coordinator is released by the time the close runs, so the control never stays open.
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let id = coordinator.presentationID {
            coordinator.presentationID = nil
            let isPresented = coordinator.parent.$isPresented
            DispatchQueue.main.async {
                MonknotPopoverController.shared.close(id)
                if isPresented.wrappedValue {
                    isPresented.wrappedValue = false
                }
            }
        }
    }

    @MainActor
    final class Coordinator {
        var parent: MonknotPopoverAnchor
        var presentationID: UUID?
        var isPresentationScheduled = false

        init(parent: MonknotPopoverAnchor) {
            self.parent = parent
        }

        func present(from view: NSView, opensFromKeyboard: Bool) {
            let parent = parent
            presentationID = MonknotPopoverController.shared.present(
                parent.content(),
                label: parent.label,
                from: view,
                contentKind: parent.contentKind,
                listRows: parent.listRows,
                theme: parent.theme,
                zoomScale: parent.zoomScale,
                opensFromKeyboard: opensFromKeyboard,
                onClose: { [weak self] in
                    guard let self else { return }
                    self.presentationID = nil
                    if self.parent.isPresented {
                        self.parent.isPresented = false
                    }
                }
            )
            if presentationID == nil {
                self.parent.isPresented = false
            }
        }
    }
}
