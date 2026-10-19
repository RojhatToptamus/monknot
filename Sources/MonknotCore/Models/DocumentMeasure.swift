import Foundation

/// The comfortable line length of the document column, shared by Source (points) and Preview
/// (`em` of its prose). At the default content width it is 640 pt of 13 pt text: about 80 characters
/// of the code face, 90 of the prose face. The content-width setting scales it, so on a wide window
/// the setting chooses the line length; on a narrow one the setting's share of the pane wins. At
/// 100 % there is no measure: the column fills the pane.
public enum DocumentMeasure {
    public static let basePoints: Double = 640
    public static let referenceFontSize: Double = 13
    public static let defaultContentWidthPercent: Double = 88
    /// The Content Width setting's range.
    public static let contentWidthPercentRange: ClosedRange<Double> = 55...100
    /// Preview sets prose at the code size × 14⁄13.
    public static let previewProseScale: Double = 14 / 13
    /// The space above the first line, in multiples of the code size (zoom included), the same in
    /// Source and Preview, so switching view mode never moves the first line and a larger text size
    /// keeps the margin's proportion (design.md §10.11).
    public static let verticalMarginEm: Double = 2.5
    /// The least space between the pane's edge and the text at 1× zoom, in Source and Preview alike, so
    /// the text starts at the same x in both at every width (design.md §10.11). It holds Preview's block
    /// handles, which sit left of the text: 22 + 1 + 18 wide and 6 clear of it (editor.css `.mk-handle`).
    public static let minimumTextEdgeBase: Double = 48

    public static func clampedContentWidthPercent(_ value: Double) -> Double {
        min(contentWidthPercentRange.upperBound, max(contentWidthPercentRange.lowerBound, value))
    }

    /// `verticalMarginEm` of `fontSize` (the code size, zoom included), in points. Snapped to a
    /// millionth before rounding, so a code size Preview derives back from its prose size rounds as
    /// Source's does.
    public static func verticalMargin(fontSize: Double) -> Double {
        ((max(1, fontSize) * verticalMarginEm * 1e6).rounded() / 1e6).rounded()
    }

    /// `minimumTextEdgeBase` at the document's zoom, in points.
    public static func minimumTextEdge(zoomScale: Double) -> Double {
        (minimumTextEdgeBase * zoomScale).rounded()
    }

    public static func points(contentWidthPercent: Double, fontSize: Double = referenceFontSize) -> Double {
        guard contentWidthPercent < 100 else { return .infinity }
        return basePoints * (max(1, fontSize) / referenceFontSize) * (contentWidthPercent / defaultContentWidthPercent)
    }

    /// The same width as `points` at the reference size, in `em` of Preview's prose; infinite at 100 %.
    public static func previewEm(contentWidthPercent: Double) -> Double {
        points(contentWidthPercent: contentWidthPercent) / (referenceFontSize * previewProseScale)
    }

    /// `previewEm` as a CSS length; at 100 % a width no pane reaches.
    public static func previewCSSLength(contentWidthPercent: Double) -> String {
        let em = previewEm(contentWidthPercent: contentWidthPercent)
        guard em.isFinite else { return "100000px" }
        return String(format: "%.2fem", locale: Locale(identifier: "en_US_POSIX"), em)
    }
}
