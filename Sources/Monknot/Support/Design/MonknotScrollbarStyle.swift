import AppKit
import SwiftUI

enum MonknotScrollbarStyle {
    static let trackWidth: CGFloat = 12
    static let restingThumbWidth: CGFloat = 6
    static let hoveredThumbWidth: CGFloat = 8
    // At 18 % the thumb measured 1.8:1 against the canvas; half strength clears the 3:1 minimum for
    // non-text indicators in both appearances.
    static let restingOpacity: CGFloat = 0.5
    static let hoveredOpacity: CGFloat = 0.7

    /// The scroller style follows System Settings › Appearance › Show scroll bars; AppKit applies it.
    static func apply(to scrollView: NSScrollView) {
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is MonknotScroller) {
            scrollView.verticalScroller = MonknotScroller(frame: .zero)
        }
    }

    static func webCSS(
        selector: String = "*",
        restingColor: String = "color-mix(in srgb, CanvasText 18%, transparent)",
        hoveredColor: String = "color-mix(in srgb, CanvasText 55%, transparent)"
    ) -> String {
        let restingInset = (trackWidth - restingThumbWidth) / 2
        let hoveredInset = (trackWidth - hoveredThumbWidth) / 2

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
          border-radius: 999px;
        }
        \(selector)::-webkit-scrollbar-thumb:hover {
          background: \(hoveredColor);
          background-clip: content-box;
          border: \(cssPixels(hoveredInset)) solid transparent;
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

/// The thin rounded thumb used while overlay scroll bars are active. With "Show scroll bars: Always"
/// the user asked for the standard scroll bar, so legacy style draws AppKit's own knob and track.
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
        NSBezierPath(roundedRect: visibleRect, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .overlay else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        func applyStyle() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                MonknotScrollbarStyle.apply(to: scrollView)
            }
        }
    }
}
