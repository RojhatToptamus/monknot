import AppKit
import MonknotCore
import SwiftUI

enum MonknotScrollbarStyle {
    static let trackWidth: CGFloat = 12
    /// The thumb is a mark, not a control surface (design.md §7: scroll thumbs take radius 2). It rests
    /// slim and quiet while the list scrolls or the pointer is over it, and widens and darkens under
    /// the pointer so it is easy to grab with a mouse.
    static let restingThumbWidth: CGFloat = 4
    static let hoveredThumbWidth: CGFloat = 6
    static let thumbRadius: CGFloat = 2
    static let restingOpacity: CGFloat = 0.35
    static let hoveredOpacity: CGFloat = 0.7

    /// Documents (editor, PDF, preview) keep AppKit's own scroller, which follows System Settings ›
    /// Appearance › Show scroll bars. A legacy scroller stays laid out while the document fits, so text
    /// never rewraps when the document grows past one screen; an overlay scroller takes no width and
    /// hides as usual. Re-apply when `NSScroller.preferredScrollerStyleDidChangeNotification` posts.
    static func applyDocument(to scrollView: NSScrollView) {
        let autohides = NSScroller.preferredScrollerStyle == .overlay
        if scrollView.autohidesScrollers != autohides {
            scrollView.autohidesScrollers = autohides
        }
    }

    /// Chrome lists (sidebar, search results, palettes, panels, Settings) always use the slim overlay
    /// thumb. With a mouse attached, AppKit would otherwise give each one a legacy bar with an
    /// opaque track, the loudest thing in a 248pt sidebar. Keep the style with `MonknotChromeScrollerBehavior`,
    /// because AppKit resets it whenever the system setting or the attached mouse changes.
    static func applyChrome(to scrollView: NSScrollView, thumbColor: NSColor) {
        scrollView.autohidesScrollers = true
        // The vertical scroller is replaced even while hidden, so a list that turns it on later
        // (PDFThumbnailView does) shows the chrome thumb.
        chromeScroller(of: scrollView, vertical: true).thumbColor = thumbColor
        if scrollView.hasHorizontalScroller {
            chromeScroller(of: scrollView, vertical: false).thumbColor = thumbColor
        }
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

    private static func chromeScroller(of scrollView: NSScrollView, vertical: Bool) -> MonknotScroller {
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

    /// The same thumb for a web view's scroll bar. WebKit draws a styled scroll bar as a fixed bar and
    /// does not repaint it when a class changes, so it cannot fade in and out like an overlay scroller:
    /// it stays at the resting strength and brightens only under the pointer.
    static func webCSS(
        selector: String = "*",
        restingColor: String = "color-mix(in srgb, CanvasText 35%, transparent)",
        hoveredColor: String = "color-mix(in srgb, CanvasText 70%, transparent)"
    ) -> String {
        let restingInset = (trackWidth - restingThumbWidth) / 2
        let hoveredInset = (trackWidth - hoveredThumbWidth) / 2

        // The border is the inset, so the corner radius includes it to leave `thumbRadius` on the thumb.
        return """
        \(selector)::-webkit-scrollbar {
          width: \(cssPixels(trackWidth));
          height: \(cssPixels(trackWidth));
          background: transparent;
        }
        \(selector)::-webkit-scrollbar-track {
          background: transparent;
        }
        \(selector)::-webkit-scrollbar-thumb {
          background: \(restingColor);
          background-clip: content-box;
          border: \(cssPixels(restingInset)) solid transparent;
          border-radius: \(cssPixels(thumbRadius + restingInset));
        }
        \(selector)::-webkit-scrollbar-thumb:hover {
          background: \(hoveredColor);
          background-clip: content-box;
          border: \(cssPixels(hoveredInset)) solid transparent;
          border-radius: \(cssPixels(thumbRadius + hoveredInset));
        }
        \(selector)::-webkit-scrollbar-corner {
          background: transparent;
        }
        """
    }

    private static func cssPixels(_ value: CGFloat) -> String {
        value.rounded() == value ? "\(Int(value))px" : "\(value)px"
    }
}

/// The slim overlay thumb of a chrome list. Should AppKit put the scroll view on the legacy style
/// before `MonknotChromeScrollerBehavior` restores it, the scroller draws AppKit's own knob and track.
final class MonknotScroller: NSScroller {
    /// AppKit treats scroller subclasses as legacy-only unless they opt in (see NSScroller.h).
    override class var isCompatibleWithOverlayScrollers: Bool {
        self == MonknotScroller.self
    }

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
        guard scrollerStyle == .overlay else {
            super.drawKnob()
            return
        }
        let knobRect = rect(for: .knob)
        guard knobRect.width > 0, knobRect.height > 0 else { return }

        let thickness = isHovered
            ? MonknotScrollbarStyle.hoveredThumbWidth
            : MonknotScrollbarStyle.restingThumbWidth
        let visibleRect = bounds.height >= bounds.width
            ? NSRect(
                x: knobRect.midX - thickness / 2,
                y: knobRect.minY + 1,
                width: thickness,
                height: max(0, knobRect.height - 2)
            )
            : NSRect(
                x: knobRect.minX + 1,
                y: knobRect.midY - thickness / 2,
                width: max(0, knobRect.width - 2),
                height: thickness
            )
        let opacity = isHovered
            ? MonknotScrollbarStyle.hoveredOpacity
            : MonknotScrollbarStyle.restingOpacity
        thumbColor.withAlphaComponent(opacity).setFill()
        let radius = MonknotScrollbarStyle.thumbRadius
        NSBezierPath(roundedRect: visibleRect, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .overlay else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
    }
}

/// Keeps a chrome scroll view on the overlay thumb and shows the thumb while the pointer is over the
/// list, so a mouse user can see there is more and grab it. It fades again like any overlay scroller.
final class MonknotChromeScrollerBehavior: NSResponder {
    private weak var scrollView: NSScrollView?
    private var trackingArea: NSTrackingArea?
    private var styleObserver: NSObjectProtocol?
    private var lastReveal: TimeInterval = 0

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
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        scrollView.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
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
        if let trackingArea, let scrollView {
            scrollView.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
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
        // A tracking area does not retain its owner; it must not outlive this object.
        if let trackingArea, let scrollView {
            MainActor.assumeIsolated {
                scrollView.removeTrackingArea(trackingArea)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        revealThumb()
    }

    override func mouseMoved(with event: NSEvent) {
        revealThumb()
    }

    private func revealThumb() {
        guard let scrollView,
              scrollView.scrollerStyle == .overlay,
              let documentView = scrollView.documentView
        else { return }
        let visibleSize = scrollView.contentView.bounds.size
        guard documentView.frame.height > visibleSize.height + 1
            || documentView.frame.width > visibleSize.width + 1
        else { return }
        // Flashing restarts the overlay fade; once every 0.4s is enough to keep it up while the
        // pointer moves.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReveal > 0.4 else { return }
        lastReveal = now
        scrollView.flashScrollers()
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
