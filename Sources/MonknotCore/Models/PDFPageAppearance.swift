import Foundation

/// How the PDF viewer shows pages: as the file has them, dimmed, or dark with light ink. Only the
/// screen changes; the file, saving and export never see it (design.md §10.7a).
public enum PDFPageAppearance: String, CaseIterable, Sendable {
    case original
    case dim
    case dark

    public static let preferenceKey = "Monknot.pdfPageAppearance"

    /// Dim shows every colour at this share of its brightness, so white paper is light grey and a
    /// picture keeps its colours.
    static let dimBrightness = 0.8

    public var title: String {
        switch self {
        case .original: return "Original"
        case .dim: return "Dim"
        case .dark: return "Dark"
        }
    }

    /// The colour transform pages are shown through in `theme`, nil for the original pages. Dark's
    /// paper is the theme's darker base colour and its ink the lighter one, so a page reads like the
    /// theme's own text.
    public func colorTransform(in theme: AppTheme) -> PDFPageColorTransform? {
        switch self {
        case .original:
            return nil
        case .dim:
            return PDFPageColorTransform(brightness: Self.dimBrightness)
        case .dark:
            guard let background = RGBHex(theme.background), let foreground = RGBHex(theme.foreground) else {
                return nil
            }
            return theme.isDark
                ? PDFPageColorTransform(paper: background, ink: foreground)
                : PDFPageColorTransform(paper: foreground, ink: background)
        }
    }
}

/// An affine transform of sRGB colour components: `matrix · rgb + bias`, rows red, green, blue.
public struct PDFPageColorTransform: Equatable, Sendable {
    public let matrix: [[Double]]
    public let bias: [Double]

    init(brightness: Double) {
        matrix = (0..<3).map { row in (0..<3).map { column in row == column ? brightness : 0 } }
        bias = [0, 0, 0]
    }

    /// White becomes `paper` and black `ink`. Only a colour's grey level flips, from one end of that
    /// range to the other; its difference from grey stays, and with it its hue, so a yellow
    /// highlight stays yellow, only darker.
    init(paper: RGBHex, ink: RGBHex) {
        let ink = [ink.red, ink.green, ink.blue]
        let span = zip(ink, [paper.red, paper.green, paper.blue]).map { $0 - $1 }
        matrix = (0..<3).map { row in
            (0..<3).map { column in span[row] * ((row == column ? 1 : 0) - 2.0 / 3) }
        }
        bias = ink
    }
}
