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
        LinearGradient(
            stops: isLeading
                ? [
                    .init(color: theme.contentSurfaceColor, location: 0),
                    .init(color: theme.contentSurfaceColor.opacity(0.92), location: 0.38),
                    .init(color: theme.contentSurfaceColor.opacity(0), location: 1)
                ]
                : [
                    .init(color: theme.contentSurfaceColor.opacity(0), location: 0),
                    .init(color: theme.contentSurfaceColor.opacity(0.92), location: 0.62),
                    .init(color: theme.contentSurfaceColor, location: 1)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: MonknotMetrics.interfaceDensity(28, theme: theme, zoomScale: zoomScale))
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
