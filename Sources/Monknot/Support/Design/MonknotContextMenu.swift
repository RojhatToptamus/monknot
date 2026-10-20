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

/// One open menu: its rows, which one the pointer or the keyboard has highlighted, and how far a menu
/// taller than it may be has scrolled.
@MainActor
final class MonknotContextMenuModel: ObservableObject {
    struct Item {
        let title: String
        let systemImage: String?
        /// A colour's swatch in the glyph column, for a colour among a pop-up's values.
        var swatch: Color?
        let isEnabled: Bool
        let isDestructive: Bool
        /// One of a pop-up's values: every value row keeps room for the check, and the current one
        /// shows it.
        var isValue = false
        var isChecked = false
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
    @Published var highlighted: Int? {
        didSet {
            if highlighted != oldValue {
                onHighlight?(highlighted)
            }
        }
    }
    @Published var pressed: Int?
    /// False until the surface has been drawn once, so it grows in from its corner.
    @Published var isShown = false
    /// How far the rows have scrolled, in points from the top, in a menu taller than it may be.
    @Published var scrollOffset: CGFloat = 0
    /// The thumb shows while the rows scroll and a moment after, never merely under the pointer
    /// (design.md §5.7).
    @Published var showsThumb = false
    @Published var isThumbHovered = false
    /// Told when the highlight moves, so a pop-up can preview the value under it.
    var onHighlight: ((Int?) -> Void)?

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

/// Where each row of a menu sits, from the top left of its content: the surface's own coordinates
/// until it scrolls. The surface draws from these frames and the pointer is hit-tested against them,
/// so the two agree at every zoom.
struct MonknotContextMenuLayout {
    static let minimumWidthBase: CGFloat = 232
    static let maximumWidthBase: CGFloat = 320
    /// A pop-up's values scroll past this height, as Preview's menus do (editor.css `.mk-menu`).
    static let valueMenuMaximumHeightBase: CGFloat = 380
    /// The thumb's shortest length, so a long list's thumb stays easy to see and grab.
    static let minimumThumbLength: CGFloat = 20

    let frames: [CGRect]
    /// The surface: as tall as the content, or as tall as it may be where the menu scrolls.
    let size: CGSize
    /// The rows with the list inset above and below.
    let contentHeight: CGFloat
    let rowHeight: CGFloat
    /// False for a menu of plain names, which has no glyph column (as Preview's language menu).
    let hasGlyphColumn: Bool
    /// A pop-up's menu keeps the check's room on every row, so the check never moves the labels.
    let reservesCheck: Bool
    /// The entries that are rows, not separators.
    private let rows: Set<Int>
    private let inset: CGFloat

    /// `minimumWidth` keeps a pop-up's menu as wide as its button; past `maximumHeight` the rows
    /// scroll.
    init(
        entries: [MonknotContextMenuModel.Entry],
        theme: AppTheme,
        zoomScale: Double,
        minimumWidth: CGFloat = 0,
        maximumHeight: CGFloat? = nil
    ) {
        func density(_ base: CGFloat) -> CGFloat {
            MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
        }
        let inset = density(MonknotMetrics.menuListInsetBase)
        let rowHeight = density(MonknotMetrics.menuRowHeightBase)
        let separatorHeight = 1 + 2 * density(6)
        let font = NSFont.systemFont(ofSize: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale))
        let items = entries.compactMap(\.item)
        let widestLabel = items.map { item in
            ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        let hasGlyphColumn = items.contains { $0.systemImage != nil || $0.swatch != nil }
        let reservesCheck = items.contains(where: \.isValue)
        let glyphColumn = hasGlyphColumn
            ? MonknotMetrics.interfaceGlyph(MonknotMetrics.rowIconColumnWidthBase, theme: theme, zoomScale: zoomScale)
                + density(MonknotMetrics.menuRowGlyphGapBase)
            : 0
        let rowChrome = 2 * density(MonknotMetrics.menuRowPaddingBase)
            + glyphColumn
            + density(8)
            + (reservesCheck ? MonknotMenuRowCheck.width(theme: theme, zoomScale: zoomScale) : 0)
        let width = min(
            max(density(Self.minimumWidthBase), minimumWidth, 2 * inset + rowChrome + widestLabel),
            max(density(Self.maximumWidthBase), minimumWidth)
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
        self.contentHeight = y + inset
        self.size = CGSize(width: width, height: min(y + inset, maximumHeight ?? .greatestFiniteMagnitude))
        self.rowHeight = rowHeight
        self.hasGlyphColumn = hasGlyphColumn
        self.reservesCheck = reservesCheck
        self.rows = Set(entries.indices.filter { entries[$0].item != nil })
        self.inset = inset
    }

    var maximumScrollOffset: CGFloat {
        max(0, contentHeight - size.height)
    }

    var scrolls: Bool {
        maximumScrollOffset > 0
    }

    /// The row under `point`, in the content's coordinates; nil over the inset or a separator.
    func entry(at point: CGPoint) -> Int? {
        frames.indices.first { rows.contains($0) && frames[$0].contains(point) }
    }

    /// The entries any part of which shows at `offset`.
    func visibleEntries(at offset: CGFloat) -> [Int] {
        guard scrolls else { return Array(frames.indices) }
        return frames.indices.filter { frames[$0].maxY > offset && frames[$0].minY < offset + size.height }
    }

    func clampedOffset(_ offset: CGFloat) -> CGFloat {
        min(max(0, offset), maximumScrollOffset)
    }

    /// The offset nearest `offset` that shows the row at `index` whole, with the list inset around it,
    /// as Preview's menus reveal a row the keys reach.
    func offset(revealing index: Int, from offset: CGFloat) -> CGFloat {
        guard frames.indices.contains(index) else { return offset }
        let top = frames[index].minY - inset
        let bottom = frames[index].maxY + inset
        if top < offset {
            return clampedOffset(top)
        }
        if bottom > offset + size.height {
            return clampedOffset(bottom - size.height)
        }
        return offset
    }

    /// The offset that puts the row at `index` in the middle of the menu, where a pop-up opens with its
    /// value.
    func offset(centering index: Int) -> CGFloat {
        guard frames.indices.contains(index) else { return 0 }
        return clampedOffset(frames[index].midY - size.height / 2)
    }

    /// The thumb in the surface's coordinates at `offset` (design.md §5.7): a capsule centred in the 9
    /// lane flush with the trailing edge, 4 wide at rest and 6 under the pointer, its ends 6 clear of
    /// the surface's; nil when the menu does not scroll.
    func thumbFrame(offset: CGFloat, isHovered: Bool) -> CGRect? {
        guard scrolls else { return nil }
        let track = size.height - 2 * MonknotScrollbarStyle.endInset
        let length = max(Self.minimumThumbLength, track * size.height / contentHeight)
        let travel = max(0, track - length)
        let width = isHovered ? MonknotScrollbarStyle.hoveredThumbWidth : MonknotScrollbarStyle.restingThumbWidth
        return CGRect(
            x: size.width - MonknotScrollbarStyle.thumbCenterInset - width / 2,
            y: MonknotScrollbarStyle.endInset + travel * clampedOffset(offset) / maximumScrollOffset,
            width: width,
            height: length
        )
    }

    /// How far the content scrolls for each point the thumb is dragged.
    var scrollPerThumbPoint: CGFloat {
        guard let thumb = thumbFrame(offset: 0, isHovered: false) else { return 0 }
        let travel = size.height - 2 * MonknotScrollbarStyle.endInset - thumb.height
        return travel > 0 ? maximumScrollOffset / travel : 0
    }
}

// MARK: - Surface

/// The menu row on a floating surface (design.md §5.8): `surf2`, radius 12, `e2`, the 6 list inset,
/// 30 rows 1 apart. The one highlight is the `selected` fill, `press` while held; a destructive
/// command's highlighted row is `danger`; a pop-up's current value carries the check. It grows in from
/// the pointer's corner. A menu taller than it may be scrolls under the chrome lists' thumb, drawing
/// only the rows in view.
struct MonknotContextMenuSurface: View {
    @ObservedObject var model: MonknotContextMenuModel
    let layout: MonknotContextMenuLayout
    let anchor: UnitPoint
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.visibleEntries(at: model.scrollOffset), id: \.self) { index in
                let frame = layout.frames[index]
                Group {
                    switch model.entries[index] {
                    case .separator:
                        MonknotMenuSeparator(theme: theme, zoomScale: zoomScale)
                    case .item(let item):
                        row(item, index: index)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY - model.scrollOffset)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let thumb = layout.thumbFrame(offset: model.scrollOffset, isHovered: model.isThumbHovered) {
                Capsule()
                    .fill(theme.foregroundColor.opacity(
                        model.isThumbHovered ? MonknotScrollbarStyle.hoveredOpacity : MonknotScrollbarStyle.restingOpacity
                    ))
                    .frame(width: thumb.width, height: thumb.height)
                    .offset(x: thumb.minX, y: thumb.minY)
                    .opacity(model.showsThumb ? 1 : 0)
            }
        }
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
        let leading: MonknotMenuRowLeading = !layout.hasGlyphColumn ? .none
            : item.swatch.map { .swatch($0) } ?? item.systemImage.map { .glyph($0) } ?? .blank
        return MonknotMenuRowLabel(
            leading: leading,
            title: item.title,
            isHighlighted: isHighlighted,
            isDisabled: !item.isEnabled,
            isDestructive: item.isDestructive,
            theme: theme,
            zoomScale: zoomScale
        ) {
            if layout.reservesCheck {
                MonknotMenuRowCheck(isDisabled: !item.isEnabled, theme: theme, zoomScale: zoomScale)
                    .opacity(item.isChecked ? 1 : 0)
            }
        }
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

    init(title: String, isEnabled: Bool, isChecked: Bool, frame: NSRect, parent: NSView, press: @escaping () -> Bool) {
        self.press = press
        super.init()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(isEnabled)
        setAccessibilitySelected(isChecked)
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
/// appearance, and a menu with a submenu. A control's menu (a pop-up's values, the PDF bar's More)
/// is the same menu, opened below the control by `presentMenu`.
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
        /// Told the chosen entry, or nil when the menu closed without a choice.
        let onClose: ((Int?) -> Void)?
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
    /// Where a drag of the thumb started: the pointer's height on screen and the offset then.
    private var thumbDrag: (pointerY: CGFloat, offset: CGFloat)?
    private var thumbHide: DispatchWorkItem?
    /// How long the thumb stays after the rows stop scrolling, as in Preview's menus.
    static let thumbLinger: TimeInterval = 0.7

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
            if isInPanel {
                scroll(with: event)
            } else {
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

    /// Shows a control's menu below `anchor` (design.md §5.1, §5.3): a menu button's commands (the PDF
    /// bar's More), or a pop-up's values with the current one checked, highlighted and in view. Its
    /// leading edge is on the control's, 4 clear of it, above it where the screen ends; where it would
    /// cross the window's trailing edge (a control at the end of a bar), it ends on the control's
    /// trailing edge instead. It is at least as wide as the control, and scrolls past
    /// `maximumHeightBase`. False when `anchor` is in no window.
    @discardableResult
    func presentMenu(
        _ entries: [MonknotContextMenuModel.Entry],
        below anchor: NSView,
        theme: AppTheme,
        zoomScale: Double,
        maximumHeightBase: CGFloat? = nil,
        onHighlight: ((Int?) -> Void)? = nil,
        onClose: @escaping (Int?) -> Void
    ) -> Bool {
        guard let window = anchor.window, !entries.isEmpty else { return false }
        install()
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let gap = MonknotMetrics.interfaceDensity(4, theme: theme, zoomScale: zoomScale)
        present(
            entries: entries,
            at: NSPoint(x: anchorRect.minX, y: anchorRect.minY - gap),
            flippedAbove: anchorRect.maxY + gap,
            flippedLeftTo: anchorRect.maxX,
            within: window.frame.maxX,
            in: window,
            theme: theme,
            zoomScale: zoomScale,
            minimumWidth: anchorRect.width,
            maximumHeight: maximumHeightBase.map { MonknotMetrics.interfaceDensity($0, theme: theme, zoomScale: zoomScale) },
            highlighted: entries.firstIndex { $0.item?.isChecked == true },
            onHighlight: onHighlight,
            onClose: onClose
        )
        openingPressIsDown = false
        return true
    }

    /// Shows `entries` with the surface's top-left corner at `screenPoint`, flipped left or up where
    /// the screen (or `within`, a trailing edge it keeps inside) ends, 6 clear of the screen's edge;
    /// flipped up, its bottom edge is at `flippedAbove`, and flipped left its trailing edge is at
    /// `flippedLeftTo`, or at the point itself. A menu taller than `maximumHeight` or the screen
    /// scrolls; `highlighted` opens highlighted and in view, without telling `onHighlight`.
    func present(
        entries: [MonknotContextMenuModel.Entry],
        menu: NSMenu? = nil,
        at screenPoint: NSPoint,
        flippedAbove: CGFloat? = nil,
        flippedLeftTo: CGFloat? = nil,
        within trailingLimit: CGFloat? = nil,
        in window: NSWindow,
        theme: AppTheme,
        zoomScale: Double,
        minimumWidth: CGFloat = 0,
        maximumHeight: CGFloat? = nil,
        highlighted: Int? = nil,
        onHighlight: ((Int?) -> Void)? = nil,
        onClose: ((Int?) -> Void)? = nil
    ) {
        close(animated: false)

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 6, dy: 6)
            ?? NSRect(origin: .zero, size: CGSize(width: 10_000, height: 10_000))
        let model = MonknotContextMenuModel(entries: entries)
        let layout = MonknotContextMenuLayout(
            entries: entries,
            theme: theme,
            zoomScale: zoomScale,
            minimumWidth: minimumWidth,
            maximumHeight: min(maximumHeight ?? .greatestFiniteMagnitude, visible.height)
        )
        if let highlighted, model.isEnabled(highlighted) {
            model.highlighted = highlighted
            model.scrollOffset = layout.offset(centering: highlighted)
        }
        model.onHighlight = onHighlight
        let size = layout.size
        var surface = NSRect(x: screenPoint.x, y: screenPoint.y - size.height, width: size.width, height: size.height)
        var anchor = UnitPoint.topLeading
        if surface.maxX > min(visible.maxX, trailingLimit ?? .greatestFiniteMagnitude) {
            surface.origin.x = (flippedLeftTo ?? screenPoint.x) - size.width
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
        guard surface.contains(location) else { return nil }
        let point = CGPoint(x: location.x - surface.minX, y: surface.maxY - location.y + presentation.model.scrollOffset)
        return presentation.layout.entry(at: point)
    }

    /// The pointer is in the thumb's lane while the thumb shows, where a press drags it.
    private var pointerIsOverThumbLane: Bool {
        guard let presentation, presentation.layout.scrolls, presentation.model.showsThumb else { return false }
        let surface = presentation.surfaceFrame
        let lane = NSRect(
            x: surface.maxX - MonknotScrollbarStyle.trackWidth,
            y: surface.minY,
            width: MonknotScrollbarStyle.trackWidth,
            height: surface.height
        )
        return lane.contains(NSEvent.mouseLocation)
    }

    private var pointerIsOverSurface: Bool {
        guard let presentation else { return false }
        return presentation.surfaceFrame.contains(NSEvent.mouseLocation)
    }

    func pointerMoved() {
        guard let presentation else { return }
        let model = presentation.model
        if let thumbDrag {
            let dragged = thumbDrag.pointerY - NSEvent.mouseLocation.y
            setScrollOffset(thumbDrag.offset + dragged * presentation.layout.scrollPerThumbPoint)
            return
        }
        let overLane = pointerIsOverThumbLane
        if model.isThumbHovered != overLane {
            withAnimation(MonknotMotion.hoverAnimation) {
                model.isThumbHovered = overLane
            }
        }
        if overLane {
            // A thumb under the pointer stays until the pointer leaves it.
            cancelThumbHide()
        } else if model.showsThumb, thumbHide == nil {
            scheduleThumbHide()
        }
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
        if pointerIsOverThumbLane {
            thumbDrag = (NSEvent.mouseLocation.y, model.scrollOffset)
            cancelThumbHide()
            return
        }
        pointerMoved()
        model.pressed = model.highlighted
    }

    func pointerUp() {
        guard let model = presentation?.model else { return }
        if thumbDrag != nil {
            thumbDrag = nil
            pointerMoved()
            return
        }
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

    // MARK: Scrolling

    /// A wheel or trackpad over a menu taller than it may be scrolls its rows; the row under the
    /// pointer takes the highlight as they pass.
    private func scroll(with event: NSEvent) {
        guard let presentation, presentation.layout.scrolls else { return }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * presentation.layout.rowHeight
        setScrollOffset(presentation.model.scrollOffset - delta)
        pointerMoved()
    }

    private func setScrollOffset(_ offset: CGFloat) {
        guard let presentation else { return }
        let clamped = presentation.layout.clampedOffset(offset)
        guard clamped != presentation.model.scrollOffset else { return }
        presentation.model.scrollOffset = clamped
        presentation.model.showsThumb = true
        if thumbDrag == nil, !presentation.model.isThumbHovered {
            scheduleThumbHide()
        } else {
            cancelThumbHide()
        }
    }

    private func cancelThumbHide() {
        thumbHide?.cancel()
        thumbHide = nil
    }

    /// The thumb fades a moment after the rows stop, unless the pointer is on it.
    private func scheduleThumbHide() {
        thumbHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let model = self.presentation?.model else { return }
            self.thumbHide = nil
            guard self.thumbDrag == nil, !model.isThumbHovered else { return }
            withAnimation(MonknotMotion.hoverAnimation) {
                model.showsThumb = false
            }
        }
        thumbHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbLinger, execute: work)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) {
        guard let presentation else { return }
        let model = presentation.model
        let before = model.highlighted
        defer {
            // The keys keep the row they reach in view.
            if let after = presentation.model.highlighted, after != before, self.presentation?.id == presentation.id {
                setScrollOffset(presentation.layout.offset(revealing: after, from: model.scrollOffset))
            }
        }
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
        case 49 where isTypeSelecting:
            // A space inside a name being typed ("Helvetica Neue") goes on finding it.
            typeSelect(" ", modifiers: modifiers, model: model)
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

    private var isTypeSelecting: Bool {
        !typeSelection.isEmpty && ProcessInfo.processInfo.systemUptime - typeSelectionTime <= 1
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
        close(chosen: index)
        // The action runs once the menu has started to leave, as a system menu's does.
        DispatchQueue.main.async {
            item.perform()
        }
    }

    /// Closes the open menu: a 90 ms fade, or at once. `chosen` is the entry whose action runs next.
    func close(animated: Bool = true, chosen: Int? = nil) {
        guard let presentation else { return }
        self.presentation = nil
        openingPressIsDown = false
        typeSelection = ""
        thumbDrag = nil
        cancelThumbHide()
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
        presentation.onClose?(chosen)
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
                y: surface.maxY - frame.maxY + presentation.model.scrollOffset,
                width: frame.width,
                height: frame.height
            )
            return MonknotContextMenuAccessibilityRow(
                title: item.title,
                isEnabled: item.isEnabled,
                isChecked: item.isChecked,
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
