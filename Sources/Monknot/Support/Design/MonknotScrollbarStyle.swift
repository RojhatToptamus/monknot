import AppKit
import MonknotCore
import SwiftUI

enum MonknotScrollbarStyle {
    /// The lane a thumb sits in, flush with a scroll view's trailing or bottom edge (design.md §5.7).
    /// With "Show scroll bars: Always" a document reserves this lane, so text never runs under the
    /// thumb.
    /// The geometry is `ScrollThumbGeometry`'s (MonknotCore), which Preview's page draws from too.
    static let trackWidth = CGFloat(ScrollThumbGeometry.trackWidth)
    /// The thumb is a slim capsule with no track. It rests quiet and widens and darkens under the
    /// pointer, so it is easy to grab with a mouse.
    static let restingThumbWidth = CGFloat(ScrollThumbGeometry.restingThumbWidth)
    static let hoveredThumbWidth = CGFloat(ScrollThumbGeometry.hoveredThumbWidth)
    /// Where the thumb's centre sits, measured from the container's edge: the middle of the lane, so
    /// a resting thumb is 2.5 from the edge, close to the divider beside it, and grows from there.
    static let thumbCenterInset: CGFloat = trackWidth / 2
    static let restingOpacity = CGFloat(ScrollThumbGeometry.restingOpacity)
    static let hoveredOpacity = CGFloat(ScrollThumbGeometry.hoveredOpacity)
    /// The thumb's ends stay this far from the ends of a list or card, clear of its rounded corners.
    static let endInset = CGFloat(ScrollThumbGeometry.endInset)

    /// Documents (editor, plain text, PDF) take the same thumb as the chrome. They follow System
    /// Settings › Appearance › Show scroll bars: an overlay thumb fades and takes no width; with
    /// "Always" the thumb stays visible in a reserved lane, so text never rewraps when the document
    /// grows past one screen. Re-apply when `NSScroller.preferredScrollerStyleDidChangeNotification`
    /// posts.
    static func applyDocument(to scrollView: NSScrollView, thumbColor: NSColor? = nil) {
        let style = NSScroller.preferredScrollerStyle
        install(on: scrollView, thumbColor: thumbColor)
        if scrollView.scrollerStyle != style {
            scrollView.scrollerStyle = style
        }
        let autohides = style == .overlay
        if scrollView.autohidesScrollers != autohides {
            scrollView.autohidesScrollers = autohides
        }
        applyEndInsets(to: scrollView)
    }

    /// Chrome lists (sidebar, search results, palettes, panels, Settings) always use the overlay
    /// thumb, which fades: a list never reserves a lane. Keep the style with
    /// `MonknotChromeScrollerBehavior`, because AppKit resets it whenever the system setting or the
    /// attached mouse changes.
    static func applyChrome(to scrollView: NSScrollView, thumbColor: NSColor) {
        scrollView.autohidesScrollers = true
        install(on: scrollView, thumbColor: thumbColor)
        applyEndInsets(to: scrollView)
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
            // Give the list back the width the legacy bar took.
            scrollView.tile()
        }
    }

    /// The thumb takes the theme's ink, like every other mark in the chrome (design.md §5.7).
    static func thumbColor(for theme: AppTheme) -> NSColor {
        NSColor(hex: theme.foreground)
    }

    /// The vertical scroller is replaced even while hidden, so a view that turns it on later
    /// (PDFThumbnailView does) shows the Monknot thumb.
    private static func install(on scrollView: NSScrollView, thumbColor: NSColor?) {
        let vertical = scroller(of: scrollView, vertical: true)
        if let thumbColor { vertical.thumbColor = thumbColor }
        if scrollView.hasHorizontalScroller {
            let horizontal = scroller(of: scrollView, vertical: false)
            if let thumbColor { horizontal.thumbColor = thumbColor }
        }
    }

    /// Clears a thumb's ends of a card's rounded corners. A scroller is inset only along its length:
    /// an inset across it (the right one for a vertical scroller) moves the whole lane off the edge,
    /// leaving an unpainted strip between the thumb and the card's edge. With both scrollers, each
    /// ends where the other's lane begins, so only their far ends are inset.
    static func endInsets(hasVertical: Bool, hasHorizontal: Bool) -> NSEdgeInsets {
        NSEdgeInsets(
            top: hasVertical ? endInset : 0,
            left: hasHorizontal ? endInset : 0,
            bottom: hasVertical && !hasHorizontal ? endInset : 0,
            right: hasHorizontal && !hasVertical ? endInset : 0
        )
    }

    private static func applyEndInsets(to scrollView: NSScrollView) {
        let insets = endInsets(hasVertical: scrollView.hasVerticalScroller, hasHorizontal: scrollView.hasHorizontalScroller)
        if !NSEdgeInsetsEqual(scrollView.scrollerInsets, insets) {
            scrollView.scrollerInsets = insets
        }
    }

    private static func scroller(of scrollView: NSScrollView, vertical: Bool) -> MonknotScroller {
        let current = vertical ? scrollView.verticalScroller : scrollView.horizontalScroller
        if let scroller = current as? MonknotScroller {
            return scroller
        }
        let scroller = MonknotScroller(frame: .zero)
        if vertical {
            scrollView.verticalScroller = scroller
        } else {
            scrollView.horizontalScroller = scroller
        }
        return scroller
    }
}

/// The Monknot thumb: a slim capsule with no track, in overlay and legacy styles alike. In the legacy
/// style its lane stays transparent, so the document's own background shows behind the thumb.
final class MonknotScroller: NSScroller {
    /// AppKit treats scroller subclasses as legacy-only unless they opt in (see NSScroller.h).
    override class var isCompatibleWithOverlayScrollers: Bool {
        self == MonknotScroller.self
    }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        MonknotScrollbarStyle.trackWidth
    }

    override var isOpaque: Bool { false }

    var thumbColor: NSColor = .labelColor {
        didSet {
            if thumbColor != oldValue {
                needsDisplay = true
            }
        }
    }

    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                needsDisplay = true
            }
        }
    }
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        // Active in every window so the exit still arrives after the window resigns key; a key-only
        // area would leave the thumb wide until the pointer next crossed it.
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let rect = Self.thumbRect(
            knob: knobRect,
            bounds: bounds,
            isVertical: bounds.height >= bounds.width,
            isHovered: isHovered
        )
        let opacity = isHovered
            ? MonknotScrollbarStyle.hoveredOpacity
            : MonknotScrollbarStyle.restingOpacity
        thumbColor.withAlphaComponent(opacity).setFill()
        let radius = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// The visible capsule inside AppKit's knob rect: centred `thumbCenterInset` from the container's
    /// edge, so it rests 2.5 from the edge and grows from its centre under the pointer.
    static func thumbRect(knob: NSRect, bounds: NSRect, isVertical: Bool, isHovered: Bool) -> NSRect {
        let thickness = isHovered
            ? MonknotScrollbarStyle.hoveredThumbWidth
            : MonknotScrollbarStyle.restingThumbWidth
        let center = MonknotScrollbarStyle.thumbCenterInset
        if isVertical {
            return NSRect(
                x: bounds.maxX - center - thickness / 2,
                y: knob.minY + 1,
                width: thickness,
                height: max(thickness, knob.height - 2)
            )
        }
        return NSRect(
            x: knob.minX + 1,
            y: bounds.maxY - center - thickness / 2,
            width: max(thickness, knob.width - 2),
            height: thickness
        )
    }

    /// No slot in any style: the lane shows what is behind it.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Keeps a chrome list on the overlay thumb whatever "Show scroll bars" says (design.md §5.7). The thumb
/// appears only while the list scrolls, as the system's overlay scroller does: a thumb that also
/// appeared whenever the pointer crossed the list sat beside the divider and read as a resize handle.
final class MonknotChromeScrollerBehavior: NSResponder {
    private weak var scrollView: NSScrollView?
    private var styleObserver: NSObjectProtocol?

    var thumbColor: NSColor = .labelColor {
        didSet {
            guard thumbColor != oldValue, let scrollView else { return }
            MonknotScrollbarStyle.applyChrome(to: scrollView, thumbColor: thumbColor)
        }
    }

    /// Styles `scrollView` immediately, so it lays out with the overlay thumb from its first pass.
    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        // AppKit puts every scroll view back on the system style after posting this.
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let scrollView = self.scrollView else { return }
                MonknotScrollbarStyle.applyChrome(to: scrollView, thumbColor: self.thumbColor)
            }
        }
        MonknotScrollbarStyle.applyChrome(to: scrollView, thumbColor: thumbColor)
    }

    func detach() {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
        }
        styleObserver = nil
        scrollView = nil
    }

    deinit {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
        }
    }
}

/// A SwiftUI scroll view for chrome lists. Its backing `NSScrollView` takes the overlay thumb as the
/// content enters the view hierarchy, before the first layout pass, so a legacy bar never flashes
/// and the content never shifts sideways.
struct MonknotScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let thumbColor: NSColor
    private let content: Content

    init(_ axes: Axis.Set = .vertical, theme: AppTheme, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.thumbColor = MonknotScrollbarStyle.thumbColor(for: theme)
        self.content = content()
    }

    var body: some View {
        ScrollView(axes) {
            content.background(MonknotScrollbarConfigurator(thumbColor: thumbColor))
        }
    }
}

private struct MonknotScrollbarConfigurator: NSViewRepresentable {
    let thumbColor: NSColor

    func makeNSView(context: Context) -> ConfigurationView {
        let view = ConfigurationView()
        view.behavior.thumbColor = thumbColor
        return view
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.behavior.thumbColor = thumbColor
    }

    final class ConfigurationView: NSView {
        let behavior = MonknotChromeScrollerBehavior()

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachToEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToEnclosingScrollView()
        }

        private func attachToEnclosingScrollView() {
            if let scrollView = enclosingScrollView {
                behavior.attach(to: scrollView)
            } else {
                behavior.detach()
            }
        }
    }
}
