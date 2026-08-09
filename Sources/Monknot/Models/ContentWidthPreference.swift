import Foundation

enum ContentWidthPreference {
    static let key = "Monknot.contentWidthPercent"
    static let legacyPreviewWidthKey = "Monknot.previewWidthPercent"
    static let defaultValue = 88.0
    static let allowedRange = 55.0...100.0
    private static let editorMinimumHorizontalInsetBase: CGFloat = 16
    private static let editorVerticalInsetBase: CGFloat = 18
    private static let editorLineFragmentPaddingBase: CGFloat = 5
    private static let editorPlaceholderLeadingGapBase: CGFloat = 12
    private static let editorPlaceholderTopInsetBase: CGFloat = 26
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

    static func editorHorizontalInset(
        viewportWidth: CGFloat,
        contentWidthPercent: Double,
        zoomScale: Double
    ) -> CGFloat {
        let viewportWidth = max(0, viewportWidth)
        let widthFraction = clamped(contentWidthPercent) / 100
        return max(
            scaledEditorMetric(editorMinimumHorizontalInsetBase, zoomScale: zoomScale),
            viewportWidth * CGFloat(1 - widthFraction) / 2
        )
    }

    static func editorVerticalInset(zoomScale: Double) -> CGFloat {
        scaledEditorMetric(editorVerticalInsetBase, zoomScale: zoomScale)
    }

    static func editorLineFragmentPadding(zoomScale: Double) -> CGFloat {
        scaledEditorMetric(editorLineFragmentPaddingBase, zoomScale: zoomScale)
    }

    static func editorPlaceholderLeadingInset(
        viewportWidth: CGFloat,
        contentWidthPercent: Double,
        zoomScale: Double
    ) -> CGFloat {
        editorHorizontalInset(
            viewportWidth: viewportWidth,
            contentWidthPercent: contentWidthPercent,
            zoomScale: zoomScale
        ) + scaledEditorMetric(editorPlaceholderLeadingGapBase, zoomScale: zoomScale)
    }

    static func editorPlaceholderTopInset(zoomScale: Double) -> CGFloat {
        scaledEditorMetric(editorPlaceholderTopInsetBase, zoomScale: zoomScale)
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
