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
    /// Preview sets prose at the code size × 14⁄13.
    public static let previewProseScale: Double = 14 / 13

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
