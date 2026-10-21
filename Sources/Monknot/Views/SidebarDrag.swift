import AppKit
import MonknotCore
import SwiftUI

/// A sidebar row being moved (design.md §10.4, "Moving files"). Inside the sidebar the drag is the
/// tree's own, so every frame of it is Monknot's: the row stays at 35 % while a copy of it, the row's
/// glyph and name on a floating surface, rides under the pointer; Option copies; a closed folder
/// opens after the system's spring-loading delay; the list scrolls near its edges; Esc or a drop on
/// no target glides the copy back. Leaving the sidebar hands the item to a system file drag, so it
/// can be dropped on the terminal, an editor or Finder.
@MainActor
final class SidebarDragSession: NSObject, NSDraggingSource {
    struct Item {
        let rowID: String
        /// The row's own item when the drag began. The drop moves the items the drag picked up,
        /// never whatever the row shows by then.
        let url: URL
        /// The row's item, or every selected item when the row is one of several selected.
        let urls: [URL]
        let title: String
        let systemImage: String
    }

    /// What the sidebar does as the drag goes on.
    struct Handlers {
        /// The pointer moved, or the list scrolled under it: resolve the target again.
        var pointerMoved: () -> Void = {}
        /// Option went down or up.
        var copiesChanged: (Bool) -> Void = { _ in }
        /// A closed folder held under the pointer for the spring-loading delay.
        var springOpen: (String) -> Void = { _ in }
        /// Esc, or the drag handed off: the tree's own drag is over without a drop.
        var cancelled: () -> Void = {}
        /// The drag left the sidebar and became a system file drag.
        var handedOff: () -> Void = {}
        /// The system file drag ended, dropped or not.
        var handOffEnded: () -> Void = {}
        /// The copy has glided back to its row, after Esc or a drop on no target.
        var returned: () -> Void = {}
    }

    /// How far the shadow of the copy reaches beyond it.
    static let shadowMargin: CGFloat = 24
    /// The auto-scroll zone at each edge of the list, in rows, and the speed at the edge itself.
    static let autoScrollZoneRows: CGFloat = 1
    static let autoScrollRowsPerSecond: CGFloat = 12
    static let fadeDuration = MonknotMotion.hoverDuration
    static let slideBackDuration = MonknotMotion.paneTransitionDuration

    private(set) var item: Item?
    private(set) var isCancelled = false
    private(set) var isHandedOff = false
    private(set) var copies = false
    /// Folders the drag opened by spring-loading, which close again unless the drop lands in them.
    private(set) var springOpenedFolderIDs: Set<String> = []

    /// The tree's hosting view, whose coordinates are the rows' (it is flipped).
    weak var treeView: NSView?
    /// The sidebar's column, which the drag leaves to become a system file drag.
    weak var sidebarView: NSView?

    private var handlers = Handlers()
    private var theme = AppTheme.defaultLight
    private var zoomScale = 1.0
    private var windowPoint: NSPoint?
    /// The pointer's offset from the copy's top-left corner, in points.
    private var grabOffset = CGSize.zero
    private var chipPanel: NSPanel?
    private var chipSize = CGSize.zero
    private var chipStartFrame: NSRect?
    private var keyMonitor: Any?
    private var scrollTimer: Timer?
    private var springTimer: Timer?
    private var springCandidateID: String?

    var isActive: Bool {
        item != nil && !isCancelled && !isHandedOff
    }

    func isActive(for rowID: String) -> Bool {
        isActive && item?.rowID == rowID
    }

    // MARK: Beginning

    func begin(item: Item, copies: Bool, theme: AppTheme, zoomScale: Double, handlers: Handlers) {
        end()
        self.item = item
        self.copies = copies
        self.theme = theme
        self.zoomScale = zoomScale
        self.handlers = handlers
        isCancelled = false
        isHandedOff = false
        springOpenedFolderIDs = []
        (copies ? NSCursor.dragCopy : NSCursor.arrow).set()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            // AppKit calls local event-monitor handlers on the main thread.
            let consumes = MainActor.assumeIsolated { self.handleKey(event) }
            return consumes ? nil : event
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    /// Lifts the copy off the row, its glyph where the row's glyph was, once the row's frame is known.
    func liftCopy(rowFrame: CGRect, depth: Int) {
        guard chipPanel == nil, isActive, let item, let treeView, let window = treeView.window, let windowPoint else { return }
        let indent = MonknotMetrics.scale(MonknotMetrics.rowIndentBase, theme: theme, zoomScale: zoomScale) * CGFloat(depth)
        let chipView = SidebarDragChip(title: item.title, systemImage: item.systemImage, theme: theme, zoomScale: zoomScale)
        let hosting = NSHostingView(rootView: chipView.padding(Self.shadowMargin))
        let fitting = hosting.fittingSize
        chipSize = CGSize(width: fitting.width - 2 * Self.shadowMargin, height: fitting.height - 2 * Self.shadowMargin)

        // The copy's top-left corner where the row's content starts, so it lifts off in place; the
        // pointer stays over the copy even when it took the row far right of a short name.
        let pointer = treeView.convert(windowPoint, from: nil)
        let origin = CGPoint(x: rowFrame.minX + indent, y: rowFrame.minY)
        grabOffset = CGSize(
            width: min(max(pointer.x - origin.x, 8), max(8, chipSize.width - 12)),
            height: min(max(pointer.y - origin.y, 0), chipSize.height)
        )

        let panel = MonknotContextMenuPanel(
            contentRect: NSRect(origin: .zero, size: fitting),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: fitting)
        panel.contentView = hosting
        panel.alphaValue = 0
        chipPanel = panel
        // Where it starts is where Esc glides it back to.
        let startTopLeft = window.convertPoint(toScreen: treeView.convert(origin, to: nil))
        chipStartFrame = panelFrame(topLeft: startTopLeft)
        positionChip()
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    // MARK: Moving

    /// The pointer, in the tree's coordinates as the drag gesture reports it.
    func pointerMoved(toTreePoint point: CGPoint) {
        guard isActive, let treeView else { return }
        windowPoint = treeView.convert(point, to: nil)
        positionChip()
    }

    /// The pointer in the tree's coordinates now, after any scrolling under it.
    var treePoint: CGPoint? {
        guard let windowPoint, let treeView else { return nil }
        return treeView.convert(windowPoint, from: nil)
    }

    /// Whether the pointer, at `windowPoint`, has left the sidebar, so the drag becomes a file drag.
    func leavesSidebar(at windowPoint: NSPoint) -> Bool {
        guard isActive, let sidebarView else { return false }
        return !sidebarView.convert(sidebarView.bounds, to: nil).contains(windowPoint)
    }

    private func panelFrame(topLeft: NSPoint) -> NSRect {
        let margin = Self.shadowMargin
        return NSRect(
            x: topLeft.x - margin,
            y: topLeft.y - chipSize.height - margin,
            width: chipSize.width + 2 * margin,
            height: chipSize.height + 2 * margin
        )
    }

    private func positionChip() {
        guard let chipPanel, let windowPoint, let window = treeView?.window else { return }
        let pointer = window.convertPoint(toScreen: windowPoint)
        chipPanel.setFrame(
            panelFrame(topLeft: NSPoint(x: pointer.x - grabOffset.width, y: pointer.y + grabOffset.height)),
            display: true
        )
    }

    // MARK: Keys

    /// Esc cancels; Option copies while it is held. Every other key is ignored while the drag lasts.
    /// The button coming up reads the keys held then, before the gesture sees the event and drops.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if event.type == .flagsChanged || event.type == .leftMouseUp {
            setCopies(event.modifierFlags.contains(.option))
            return false
        }
        if event.keyCode == 53 {
            cancel()
        }
        return true
    }

    func setCopies(_ copies: Bool) {
        guard isActive, copies != self.copies else { return }
        self.copies = copies
        (copies ? NSCursor.dragCopy : NSCursor.arrow).set()
        handlers.copiesChanged(copies)
    }

    // MARK: Spring-loading

    /// The system's spring-loading delay (System Settings › Accessibility › Pointer Control), 0.5 s
    /// unless changed; none when spring-loading is off.
    static var springLoadingDelay: TimeInterval? {
        let defaults = UserDefaults.standard
        if let enabled = defaults.object(forKey: "com.apple.springing.enabled") as? Bool, !enabled {
            return nil
        }
        let delay = defaults.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        return min(max(delay, 0.1), 2)
    }

    /// The closed folder under the pointer, or nil: held there for the delay, it opens.
    func springLoad(folderID: String?) {
        guard folderID != springCandidateID else { return }
        springTimer?.invalidate()
        springTimer = nil
        springCandidateID = folderID
        guard let folderID, let delay = Self.springLoadingDelay else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.springCandidateID == folderID else { return }
                self.springCandidateID = nil
                if self.isActive {
                    self.springOpenedFolderIDs.insert(folderID)
                    self.handlers.springOpen(folderID)
                } else if self.isExternalTargeting {
                    self.externalSpringOpen(folderID)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    /// A file drag from Finder, another window or one handed off from here is over a row: it springs
    /// folders open too.
    private(set) var isExternalTargeting = false
    private var externalSpringOpen: (String) -> Void = { _ in }

    func externalTargeting(folderID: String?, springOpen: @escaping (String) -> Void) {
        guard !isActive else { return }
        isExternalTargeting = folderID != nil
        externalSpringOpen = springOpen
        springLoad(folderID: folderID)
    }

    // MARK: Auto-scroll

    /// Within a row of the list's top or bottom edge the tree scrolls, slowly at the zone's inner
    /// edge and 12 rows a second at the edge itself (beyond it too); the target updates under a
    /// pointer that holds still.
    private func autoScroll() {
        guard isActive, let windowPoint, let treeView, let scrollView = treeView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.convert(clip.bounds, to: nil)
        guard windowPoint.x >= visible.minX, windowPoint.x <= visible.maxX else { return }
        let row = MonknotMetrics.scale(MonknotMetrics.rowHeightBase, theme: theme, zoomScale: zoomScale)
        let zone = row * Self.autoScrollZoneRows
        let maximumSpeed = row * Self.autoScrollRowsPerSecond
        let fromTop = visible.maxY - windowPoint.y
        let fromBottom = windowPoint.y - visible.minY
        var velocity: CGFloat = 0
        if fromTop < zone {
            velocity = -maximumSpeed * min(1, (zone - fromTop) / zone)
        } else if fromBottom < zone {
            velocity = maximumSpeed * min(1, (zone - fromBottom) / zone)
        }
        guard velocity != 0, let document = scrollView.documentView else { return }
        let maximumY = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        // The tree's clip view is flipped with its document, so a larger y scrolls down.
        origin.y = min(max(0, origin.y + velocity / 60), maximumY)
        guard abs(origin.y - clip.bounds.origin.y) > 0.01 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        handlers.pointerMoved()
    }

    // MARK: Ending

    /// Esc: the drag ends without a drop, and the copy glides back to its row.
    func cancel() {
        guard isActive else { return }
        isCancelled = true
        stopTracking()
        handlers.cancelled()
        slideBack()
    }

    /// The drop landed: the copy fades where it is.
    func finishDropped() {
        stopTracking()
        fadeOutChip()
        item = nil
    }

    /// The drop found no target: the copy glides back to its row.
    func finishWithoutTarget() {
        guard item != nil else { return }
        isCancelled = true
        stopTracking()
        slideBack()
    }

    /// Forgets the spring-opened folders the caller has dealt with.
    func clearSpringOpenedFolders() {
        springOpenedFolderIDs = []
    }

    private func slideBack() {
        guard let panel = chipPanel, let start = chipStartFrame,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            fadeOutChip()
            finishReturn()
            return
        }
        chipPanel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideBackDuration
            context.timingFunction = MonknotMotion.paneTimingFunction
            panel.animator().setFrame(start, display: true)
        }
        // Finished on a timer rather than in the animation's completion, which never runs while
        // the screen is locked or asleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideBackDuration) { [weak self] in
            Self.fade(panel)
            self?.finishReturn()
        }
    }

    private func finishReturn() {
        let returned = handlers.returned
        item = nil
        returned()
    }

    private func fadeOutChip() {
        guard let panel = chipPanel else { return }
        chipPanel = nil
        Self.fade(panel)
    }

    private static func fade(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonknotContextMenuController.exitDuration
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MonknotContextMenuController.exitDuration + 0.02) {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func stopTracking() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        scrollTimer?.invalidate()
        scrollTimer = nil
        springTimer?.invalidate()
        springTimer = nil
        springCandidateID = nil
        NSCursor.arrow.set()
    }

    /// Ends whatever drag is under way at once, without a drop.
    func end() {
        stopTracking()
        if let chipPanel {
            chipPanel.parent?.removeChildWindow(chipPanel)
            chipPanel.orderOut(nil)
        }
        chipPanel = nil
        chipStartFrame = nil
        item = nil
        windowPoint = nil
        isHandedOff = false
        isCancelled = false
        copies = false
    }

    // MARK: Leaving the sidebar

    /// The pointer left the sidebar: the item becomes a system file drag from here, with the copy as
    /// its image, so the terminal types its path, an editor links it and Finder copies it.
    func handOff(_ event: NSEvent, from view: NSView) {
        guard isActive, let item, let image = chipImage() else { return }
        isHandedOff = true
        stopTracking()
        if let chipPanel {
            chipPanel.parent?.removeChildWindow(chipPanel)
            chipPanel.orderOut(nil)
        }
        chipPanel = nil
        let point = view.convert(event.locationInWindow, from: nil)
        let margin = Self.shadowMargin
        let originY = view.isFlipped
            ? point.y - grabOffset.height - margin
            : point.y + grabOffset.height + margin - image.size.height
        let frame = NSRect(x: point.x - grabOffset.width - margin, y: originY, width: image.size.width, height: image.size.height)
        // One file URL per item; the copy is the first item's image and stands for them all.
        let draggingItems = item.urls.enumerated().map { index, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            draggingItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return draggingItem
        }
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        handlers.handedOff()
    }

    private func chipImage() -> NSImage? {
        guard let item else { return nil }
        let view = SidebarDragChip(title: item.title, systemImage: item.systemImage, theme: theme, zoomScale: zoomScale)
            .padding(Self.shadowMargin)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = treeView?.window?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Another app only ever copies the file, so a drop on Finder never moves it out of the
        // workspace; within Monknot it can move (back into the tree) or link (an editor).
        context == .outsideApplication ? .copy : [.copy, .move, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            let ended = handlers.handOffEnded
            end()
            ended()
        }
    }
}

/// The copy of a row that rides under the pointer: the row's glyph and name on the floating surface,
/// 28 tall, radius 8, `e2`, at most 240 wide.
struct SidebarDragChip: View {
    let title: String
    let systemImage: String
    let theme: AppTheme
    let zoomScale: Double

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: density(MonknotMetrics.rowGlyphGapBase)) {
            MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.mutedForegroundColor)
            Text(title)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, density(MonknotMetrics.rowPaddingBase))
        .padding(.trailing, density(10))
        .frame(height: MonknotMetrics.scale(MonknotMetrics.rowHeightBase, theme: theme, zoomScale: zoomScale))
        .frame(maxWidth: density(240), alignment: .leading)
        .monknotFloatingSurface(
            .e2,
            cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale),
            fill: theme.elevatedSurfaceColor,
            theme: theme
        )
        .accessibilityHidden(true)
    }
}

/// Gives the drag session the sidebar's column, which the drag leaves to become a file drag.
struct SidebarDragBounds: NSViewRepresentable {
    let session: SidebarDragSession

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        session.sidebarView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        session.sidebarView = view
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
