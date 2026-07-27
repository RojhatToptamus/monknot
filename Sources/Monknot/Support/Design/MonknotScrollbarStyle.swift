import AppKit
import SwiftUI
import WebKit

enum MonknotScrollbarStyle {
    static let trackWidth: CGFloat = 11
    static let restingThumbWidth: CGFloat = 5
    static let hoveredThumbWidth: CGFloat = 6
    static let restingOpacity: CGFloat = 0.18
    static let hoveredOpacity: CGFloat = 0.55

    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
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

    static func webUserScript() -> WKUserScript {
        let css = webCSS()
        return WKUserScript(
            source: """
            (() => {
              const style = document.createElement("style");
              style.textContent = `\(css)`;
              (document.head || document.documentElement).appendChild(style);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    private static func cssPixels(_ value: CGFloat) -> String {
        value.rounded() == value ? "\(Int(value))px" : "\(value)px"
    }
}

final class MonknotScroller: NSScroller {
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

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
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
