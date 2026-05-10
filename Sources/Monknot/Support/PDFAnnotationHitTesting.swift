import CoreGraphics
import Foundation
import PDFKit

enum PDFAnnotationHitTesting {
    static func annotationForErasing(on page: PDFPage, at point: CGPoint, tolerance: CGFloat) -> PDFAnnotation? {
        page.annotations.reversed().first { annotation in
            guard isErasable(annotation) else { return false }
            return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func isErasable(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        let subtype = PDFAnnotationSubtype(rawValue: type)
        if erasableSubtypes.contains(subtype) {
            return true
        }

        let normalizedType = type
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return erasableTypeNames.contains(normalizedType)
    }

    private static let erasableSubtypes: Set<PDFAnnotationSubtype> = [
        .highlight,
        .underline,
        .strikeOut,
        .ink,
        .freeText,
        .text,
        .square,
        .circle,
        .line,
        .stamp,
        .popup
    ]

    private static let erasableTypeNames: Set<String> = [
        "highlight",
        "underline",
        "strikeout",
        "ink",
        "freetext",
        "text",
        "square",
        "circle",
        "line",
        "stamp",
        "popup"
    ]
}
