import AppKit
import AVKit
import Combine
import MonknotCore
import PDFKit
import SwiftUI
import WebKit

// MARK: - Commands

/// Every command a context menu in the chrome offers, with its one title, glyph and role (design.md
/// §5.8). Call sites build their SwiftUI `.contextMenu` buttons from it, and the menu Monknot draws
/// reads the glyph and role back from the title, so neither can drift from the other.
enum MonknotMenuCommand: String, CaseIterable {
    case newFile = "New File"
    case newFolder = "New Folder"
    case rename = "Rename"
    case copyPath = "Copy Path"
    case copyRelativePath = "Copy Relative Path"
    case revealInFinder = "Reveal in Finder"
    case exportPDF = "Export PDF…"
    case copy = "Copy"
    case cut = "Cut"
    case paste = "Paste"
    case duplicate = "Duplicate"
    case moveToTrash = "Move to Trash"
    case collapseAllFolders = "Collapse All Folders"
    case open = "Open"
    case pinTab = "Pin Tab"
    case unpinTab = "Unpin Tab"
    case closeTab = "Close Tab"
    case closeOtherTabs = "Close Other Tabs"
    case restartTerminal = "Restart Terminal"
    case killTerminal = "Kill Terminal"

    var title: String {
        rawValue
    }

    var systemImage: String {
        switch self {
        case .newFile: return MonknotWorkspaceIcons.newFile
        case .newFolder: return MonknotWorkspaceIcons.newFolder
        case .rename: return "pencil"
        case .copyPath: return MonknotWorkspaceIcons.copyPath
        case .copyRelativePath:
            return MonknotSFSymbol.resolve("point.topleft.down.to.point.bottomright.curvepath", fallback: "link")
        case .revealInFinder: return MonknotWorkspaceIcons.revealInFinder
        case .exportPDF: return MonknotWorkspaceIcons.exportPDF
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .paste: return MonknotSFSymbol.resolve("clipboard", fallback: "doc.on.clipboard")
        case .duplicate: return "plus.square.on.square"
        case .moveToTrash, .killTerminal: return "trash"
        case .collapseAllFolders:
            return MonknotSFSymbol.resolve("rectangle.compress.vertical", fallback: "arrow.down.right.and.arrow.up.left")
        case .open: return "doc"
        case .pinTab: return "pin"
        case .unpinTab: return "pin.slash"
        case .closeTab: return "xmark"
        case .closeOtherTabs: return MonknotSFSymbol.resolve("xmark.rectangle", fallback: "xmark")
        case .restartTerminal: return "arrow.clockwise"
        }
    }

    /// A command that destroys something: its row turns `danger` while highlighted.
    var isDestructive: Bool {
        self == .moveToTrash || self == .killTerminal
    }
}

/// A context menu's button for `command`.
struct MonknotMenuCommandButton: View {
    let command: MonknotMenuCommand
    let action: () -> Void

    init(_ command: MonknotMenuCommand, action: @escaping () -> Void) {
        self.command = command
        self.action = action
    }

    var body: some View {
        Button(role: command.isDestructive ? .destructive : nil, action: action) {
            Label(command.title, systemImage: command.systemImage)
        }
    }
}

// MARK: - Model and layout

/// One open context menu: its rows, and which one the pointer or the keyboard has highlighted.
@MainActor
final class MonknotContextMenuModel: ObservableObject {
    struct Item {
        let title: String
        let systemImage: String?
        let isEnabled: Bool
        let isDestructive: Bool
        let perform: () -> Void
    }

    enum Entry {
        case separator
        case item(Item)

        var item: Item? {
            if case .item(let item) = self {
                return item
            }
            return nil
        }
    }

    let entries: [Entry]
    @Published var highlighted: Int?
    @Published var pressed: Int?
    /// False until the surface has been drawn once, so it grows in from its corner.
    @Published var isShown = false

    init(entries: [Entry]) {
        self.entries = entries
    }

    func isEnabled(_ index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].item?.isEnabled == true
    }

    var enabledIndices: [Int] {
        entries.indices.filter(isEnabled)
    }

    /// The rows of an `NSMenu` SwiftUI built for a `.contextMenu`, performed through the menu itself.
    /// Separators at either end or next to each other are dropped; nil when a row has a submenu or a
    /// custom view, which only the system's menu can show.
    static func entries(of menu: NSMenu) -> [Entry]? {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var entries: [Entry] = []
        for (index, menuItem) in menu.items.enumerated() where !menuItem.isHidden {
            if menuItem.submenu != nil || menuItem.view != nil {
                return nil
            }
            if menuItem.isSeparatorItem {
                if let last = entries.last, case .item = last {
                    entries.append(.separator)
                }
                continue
            }
            let command = MonknotMenuCommand(rawValue: menuItem.title)
            entries.append(.item(Item(
                title: menuItem.title,
                systemImage: command?.systemImage,
                isEnabled: menuItem.isEnabled && (menuItem.action != nil || menuItem.target != nil),
                isDestructive: command?.isDestructive == true,
                // The row holds its menu: the action runs after the menu has closed, when nothing
                // else may.
                perform: {
                    guard menu.items.indices.contains(index) else { return }
                    menu.performActionForItem(at: index)
                }
            )))
        }
        if let last = entries.last, case .separator = last {
            entries.removeLast()
        }
        return entries.isEmpty ? nil : entries
    }
}

/// Where each row of a context menu sits, in the surface's own coordinates from its top left. The
/// surface draws from these frames and the pointer is hit-tested against them, so the two agree at
/// every zoom.
struct MonknotContextMenuLayout {
    static let minimumWidthBase: CGFloat = 232
    static let maximumWidthBase: CGFloat = 320

    let frames: [CGRect]
    let size: CGSize
    /// The entries that are rows, not separators.
    private let rows: Set<Int>

    init(entries: [MonknotContextMenuModel.Entry], theme: AppTheme, zoomScale: Double) {
        func density(_ base: CGFloat) -> CGFloat {
            MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
        }
        let inset = density(MonknotMetrics.menuListInsetBase)
        let rowHeight = density(MonknotMetrics.menuRowHeightBase)
        let separatorHeight = 1 + 2 * density(6)
        let font = NSFont.systemFont(ofSize: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale))
        let widestLabel = entries.compactMap(\.item).map { item in
            ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        let rowChrome = 2 * density(MonknotMetrics.menuRowPaddingBase)
            + MonknotMetrics.interfaceGlyph(MonknotMetrics.rowIconColumnWidthBase, theme: theme, zoomScale: zoomScale)
            + density(MonknotMetrics.menuRowGlyphGapBase)
            + density(8)
        let width = min(
            max(density(Self.minimumWidthBase), 2 * inset + rowChrome + widestLabel),
            density(Self.maximumWidthBase)
        )

        var frames: [CGRect] = []
        var y = inset
        var previousWasItem = false
        for entry in entries {
            switch entry {
            case .separator:
                frames.append(CGRect(x: inset, y: y, width: width - 2 * inset, height: separatorHeight))
                y += separatorHeight
                previousWasItem = false
            case .item:
                // Rows sit 1 apart, as in every menu (design.md §10.7).
                if previousWasItem {
                    y += 1
                }
                frames.append(CGRect(x: inset, y: y, width: width - 2 * inset, height: rowHeight))
                y += rowHeight
                previousWasItem = true
            }
        }
        self.frames = frames
        self.size = CGSize(width: width, height: y + inset)
        self.rows = Set(entries.indices.filter { entries[$0].item != nil })
    }

    /// The row under `point`, in the surface's coordinates; nil over the inset or a separator.
    func entry(at point: CGPoint) -> Int? {
        frames.indices.first { rows.contains($0) && frames[$0].contains(point) }
    }
}

// MARK: - Surface

/// The menu row on a floating surface (design.md §5.8): `surf2`, radius 12, `e2`, the 6 list inset,
/// 30 rows 1 apart. The one highlight is the `selected` fill, `press` while held; a destructive
/// command's highlighted row is `danger`. It grows in from the pointer's corner.
struct MonknotContextMenuSurface: View {
    @ObservedObject var model: MonknotContextMenuModel
    let layout: MonknotContextMenuLayout
    let anchor: UnitPoint
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                let frame = layout.frames[index]
                Group {
                    switch entry {
                    case .separator:
                        MonknotMenuSeparator(theme: theme, zoomScale: zoomScale)
                    case .item(let item):
                        row(item, index: index)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .monknotFloatingSurface(
            .e2,
            cornerRadius: theme.chromeRadius(MonknotMetrics.cardCornerRadius, zoomScale: zoomScale),
            fill: theme.elevatedSurfaceColor,
            theme: theme
        )
        .scaleEffect(model.isShown || reduceMotion ? 1 : 0.97, anchor: anchor)
        .opacity(model.isShown ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func row(_ item: MonknotContextMenuModel.Item, index: Int) -> some View {
        let isHighlighted = item.isEnabled && model.highlighted == index
        let fill: Color = !item.isEnabled ? .clear
            : model.pressed == index ? theme.pressedFillColor
            : isHighlighted ? theme.chromeSelectedFillColor
            : .clear
        return MonknotMenuRowLabel(
            leading: item.systemImage.map { .glyph($0) } ?? .blank,
            title: item.title,
            isHighlighted: isHighlighted,
            isDisabled: !item.isEnabled,
            isDestructive: item.isDestructive,
            theme: theme,
            zoomScale: zoomScale
        )
        .background {
            // The highlight moves at once, as the keyboard moves it: a menu never trails the pointer.
            RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
                .fill(fill)
        }
    }
}

// MARK: - Panel

/// The borderless panel a context menu floats in. It never becomes key, so the window it belongs
/// to keeps its focus, selection and active appearance, as with a system menu.
final class MonknotContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Takes the pointer over the menu for the controller, and gives VoiceOver the menu and its rows.
final class MonknotContextMenuInteractionView: NSView {
    weak var controller: MonknotContextMenuController?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved()
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved()
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerMoved()
    }

    override func mouseDown(with event: NSEvent) {
        controller?.pointerDown()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.pointerDown()
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        controller?.pointerMoved()
    }

    override func rightMouseDragged(with event: NSEvent) {
        controller?.pointerMoved()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.pointerUp()
    }

    override func rightMouseUp(with event: NSEvent) {
        controller?.pointerUp()
    }

    override func scrollWheel(with event: NSEvent) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .menu
    }

    override func accessibilityChildren() -> [Any]? {
        controller?.accessibilityRows(in: self)
    }
}

/// A row of the open menu as VoiceOver reads it.
private final class MonknotContextMenuAccessibilityRow: NSAccessibilityElement {
    let press: () -> Bool

    init(title: String, isEnabled: Bool, frame: NSRect, parent: NSView, press: @escaping () -> Bool) {
        self.press = press
        super.init()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(isEnabled)
        setAccessibilityParent(parent)
        setAccessibilityFrame(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
    }
}

// MARK: - Appearance

/// Tells the context-menu controller which theme and zoom the window it sits in draws with, so a
/// menu opened there matches it.
struct MonknotContextMenuAppearance: NSViewRepresentable {
    let theme: AppTheme
    let zoomScale: Double

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.appearanceValues = (theme, zoomScale)
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.appearanceValues = (theme, zoomScale)
    }

    final class ReportingView: NSView {
        var appearanceValues: (AppTheme, Double)? {
            didSet { report() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func report() {
            guard let window, let appearanceValues else { return }
            MonknotContextMenuController.shared.setAppearance(
                theme: appearanceValues.0,
                zoomScale: appearanceValues.1,
                for: window
            )
        }
    }
}

// MARK: - Controller

/// Shows every context menu in the chrome as Monknot's own menu (design.md §5.8). A right-click or
/// Control-click over SwiftUI content asks that content for the `.contextMenu` it declares, exactly
/// as AppKit would, and draws those rows on a floating surface instead of the system's menu. Text
/// in Source, Preview, a PDF and the terminal, and the media player, keep the system's menu, which
/// carries spelling, Writing Tools, Look Up and Services; so does a window that has not reported its
/// appearance, and a menu with a submenu.
@MainActor
final class MonknotContextMenuController: ObservableObject {
    static let shared = MonknotContextMenuController()

    /// Set while a menu is open; a row that was under the pointer when it opened holds its open state
    /// (`press`) until it clears.
    @Published private(set) var presentationID: UUID?

    /// How far beyond the surface its shadow reaches; the panel is this much larger on every side.
    static let shadowMargin: CGFloat = 32
    /// How long the menu takes to grow in, and to leave (design.md §10.10).
    static let entranceDuration: Double = 0.15
    static let exitDuration: Double = 0.09
    /// A press held this long before its button comes up away from the menu closes the menu.
    static let pressAndHoldInterval: TimeInterval = 0.5

    private struct WindowAppearance {
        weak var window: NSWindow?
        let theme: AppTheme
        let zoomScale: Double
    }

    private struct Presentation {
        let id: UUID
        let panel: MonknotContextMenuPanel
        let model: MonknotContextMenuModel
        let layout: MonknotContextMenuLayout
        let menu: NSMenu?
        weak var window: NSWindow?
        let surfaceFrame: NSRect
        let openedAt: TimeInterval
        let onClose: (() -> Void)?
    }

    private var appearances: [ObjectIdentifier: WindowAppearance] = [:]
    private var presentation: Presentation?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// The button that opened the menu is still down: releasing it over a row chooses that row.
    private var openingPressIsDown = false
    private var typeSelection = ""
    private var typeSelectionTime: TimeInterval = 0

    var isOpen: Bool {
        presentation != nil
    }

    /// Starts taking right-clicks for the chrome. Called once, at launch.
    func install() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .otherMouseDown, .keyDown, .scrollWheel,
        ]) { [weak self] event in
            guard let self else { return event }
            // AppKit calls local event-monitor handlers on the main thread.
            let consumes = MainActor.assumeIsolated { self.consumes(event) }
            return consumes ? nil : event
        }
    }

    func setAppearance(theme: AppTheme, zoomScale: Double, for window: NSWindow) {
        appearances = appearances.filter { $0.value.window != nil }
        appearances[ObjectIdentifier(window)] = WindowAppearance(window: window, theme: theme, zoomScale: zoomScale)
    }

    // MARK: Events

    /// Whether the menu takes `event` for itself, so the window never sees it.
    private func consumes(_ event: NSEvent) -> Bool {
        // An open popover takes every click outside it (design.md §5.9), right-clicks included.
        if MonknotPopoverController.shared.isOpen {
            return false
        }
        if let presentation, let handled = handleWhileOpen(event, presentation: presentation) {
            return !handled.passThrough
        }
        guard Self.isContextClick(event) else { return false }
        return openMenu(for: event)
    }

    private static func isContextClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
        default:
            return false
        }
    }

    private struct Handled {
        let passThrough: Bool
    }

    /// What an event does while a menu is open: nil when it should still go on to open a menu (a
    /// right-click elsewhere opens the next one there).
    private func handleWhileOpen(_ event: NSEvent, presentation: Presentation) -> Handled? {
        let isInPanel = event.window === presentation.panel
        switch event.type {
        case .keyDown:
            handleKey(event)
            return Handled(passThrough: false)
        case .leftMouseDragged, .rightMouseDragged:
            if !isInPanel {
                pointerMoved()
            }
            return Handled(passThrough: isInPanel)
        case .leftMouseUp, .rightMouseUp:
            if openingPressIsDown, !isInPanel {
                openingPressIsDown = false
                finishOpeningPress()
                return Handled(passThrough: false)
            }
            return Handled(passThrough: isInPanel)
        case .scrollWheel:
            if !isInPanel {
                close()
            }
            return Handled(passThrough: false)
        case .leftMouseDown, .otherMouseDown, .rightMouseDown:
            if isInPanel {
                return Handled(passThrough: true)
            }
            close()
            // A right-click elsewhere goes on to open that place's menu; any other click only closes.
            return Self.isContextClick(event) ? nil : Handled(passThrough: false)
        default:
            return Handled(passThrough: true)
        }
    }

    // MARK: Opening

    /// Opens Monknot's menu for a right-click over SwiftUI content that declares one. False leaves the
    /// event to AppKit: text and web views, PDFs and players keep the system's menu.
    private func openMenu(for event: NSEvent) -> Bool {
        guard let window = event.window,
              !(window is MonknotContextMenuPanel),
              let appearance = appearances[ObjectIdentifier(window)],
              appearance.window === window,
              let menu = Self.swiftUIMenu(for: event, in: window),
              let entries = MonknotContextMenuModel.entries(of: menu)
        else { return false }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        openingPressIsDown = true
        present(
            entries: entries,
            menu: menu,
            at: screenPoint,
            in: window,
            theme: appearance.theme,
            zoomScale: appearance.zoomScale
        )
        return true
    }

    /// The menu AppKit would show for `event`: the first one up the hit view's superview chain, if a
    /// SwiftUI hosting view declares it, and none if a view that keeps the system's menu comes first.
    static func swiftUIMenu(for event: NSEvent, in window: NSWindow) -> NSMenu? {
        guard let root = window.contentView?.superview ?? window.contentView,
              let hit = root.hitTest(event.locationInWindow)
        else { return nil }
        var view: NSView? = hit
        while let current = view {
            if keepsSystemMenu(current) {
                return nil
            }
            if let menu = current.menu(for: event) {
                return isSwiftUIHost(current) ? menu : nil
            }
            view = current.superview
        }
        return nil
    }

    private static func keepsSystemMenu(_ view: NSView) -> Bool {
        view is NSTextView || view is WKWebView || view is PDFView || view is PDFThumbnailView
            || view is AVPlayerView || (view as? NSTextField)?.isEditable == true
    }

    private static func isSwiftUIHost(_ view: NSView) -> Bool {
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            if NSStringFromClass(current).contains("NSHostingView") {
                return true
            }
            cls = class_getSuperclass(current)
        }
        return false
    }

    /// Shows a menu button's commands (the PDF bar's More) below `anchor`, its leading edges on the
    /// button's, 4 clear of it; above it where the screen ends. False when `anchor`'s window has not
    /// reported its appearance, so the caller shows the system's menu instead.
    func presentCommands(
        _ groups: [[MonknotPopUpAction]],
        below anchor: NSView,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard let window = anchor.window,
              let appearance = appearances[ObjectIdentifier(window)],
              appearance.window === window
        else { return false }
        var entries: [MonknotContextMenuModel.Entry] = []
        for group in groups where !group.isEmpty {
            if !entries.isEmpty {
                entries.append(.separator)
            }
            for command in group {
                entries.append(.item(MonknotContextMenuModel.Item(
                    title: command.title,
                    systemImage: command.systemImage ?? MonknotMenuCommand(rawValue: command.title)?.systemImage,
                    isEnabled: command.isEnabled,
                    isDestructive: MonknotMenuCommand(rawValue: command.title)?.isDestructive == true,
                    perform: command.action
                )))
            }
        }
        guard !entries.isEmpty else { return false }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let gap = MonknotMetrics.interfaceDensity(4, theme: appearance.theme, zoomScale: appearance.zoomScale)
        present(
            entries: entries,
            at: NSPoint(x: anchorRect.minX, y: anchorRect.minY - gap),
            flippedAbove: anchorRect.maxY + gap,
            in: window,
            theme: appearance.theme,
            zoomScale: appearance.zoomScale,
            onClose: onClose
        )
        openingPressIsDown = false
        return true
    }

    /// Shows `entries` with the surface's top-left corner at `screenPoint`, flipped left or up where
    /// the screen ends, 6 clear of its edge; flipped up, its bottom edge is at `flippedAbove`, or at
    /// the point itself.
    func present(
        entries: [MonknotContextMenuModel.Entry],
        menu: NSMenu? = nil,
        at screenPoint: NSPoint,
        flippedAbove: CGFloat? = nil,
        in window: NSWindow,
        theme: AppTheme,
        zoomScale: Double,
        onClose: (() -> Void)? = nil
    ) {
        close(animated: false)

        let model = MonknotContextMenuModel(entries: entries)
        let layout = MonknotContextMenuLayout(entries: entries, theme: theme, zoomScale: zoomScale)
        let size = layout.size
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 6, dy: 6)
            ?? NSRect(origin: .zero, size: CGSize(width: 10_000, height: 10_000))
        var surface = NSRect(x: screenPoint.x, y: screenPoint.y - size.height, width: size.width, height: size.height)
        var anchor = UnitPoint.topLeading
        if surface.maxX > visible.maxX {
            surface.origin.x = screenPoint.x - size.width
            anchor = .topTrailing
        }
        if surface.minY < visible.minY {
            surface.origin.y = flippedAbove ?? screenPoint.y
            anchor = anchor == .topTrailing ? .bottomTrailing : .bottomLeading
        }
        surface.origin.x = min(max(surface.origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        surface.origin.y = min(max(surface.origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))

        let margin = Self.shadowMargin
        let panelFrame = surface.insetBy(dx: -margin, dy: -margin)
        let panel = MonknotContextMenuPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        let surfaceView = MonknotContextMenuSurface(
            model: model,
            layout: layout,
            anchor: anchor,
            theme: theme,
            zoomScale: zoomScale
        )
        .padding(margin)
        let hosting = NSHostingView(rootView: surfaceView)
        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        let interaction = MonknotContextMenuInteractionView(frame: hosting.frame)
        interaction.autoresizingMask = [.width, .height]
        interaction.controller = self
        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.addSubview(hosting)
        container.addSubview(interaction)
        panel.contentView = container

        let id = UUID()
        presentation = Presentation(
            id: id,
            panel: panel,
            model: model,
            layout: layout,
            menu: menu,
            window: window,
            surfaceFrame: surface,
            openedAt: ProcessInfo.processInfo.systemUptime,
            onClose: onClose
        )
        if let menu {
            menu.delegate?.menuWillOpen?(menu)
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        presentationID = id
        observe(window)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.async { [weak model] in
            guard let model else { return }
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: MonknotMotion.hoverDuration)
                    : .timingCurve(0.23, 1, 0.32, 1, duration: Self.entranceDuration)
            ) {
                model.isShown = true
            }
        }
        NSAccessibility.post(element: interaction, notification: .created)
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let closeOn: [(NSNotification.Name, Any?)] = [
            (NSApplication.didResignActiveNotification, NSApp),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.willCloseNotification, window),
            (NSWindow.didResizeNotification, window),
            (NSWindow.didMoveNotification, window),
            (NSWindow.willEnterFullScreenNotification, window),
            (NSWindow.willExitFullScreenNotification, window),
        ]
        observers = closeOn.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // MARK: Pointer

    private func entryUnderPointer() -> Int? {
        guard let presentation else { return nil }
        let location = NSEvent.mouseLocation
        let surface = presentation.surfaceFrame
        let point = CGPoint(x: location.x - surface.minX, y: surface.maxY - location.y)
        return presentation.layout.entry(at: point)
    }

    private var pointerIsOverSurface: Bool {
        guard let presentation else { return false }
        return presentation.surfaceFrame.contains(NSEvent.mouseLocation)
    }

    func pointerMoved() {
        guard let model = presentation?.model else { return }
        let index = entryUnderPointer().flatMap { model.isEnabled($0) ? $0 : nil }
        if model.highlighted != index {
            model.highlighted = index
        }
        if model.pressed != nil, model.pressed != index {
            model.pressed = index
        }
    }

    func pointerDown() {
        guard let model = presentation?.model else { return }
        pointerMoved()
        model.pressed = model.highlighted
    }

    func pointerUp() {
        guard let model = presentation?.model else { return }
        let index = entryUnderPointer()
        model.pressed = nil
        openingPressIsDown = false
        if let index, model.isEnabled(index) {
            choose(index)
        }
    }

    /// The button that opened the menu came up outside the panel's own events: over a row it chooses
    /// it, as a held right-click does in a system menu; held a while and let go away from the menu, it
    /// closes it; a quick click leaves it open.
    private func finishOpeningPress() {
        guard let presentation else { return }
        if let index = entryUnderPointer(), presentation.model.isEnabled(index) {
            choose(index)
            return
        }
        let held = ProcessInfo.processInfo.systemUptime - presentation.openedAt
        if held > Self.pressAndHoldInterval, !pointerIsOverSurface {
            close()
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) {
        guard let model = presentation?.model else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let enabled = model.enabledIndices
        let control = modifiers == .control
        switch event.keyCode {
        case 125 where modifiers.subtracting([.function, .numericPad]).isEmpty:
            moveHighlight(forward: true, in: enabled)
        case 126 where modifiers.subtracting([.function, .numericPad]).isEmpty:
            moveHighlight(forward: false, in: enabled)
        case 45 where control:
            moveHighlight(forward: true, in: enabled)
        case 35 where control:
            moveHighlight(forward: false, in: enabled)
        case 115, 116:
            model.highlighted = enabled.first
        case 119, 121:
            model.highlighted = enabled.last
        case 36, 76, 49:
            if let index = model.highlighted, model.isEnabled(index) {
                choose(index)
            } else {
                close()
            }
        case 53:
            close()
        default:
            typeSelect(event.charactersIgnoringModifiers ?? "", modifiers: modifiers, model: model)
        }
    }

    private func moveHighlight(forward: Bool, in enabled: [Int]) {
        guard let model = presentation?.model, !enabled.isEmpty else { return }
        guard let current = model.highlighted else {
            model.highlighted = forward ? enabled.first : enabled.last
            return
        }
        if forward {
            model.highlighted = enabled.first { $0 > current } ?? current
        } else {
            model.highlighted = enabled.last { $0 < current } ?? current
        }
    }

    /// Typing highlights the first enabled row whose title starts with what was typed; a pause of a
    /// second starts over.
    private func typeSelect(_ characters: String, modifiers: NSEvent.ModifierFlags, model: MonknotContextMenuModel) {
        guard modifiers.subtracting(.shift).isEmpty,
              let scalar = characters.unicodeScalars.first,
              CharacterSet.alphanumerics.union(.whitespaces).contains(scalar)
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - typeSelectionTime > 1 {
            typeSelection = ""
        }
        typeSelectionTime = now
        typeSelection += characters.lowercased()
        let match = model.enabledIndices.first { index in
            model.entries[index].item?.title.lowercased().hasPrefix(typeSelection) == true
        }
        if let match {
            model.highlighted = match
        }
    }

    // MARK: Choosing and closing

    private func choose(_ index: Int) {
        guard let item = presentation?.model.entries[index].item, item.isEnabled else { return }
        close()
        // The action runs once the menu has started to leave, as a system menu's does.
        DispatchQueue.main.async {
            item.perform()
        }
    }

    /// Closes the open menu: a 90 ms fade, or at once.
    func close(animated: Bool = true) {
        guard let presentation else { return }
        self.presentation = nil
        openingPressIsDown = false
        typeSelection = ""
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if presentationID == presentation.id {
            presentationID = nil
        }
        let panel = presentation.panel
        presentation.window?.removeChildWindow(panel)
        if let menu = presentation.menu {
            menu.delegate?.menuDidClose?(menu)
        }
        presentation.onClose?()
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.exitDuration
            panel.animator().alphaValue = 0
        }
        // Ordered out on a timer rather than in the animation's completion, which never runs while
        // the screen is locked or asleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration + 0.02) {
            panel.orderOut(nil)
        }
    }

    // MARK: Accessibility

    func accessibilityRows(in view: NSView) -> [Any]? {
        guard let presentation else { return nil }
        let surface = presentation.surfaceFrame
        return presentation.model.entries.enumerated().compactMap { index, entry -> Any? in
            guard let item = entry.item else { return nil }
            let frame = presentation.layout.frames[index]
            let screenFrame = NSRect(
                x: surface.minX + frame.minX,
                y: surface.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            return MonknotContextMenuAccessibilityRow(
                title: item.title,
                isEnabled: item.isEnabled,
                frame: screenFrame,
                parent: view
            ) { [weak self] in
                guard item.isEnabled else { return false }
                self?.choose(index)
                return true
            }
        }
    }

    // MARK: Testing

    /// The open menu's rows, for tests.
    var openTitles: [String]? {
        presentation?.model.entries.map { $0.item?.title ?? "-" }
    }

    var openModel: MonknotContextMenuModel? {
        presentation?.model
    }

    var openSurfaceFrame: NSRect? {
        presentation?.surfaceFrame
    }

    var openPanel: NSPanel? {
        presentation?.panel
    }

    /// Chooses the open menu's row titled `title`, as a click would.
    @discardableResult
    func chooseForTesting(_ title: String) -> Bool {
        guard let index = presentation?.model.entries.firstIndex(where: { $0.item?.title == title }),
              presentation?.model.isEnabled(index) == true
        else { return false }
        choose(index)
        return true
    }

    /// Handles `event` as the app's event monitor would, for tests that cannot post real events.
    func handleForTesting(_ event: NSEvent) -> Bool {
        consumes(event)
    }
}
