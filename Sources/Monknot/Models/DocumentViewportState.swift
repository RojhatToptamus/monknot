import CoreGraphics
import Foundation

struct DocumentViewportState: Equatable {
    var textScrollPosition: DocumentScrollPosition?
    var markdownPreviewScrollPosition: DocumentScrollPosition?
    var htmlPreviewScrollPosition: DocumentScrollPosition?
    var pdfPosition: PDFDocumentViewportPosition?
}

struct DocumentScrollPosition: Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var point: CGPoint {
        CGPoint(x: x, y: y)
    }

    func isMeaningfullyDifferent(from other: DocumentScrollPosition?, tolerance: Double = 0.5) -> Bool {
        guard let other else { return true }
        return abs(x - other.x) > tolerance || abs(y - other.y) > tolerance
    }
}

struct PDFDocumentViewportPosition: Equatable {
    var pageIndex: Int
    var point: DocumentScrollPosition

    init(pageIndex: Int, point: DocumentScrollPosition) {
        self.pageIndex = pageIndex
        self.point = point
    }
}

enum DocumentViewportStateChange {
    case textScrollPosition(DocumentScrollPosition)
    case markdownPreviewScrollPosition(DocumentScrollPosition)
    case htmlPreviewScrollPosition(DocumentScrollPosition)
    case pdfPosition(PDFDocumentViewportPosition)
}
