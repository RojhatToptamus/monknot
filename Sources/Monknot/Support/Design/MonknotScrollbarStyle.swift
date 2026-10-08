import AppKit
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

    /// Documents (editor, PDF): the scroller style follows System Settings › Appearance › Show scroll
    /// bars, which AppKit applies.
    static func apply(to scrollView: NSScrollView) {
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is MonknotScroller) {
            scrollView.verticalScroller = MonknotScroller(frame: .zero)
        }
    }

    /// Chrome lists (sidebar, search results, palettes, panels, Settings) always use the slim overlay
    /// thumb. With a mouse attached, AppKit would otherwise give each one a 17pt bar with an opaque
    /// track, the loudest thing in a 248pt sidebar. Keep the style with `MonknotChromeScrollerBehavior`,
    /// because AppKit resets it whenever the system setting or the attached mouse changes.
    static func applyChrome(to scrollView: NSScrollView) {
        apply(to: scrollView)
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
            // Give the list back the width the legacy bar took.
            scrollView.tile()
        }
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

/// The thin thumb used while overlay scroll bars are active. Documents with "Show scroll bars: Always"
/// draw AppKit's own legacy knob and track, because the user asked for the standard scroll bar there.
final class MonknotScroller: NSScroller {
    /// Without this AppKit treats every scroller subclass as legacy-only (see NSScroller.h), so
    /// documents never got overlay scroll bars on any Mac.
    override class var isCompatibleWithOverlayScrollers: Bool {
        self == MonknotScroller.self
    }

    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func drawKnob() {
        guard scrollerStyle == .overlay else {
            super.drawKnob()
            return
        }
        let knobRect = rect(for: .knob)
        guard knobRect.width > 0, knobRect.height > 0 else { return }

        let width = isHovered
            ? MonknotScrollbarStyle.hoveredThumbWidth
            : MonknotScrollbarStyle.restingThumbWidth
        let visibleRect = NSRect(
            x: knobRect.midX - width / 2,
            y: knobRect.minY + 1,
            width: width,
            height: max(0, knobRect.height - 2)
        )
        let opacity = isHovered
            ? MonknotScrollbarStyle.hoveredOpacity
            : MonknotScrollbarStyle.restingOpacity
        NSColor.labelColor.withAlphaComponent(opacity).setFill()
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

    func attach(to scrollView: NSScrollView) {
        if self.scrollView !== scrollView {
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
                    guard let scrollView = self?.scrollView else { return }
                    MonknotScrollbarStyle.applyChrome(to: scrollView)
                }
            }
        }
        MonknotScrollbarStyle.applyChrome(to: scrollView)
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
              let documentView = scrollView.documentView,
              documentView.frame.height > scrollView.contentView.bounds.height + 1
        else { return }
        // Flashing restarts the overlay fade; once every 0.4s is enough to keep it up while the
        // pointer moves.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReveal > 0.4 else { return }
        lastReveal = now
        scrollView.flashScrollers()
    }
}

struct MonknotScrollView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content.background(MonknotScrollbarConfigurator())
        }
    }
}

private struct MonknotScrollbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.applyStyle()
    }

    final class ConfigurationView: NSView {
        private let behavior = MonknotChromeScrollerBehavior()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                behavior.detach()
                return
            }
            applyStyle()
        }

        func applyStyle() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                self.behavior.attach(to: scrollView)
            }
        }
    }
}
