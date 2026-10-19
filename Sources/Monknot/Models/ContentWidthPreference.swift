import Foundation
import MonknotCore

enum ContentWidthPreference {
    static let key = "Monknot.contentWidthPercent"
    static let legacyPreviewWidthKey = "Monknot.previewWidthPercent"
    static let defaultValue = 88.0
    static let allowedRange = 55.0...100.0
    private static let editorMinimumHorizontalInsetBase: CGFloat = 16
    private static let editorLineFragmentPaddingBase: CGFloat = 5
    private static let editorPlaceholderLeadingGapBase: CGFloat = 12
    /// From the text's top inset to the placeholder's top, as the first line sets its glyphs.
    private static let editorPlaceholderLineOffsetBase: CGFloat = 8
    private static let editorPlaceholderMinimumFontSizeBase: CGFloat = 13

    static func initialValue(in defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: key) != nil {
            let currentValue = normalizeStoredValue(forKey: key, in: defaults)
            if defaults.object(forKey: legacyPreviewWidthKey) != nil {
                defaults.removeObject(forKey: legacyPreviewWidthKey)
            }
            return currentValue
        }

        guard defaults.object(forKey: legacyPreviewWidthKey) != nil else {
            return defaultValue
        }

        let migratedValue = clamped(defaults.double(forKey: legacyPreviewWidthKey))
        defaults.set(migratedValue, forKey: key)
        defaults.removeObject(forKey: legacyPreviewWidthKey)
        return migratedValue
    }

    static func clamped(_ value: Double) -> Double {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, value))
    }

    static let measureReferenceFontSize = CGFloat(DocumentMeasure.referenceFontSize)

    /// The text column for a pane `viewportWidth` wide: the setting's share of the pane, up to the
    /// comfortable line length (`DocumentMeasure`). Source and Preview both centre this width, so
    /// their text starts at the same edge.
    static func textColumnWidth(
        viewportWidth: CGFloat,
        contentWidthPercent: Double,
        fontSize: CGFloat = measureReferenceFontSize
    ) -> CGFloat {
        let percent = clamped(contentWidthPercent)
        let share = max(0, viewportWidth) * CGFloat(percent / 100)
        return min(share, CGFloat(DocumentMeasure.points(contentWidthPercent: percent, fontSize: Double(fontSize))))
    }

    static func editorHorizontalInset(
        viewportWidth: CGFloat,
        contentWidthPercent: Double,
        zoomScale: Double,
        fontSize: CGFloat? = nil
    ) -> CGFloat {
        let viewportWidth = max(0, viewportWidth)
        let resolvedFontSize = fontSize ?? measureReferenceFontSize * CGFloat(WorkspaceZoomPolicy.documentScale(zoomScale))
        let column = textColumnWidth(
            viewportWidth: viewportWidth,
            contentWidthPercent: contentWidthPercent,
            fontSize: resolvedFontSize
        )
        // The line fragment padding sits inside the inset, so the first glyph lands where Preview's
        // does: half the leftover width from the pane's edge.
        return max(
            scaledEditorMetric(editorMinimumHorizontalInsetBase, zoomScale: zoomScale),
            (viewportWidth - column) / 2 - editorLineFragmentPadding(zoomScale: zoomScale)
        )
    }

    /// The space above the first line (and below the last), the same as Preview's top margin.
    static func editorVerticalInset(fontSize: CGFloat) -> CGFloat {
        CGFloat(DocumentMeasure.verticalMargin(fontSize: Double(fontSize)))
    }

    static func editorLineFragmentPadding(zoomScale: Double) -> CGFloat {
        scaledEditorMetric(editorLineFragmentPaddingBase, zoomScale: zoomScale)
    }

    static func editorPlaceholderLeadingInset(
        viewportWidth: CGFloat,
        contentWidthPercent: Double,
        zoomScale: Double,
        fontSize: CGFloat? = nil
    ) -> CGFloat {
        editorHorizontalInset(
            viewportWidth: viewportWidth,
            contentWidthPercent: contentWidthPercent,
            zoomScale: zoomScale,
            fontSize: fontSize
        ) + scaledEditorMetric(editorPlaceholderLeadingGapBase, zoomScale: zoomScale)
    }

    /// The empty-document placeholder sits on the first line.
    static func editorPlaceholderTopInset(fontSize: CGFloat, zoomScale: Double) -> CGFloat {
        editorVerticalInset(fontSize: fontSize) + scaledEditorMetric(editorPlaceholderLineOffsetBase, zoomScale: zoomScale)
    }

    static func editorPlaceholderMinimumFontSize(zoomScale: Double) -> CGFloat {
        let scale = CGFloat(WorkspaceZoomPolicy.documentScale(zoomScale))
        return (editorPlaceholderMinimumFontSizeBase * scale * 2).rounded() / 2
    }

    private static func scaledEditorMetric(_ base: CGFloat, zoomScale: Double) -> CGFloat {
        (base * CGFloat(WorkspaceZoomPolicy.documentScale(zoomScale))).rounded()
    }

    private static func normalizeStoredValue(
        forKey key: String,
        in defaults: UserDefaults
    ) -> Double {
        let storedValue = defaults.double(forKey: key)
        let normalizedValue = clamped(storedValue)
        if normalizedValue != storedValue {
            defaults.set(normalizedValue, forKey: key)
        }
        return normalizedValue
    }
}
