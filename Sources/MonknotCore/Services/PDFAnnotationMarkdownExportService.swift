import Foundation
import PDFKit

public struct PDFAnnotationMarkdownExportItem: Sendable {
    public let data: Data
    public let documentName: String
    public let relativePath: String

    public init(data: Data, documentName: String, relativePath: String) {
        self.data = data
        self.documentName = documentName
        self.relativePath = relativePath
    }
}

public struct PDFAnnotationMarkdownExportService {
    public init() {}

    public func exportMarkdown(from items: [PDFAnnotationMarkdownExportItem], title: String) throws -> String {
        var lines: [String] = [
            "# \(Self.markdownEscaped(title))",
            "",
            "- PDFs: \(items.count)",
            ""
        ]

        guard !items.isEmpty else {
            lines.append("No PDF documents found.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for (index, item) in items.enumerated() {
            guard let document = PDFDocument(data: item.data) else {
                throw PDFAnnotationMarkdownExportError.unreadablePDF
            }

            if index > 0 {
                lines.append("")
            }
            lines.append("## \(Self.markdownEscaped(item.documentName))")
            lines.append("")
            lines.append(contentsOf: documentLines(from: document, relativePath: item.relativePath, pageHeadingLevel: 3))
        }

        return lines.joined(separator: "\n")
    }

    public func exportMarkdown(from data: Data, documentName: String, relativePath: String) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw PDFAnnotationMarkdownExportError.unreadablePDF
        }

        return exportMarkdown(from: document, documentName: documentName, relativePath: relativePath)
    }

    public func exportMarkdown(from document: PDFDocument, documentName: String, relativePath: String) -> String {
        var lines: [String] = [
            "# \(Self.markdownEscaped(documentName)) Annotations",
            "",
        ]
        lines.append(contentsOf: documentLines(from: document, relativePath: relativePath, pageHeadingLevel: 2))
        return lines.joined(separator: "\n")
    }

    private func documentLines(from document: PDFDocument, relativePath: String, pageHeadingLevel: Int) -> [String] {
        var lines: [String] = [
            "- Source: `\(relativePath)`",
            "- Pages: \(document.pageCount)",
            ""
        ]

        let pageExports = annotationExports(from: document)
        guard !pageExports.isEmpty else {
            lines.append("No annotations found.")
            lines.append("")
            return lines
        }

        let pageHeadingPrefix = String(repeating: "#", count: max(1, pageHeadingLevel))
        var currentPage: Int?
        for export in pageExports {
            if currentPage != export.pageNumber {
                if currentPage != nil {
                    lines.append("")
                }
                currentPage = export.pageNumber
                lines.append("\(pageHeadingPrefix) Page \(export.pageNumber)")
                lines.append("")
            }

            lines.append("- \(export.kind)\(export.metadataSuffix)")
            if let text = export.text, !text.isEmpty {
                for quoteLine in text.components(separatedBy: .newlines) {
                    let trimmedLine = quoteLine.trimmingCharacters(in: .whitespaces)
                    lines.append("> \(trimmedLine)")
                }
            } else {
                lines.append("> No annotation text available.")
            }
        }

        lines.append("")
        return lines
    }

    private func annotationExports(from document: PDFDocument) -> [AnnotationExport] {
        var exports: [AnnotationExport] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let sortedAnnotations = page.annotations.sorted { lhs, rhs in
                if lhs.bounds.maxY == rhs.bounds.maxY {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.bounds.maxY > rhs.bounds.maxY
            }

            for annotation in sortedAnnotations {
                exports.append(
                    AnnotationExport(
                        pageNumber: pageIndex + 1,
                        kind: Self.kindLabel(for: annotation),
                        text: Self.annotationText(annotation, page: page),
                        colorHex: Self.colorHex(for: annotation),
                        userName: Self.trimmed(annotation.userName),
                        modificationDate: annotation.modificationDate,
                        bounds: annotation.bounds
                    )
                )
            }
        }

        return exports
    }

    private struct AnnotationExport {
        let pageNumber: Int
        let kind: String
        let text: String?
        let colorHex: String?
        let userName: String?
        let modificationDate: Date?
        let bounds: CGRect

        var metadataSuffix: String {
            var parts: [String] = []
            if let colorHex {
                parts.append("color \(colorHex)")
            }
            if let userName {
                parts.append("by \(userName)")
            }
            if let modificationDate {
                parts.append("modified \(Self.dateFormatter.string(from: modificationDate))")
            }
            parts.append("bounds \(Self.boundsFormatter(bounds))")
            return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        }

        private static let dateFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static func boundsFormatter(_ bounds: CGRect) -> String {
            let values = [bounds.minX, bounds.minY, bounds.width, bounds.height]
                .map { String(format: "%.1f", Double($0)) }
            return values.joined(separator: ",")
        }
    }

    private static func annotationText(_ annotation: PDFAnnotation, page: PDFPage) -> String? {
        if let contents = trimmed(annotation.contents) {
            return contents
        }

        for rect in textCandidateRects(for: annotation) {
            if let text = trimmed(page.selection(for: rect)?.string) {
                return text
            }
        }

        return lineIntersectionText(for: annotation, page: page)
    }

    private static func textCandidateRects(for annotation: PDFAnnotation) -> [CGRect] {
        var rects: [CGRect] = []

        for rect in quadrilateralRects(for: annotation) {
            rects.append(rect.insetBy(dx: -2, dy: -2))
        }

        rects.append(annotation.bounds)
        rects.append(annotation.bounds.insetBy(dx: -4, dy: -4))
        rects.append(annotation.bounds.insetBy(dx: -10, dy: -6))

        return rects.filter { !$0.isNull && !$0.isEmpty }
    }

    private static func quadrilateralRects(for annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints, points.count >= 4 else {
            return []
        }

        var rects: [CGRect] = []
        let origin = annotation.bounds.origin
        var index = 0
        while index + 3 < points.count {
            let quadPoints = points[index..<(index + 4)].map { value -> CGPoint in
                let point = value.pointValue
                return CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            }

            let minX = quadPoints.map(\.x).min() ?? 0
            let maxX = quadPoints.map(\.x).max() ?? 0
            let minY = quadPoints.map(\.y).min() ?? 0
            let maxY = quadPoints.map(\.y).max() ?? 0
            rects.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            index += 4
        }

        return rects
    }

    private static func lineIntersectionText(for annotation: PDFAnnotation, page: PDFPage) -> String? {
        let pageBounds = page.bounds(for: .cropBox)
        guard let fullPageSelection = page.selection(for: pageBounds) else {
            return nil
        }

        let candidateBounds = annotation.bounds.insetBy(dx: -10, dy: -6)
        let lines = fullPageSelection.selectionsByLine()
            .filter { selection in
                let lineBounds = selection.bounds(for: page)
                return !lineBounds.isNull && !lineBounds.isEmpty && lineBounds.intersects(candidateBounds)
            }
            .compactMap { trimmed($0.string) }

        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private static func kindLabel(for annotation: PDFAnnotation) -> String {
        let rawType = annotation.type ?? "Annotation"
        let normalized = rawType
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized.lowercased() {
        case "highlight":
            return "Highlight"
        case "underline":
            return "Underline"
        case "strikeout", "strike out":
            return "Strikeout"
        case "ink":
            return "Ink annotation"
        case "text":
            return "Text note"
        case "freetext", "free text":
            return "Free text"
        default:
            return normalized.isEmpty ? "Annotation" : normalized
        }
    }

    private static func markdownEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func colorHex(for annotation: PDFAnnotation) -> String? {
        #if os(macOS)
        guard let color = annotation.color.usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
        #else
        return nil
        #endif
    }
}

public enum PDFAnnotationMarkdownExportError: LocalizedError {
    case unreadablePDF

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "Could not read the PDF document."
        }
    }
}
