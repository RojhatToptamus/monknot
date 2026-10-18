import AppKit
import QuartzCore
import SwiftUI

/// A view whose pixels a snapshot cannot hold (a video layer draws outside the view tree). A
/// document showing one keeps the plain hold while a side pane opens or closes, without a cover.
protocol WorkspaceTransitionCoverExcluded: NSView {}

/// Marks chrome drawn against the document's trailing edge (the outline rail, the word count), so a
/// pane transition's cover keeps it on the card's trailing edge however close the text comes.
struct WorkspaceTrailingChromeMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MarkerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func isAccessibilityElement() -> Bool { false }
    }
}

/// How a snapshot of the document is cut while a side pane opens or closes (design.md §10.0), in
/// pixels of the snapshot. The centre band holds the text column and glides with the card's middle,
/// where a live layout keeps a centred column; the trailing band holds the chrome against the
/// trailing edge (an outline rail, a word count, a scroll bar) and stays on that edge. Between and
/// beside them is plain background.
///
/// A document's column is centred and its left margin is plain background, so the column starts at
/// the first ink from the left. The trailing band starts where marked chrome
/// (`WorkspaceTrailingChromeMarker`) starts, or else at the first all-background pixel column past
/// the mirror of the column's start plus `padding`; the centre band ends `padding` past the last ink
/// before it, so a narrowing card never slides the column's empty margin over the chrome. Every cut
/// is an all-background column, so none passes through ink: at worst unmarked chrome glides with the
/// column.
struct WorkspaceTransitionCoverBands: Equatable {
    static let padding: CGFloat = 8

    /// The centre band is `centreStart..<centreEnd`, the trailing band `trailingStart..<width`.
    var centreStart: Int
    var centreEnd: Int
    var trailingStart: Int

    /// The whole snapshot glides as one band.
    static func whole(width: Int) -> WorkspaceTransitionCoverBands {
        WorkspaceTransitionCoverBands(centreStart: 0, centreEnd: width, trailingStart: width)
    }

    /// Reads 32-bit pixels, 8 bits a channel in any order, and compares each channel with the
    /// background pixel within `tolerance`, so anti-aliasing at a glyph's edge counts as ink. Rows
    /// are read `rowStep` apart (one point on a Retina snapshot): no stroke is thinner.
    static func detect(
        pixels: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        background: UInt32,
        paddingPixels: Int,
        trailingChromeStart: Int? = nil,
        rowStep: Int = 1,
        tolerance: UInt32 = 2
    ) -> WorkspaceTransitionCoverBands {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            return .whole(width: max(0, width))
        }
        let step = max(1, rowStep)

        func matches(_ pixel: UInt32) -> Bool {
            if pixel == background {
                return true
            }
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                let value = (pixel >> shift) & 0xFF
                let reference = (background >> shift) & 0xFF
                if (value > reference ? value - reference : reference - value) > tolerance {
                    return false
                }
            }
            return true
        }

        func isBackground(column x: Int) -> Bool {
            var offset = x * 4
            var y = 0
            while y < height {
                if !matches(pixels.load(fromByteOffset: offset, as: UInt32.self)) {
                    return false
                }
                offset += bytesPerRow * step
                y += step
            }
            return true
        }

        guard let firstInk = (0..<width).first(where: { !isBackground(column: $0) }) else {
            return .whole(width: width)
        }
        let centreStart = max(0, firstInk - paddingPixels)

        var trailingStart = width
        // Marked chrome starts the trailing band at the background column nearest its frame's edge:
        // a frame can begin with empty space the text's ragged end reaches into (the rail's markers
        // hug its trailing side), so the search runs both ways, never past `padding` left or twice
        // that right.
        if let chrome = trailingChromeStart, chrome > firstInk, chrome < width,
           let cut = (max(firstInk + 1, chrome - paddingPixels)...min(width - 1, chrome + 2 * paddingPixels))
               .filter({ isBackground(column: $0) })
               .min(by: { abs($0 - chrome) < abs($1 - chrome) }) {
            trailingStart = cut
        } else {
            let start = min(width, max(firstInk + 1, width - firstInk + paddingPixels))
            trailingStart = (start..<width).first(where: { isBackground(column: $0) }) ?? width
        }

        let lastInk = stride(from: trailingStart - 1, through: firstInk, by: -1)
            .first(where: { !isBackground(column: $0) }) ?? firstInk
        return WorkspaceTransitionCoverBands(
            centreStart: centreStart,
            centreEnd: min(trailingStart, lastInk + 1 + paddingPixels),
            trailingStart: trailingStart
        )
    }
}

/// Lies over the document while a side pane opens or closes: a snapshot of the document as it was,
/// cut into `WorkspaceTransitionCoverBands` and placed for the card's width on every frame, so the
/// document underneath can take its final width at once without its first, stale frames showing.
final class WorkspaceTransitionCoverView: NSView {
    private let snapshotWidth: CGFloat
    private let centreStart: CGFloat
    private let centreWidth: CGFloat
    private let trailingWidth: CGFloat
    private let backgroundFill = CALayer()
    private let centreBand = CALayer()
    private let trailingBand = CALayer()

    /// Snapshots `view` as it is on screen, or returns nil when it cannot (no window, no size, a
    /// pixel format the bands cannot read, or a view that draws outside the tree).
    init?(snapshotting view: NSView) {
        let bounds = view.bounds
        guard view.window != nil, bounds.width >= 1, bounds.height >= 1,
              !Self.containsExcludedView(view),
              let representation = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: representation)
        guard let image = representation.cgImage else { return nil }

        let scale = CGFloat(representation.pixelsWide) / bounds.width
        let pixelWidth = representation.pixelsWide
        let pixelHeight = representation.pixelsHigh
        // The left margin halfway down is the document's own background.
        let sampleRow = pixelHeight / 2
        var bands = WorkspaceTransitionCoverBands.whole(width: pixelWidth)
        if representation.bitsPerSample == 8, representation.bitsPerPixel == 32, !representation.isPlanar,
           let data = representation.bitmapData {
            let pixels = UnsafeRawPointer(data)
            let chromeStart = Self.trailingChromeStart(in: view).map { Int(($0 * scale).rounded(.down)) }
            bands = WorkspaceTransitionCoverBands.detect(
                pixels: pixels,
                width: pixelWidth,
                height: pixelHeight,
                bytesPerRow: representation.bytesPerRow,
                background: pixels.load(fromByteOffset: sampleRow * representation.bytesPerRow, as: UInt32.self),
                paddingPixels: Int((WorkspaceTransitionCoverBands.padding * scale).rounded()),
                trailingChromeStart: chromeStart,
                rowStep: max(1, Int(scale.rounded()))
            )
        }

        snapshotWidth = bounds.width
        centreStart = CGFloat(bands.centreStart) / scale
        centreWidth = CGFloat(bands.centreEnd - bands.centreStart) / scale
        trailingWidth = CGFloat(pixelWidth - bands.trailingStart) / scale
        super.init(frame: bounds)
        wantsLayer = true
        let total = CGFloat(pixelWidth)
        // Gaps that open between the bands show that background pixel, stretched: the snapshot's
        // own pixel in its own color space, so no seam shows where a band ends.
        backgroundFill.contents = image
        backgroundFill.contentsRect = CGRect(x: 0, y: CGFloat(sampleRow) / CGFloat(pixelHeight), width: 1 / total, height: 1 / CGFloat(pixelHeight))
        backgroundFill.magnificationFilter = .nearest
        backgroundFill.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(backgroundFill)
        // The trailing band lies under the centre band, which only reaches it where a narrowing
        // card's live layout would bring the text against the chrome too.
        for (band, start, end) in [
            (trailingBand, bands.trailingStart, pixelWidth),
            (centreBand, bands.centreStart, bands.centreEnd),
        ] {
            band.contents = image
            band.contentsScale = scale
            band.contentsGravity = .resize
            band.contentsRect = CGRect(x: CGFloat(start) / total, y: 0, width: CGFloat(end - start) / total, height: 1)
            band.isHidden = end <= start
            // Placed on every frame of the transition; implicit animations would trail the card.
            band.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(band)
        }
        setAccessibilityElement(false)
        layoutBands()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutBands()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutBands()
    }

    /// The trailing band keeps to the trailing edge; the centre band keeps the snapshot's middle on
    /// the card's middle.
    func layoutBands() {
        let width = bounds.width
        let height = bounds.height
        let centreX = backingAlignedRect(
            NSRect(x: (width - snapshotWidth) / 2 + centreStart, y: 0, width: centreWidth, height: height),
            options: .alignAllEdgesNearest
        ).minX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundFill.frame = bounds
        centreBand.frame = CGRect(x: centreX, y: 0, width: centreWidth, height: height)
        trailingBand.frame = CGRect(x: width - trailingWidth, y: 0, width: trailingWidth, height: height)
        CATransaction.commit()
    }

    /// Where the marked trailing chrome in `view` starts, in its coordinates from the left.
    private static func trailingChromeStart(in view: NSView) -> CGFloat? {
        var start: CGFloat?
        func visit(_ candidate: NSView) {
            if candidate is WorkspaceTrailingChromeMarker.MarkerView, !candidate.isHiddenOrHasHiddenAncestor,
               candidate.bounds.width > 0 {
                let minX = candidate.convert(candidate.bounds, to: view).minX
                start = min(start ?? minX, minX)
            }
            candidate.subviews.forEach(visit)
        }
        visit(view)
        return start
    }

    private static func containsExcludedView(_ view: NSView) -> Bool {
        if view is WorkspaceTransitionCoverExcluded {
            return true
        }
        return view.subviews.contains(where: containsExcludedView)
    }
}
