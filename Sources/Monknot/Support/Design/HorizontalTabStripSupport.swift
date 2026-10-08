import AppKit
import MonknotCore
import SwiftUI

enum HorizontalTabViewport {
    static let documentTabs = "Monknot.DocumentTabViewport"
    static let terminalTabs = "Monknot.TerminalTabViewport"
}

struct HorizontalTabOverflowState: Equatable {
    let hiddenIDs: Set<String>
    let hasLeadingOverflow: Bool
    let hasTrailingOverflow: Bool

    init(frames: [String: CGRect], viewportWidth: CGFloat, tolerance: CGFloat = 1) {
        self.frames = frames
        guard viewportWidth > 0 else {
            hiddenIDs = Set(frames.keys)
            hasLeadingOverflow = !frames.isEmpty
            hasTrailingOverflow = !frames.isEmpty
            return
        }

        hiddenIDs = Set(frames.compactMap { id, frame in
            let fullyVisible = frame.minX >= -tolerance
                && frame.maxX <= viewportWidth + tolerance
            return fullyVisible ? nil : id
        })
        hasLeadingOverflow = frames.values.contains { $0.minX < -tolerance }
        hasTrailingOverflow = frames.values.contains { $0.maxX > viewportWidth + tolerance }
    }

    func revealEdge(for id: String) -> HorizontalTabRevealEdge? {
        guard let frame = frames[id], hiddenIDs.contains(id) else { return nil }
        return frame.minX < 0 ? .leading : .trailing
    }

    private let frames: [String: CGRect]
}

enum HorizontalTabRevealEdge: Equatable {
    case leading
    case trailing
}

/// One-shot reveal intent for a horizontally scrolling tab lane. Frame
/// preferences also change while the user scrolls, so an unconditional
/// scroll-to-selection from the preference callback would fight manual
/// scrolling. A request is consumed only after its tab has been measured.
struct HorizontalTabRevealRequest: Equatable {
    private(set) var pendingID: String?

    mutating func request(_ id: String?) {
        pendingID = id
    }

    mutating func consume(
        frames: [String: CGRect],
        viewportWidth: CGFloat
    ) -> (id: String, edge: HorizontalTabRevealEdge)? {
        guard let pendingID, frames[pendingID] != nil else { return nil }
        self.pendingID = nil

        let overflow = HorizontalTabOverflowState(
            frames: frames,
            viewportWidth: viewportWidth
        )
        guard let edge = overflow.revealEdge(for: pendingID) else { return nil }
        return (pendingID, edge)
    }
}

struct HorizontalTabEdgeShadows: View {
    let showsLeading: Bool
    let showsTrailing: Bool
    let theme: AppTheme
    let zoomScale: Double
    var surface: Color? = nil

    var body: some View {
        HStack(spacing: 0) {
            edgeShadow(isLeading: true)
                .opacity(showsLeading ? 1 : 0)

            Spacer(minLength: 0)

            edgeShadow(isLeading: false)
                .opacity(showsTrailing ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(MonknotMotion.hoverAnimation, value: showsLeading)
        .animation(MonknotMotion.hoverAnimation, value: showsTrailing)
    }

    private func edgeShadow(isLeading: Bool) -> some View {
        let fill = surface ?? theme.contentSurfaceColor
        return LinearGradient(
            stops: isLeading
                ? [
                    .init(color: fill, location: 0),
                    .init(color: fill.opacity(0.92), location: 0.38),
                    .init(color: fill.opacity(0), location: 1)
                ]
                : [
                    .init(color: fill.opacity(0), location: 0),
                    .init(color: fill.opacity(0.92), location: 0.62),
                    .init(color: fill, location: 1)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: MonknotMetrics.interfaceDensity(24, theme: theme, zoomScale: zoomScale))
    }
}

struct HorizontalTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

struct HorizontalTabFrameReader: View {
    let id: String
    let coordinateSpace: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: HorizontalTabFramePreferenceKey.self, value: [
                id: proxy.frame(in: .named(coordinateSpace))
            ])
        }
    }
}

/// Lets a mouse wheel scroll a horizontal tab strip (design.md §10.3). A wheel has no horizontal axis,
/// so a vertical notch over the strip moves it sideways, as in Safari and Xcode. Trackpad gestures
/// keep their own axes, so a vertical swipe over the strip still does nothing, and ⇧-wheel is already
/// horizontal. Place it in the strip's scrolling content, for example as a `.background`.
struct HorizontalTabWheelScrolling: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {}

    /// The same notch on the horizontal axis, or `nil` when the event is not a plain vertical
    /// mouse-wheel notch and should pass through untouched.
    static func horizontalEvent(for event: NSEvent) -> NSEvent? {
        guard event.type == .scrollWheel,
              !event.hasPreciseScrollingDeltas,
              event.scrollingDeltaX == 0,
              event.scrollingDeltaY != 0,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let cgEvent = event.cgEvent?.copy()
        else { return nil }

        let integerAxes: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (vertical, horizontal) in integerAxes {
            cgEvent.setIntegerValueField(horizontal, value: cgEvent.getIntegerValueField(vertical))
            cgEvent.setIntegerValueField(vertical, value: 0)
        }
        cgEvent.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis2,
            value: cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        )
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cgEvent)
    }

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      self.scrollStrip(for: event, at: event.locationInWindow)
                else { return event }
                return nil
            }
        }

        deinit {
            removeMonitor()
        }

        /// Scrolls the enclosing strip for a mouse-wheel notch at `locationInWindow`, when that point is
        /// over the strip and the strip overflows; returns whether it did.
        func scrollStrip(for event: NSEvent, at locationInWindow: NSPoint) -> Bool {
            guard let scrollView = enclosingScrollView,
                  let documentView = scrollView.documentView,
                  documentView.frame.width > scrollView.contentView.bounds.width + 1,
                  scrollView.bounds.contains(scrollView.convert(locationInWindow, from: nil)),
                  // Nothing (an overlay's scrim, a popover) may cover the strip at that point.
                  isUncovered(locationInWindow, in: scrollView),
                  let horizontalEvent = HorizontalTabWheelScrolling.horizontalEvent(for: event)
            else { return false }
            scrollView.scrollWheel(with: horizontalEvent)
            return true
        }

        /// The window's frame view has no superview, so it hit-tests in window coordinates; it also
        /// covers the titlebar, where the strips live.
        private func isUncovered(_ locationInWindow: NSPoint, in scrollView: NSScrollView) -> Bool {
            guard let frameView = window?.contentView?.superview,
                  let hitView = frameView.hitTest(locationInWindow)
            else { return true }
            return hitView.isDescendant(of: scrollView)
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
