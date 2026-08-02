import CoreGraphics
import Foundation

struct DocumentViewportState: Equatable {
    var textScrollPosition: DocumentScrollPosition?
    var markdownPreviewScrollPosition: DocumentScrollPosition?
    var htmlPreviewScrollPosition: DocumentScrollPosition?
    var pdfViewportState: PDFDocumentViewportState?
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

    func isMeaningfullyDifferent(from other: PDFDocumentViewportPosition?) -> Bool {
        guard let other else { return true }
        return pageIndex != other.pageIndex || point.isMeaningfullyDifferent(from: other.point)
    }
}

enum PDFZoomMode: Equatable {
    case fitToView
    case fixed(scaleFactor: Double)
}

struct PDFDocumentViewportState: Equatable {
    var position: PDFDocumentViewportPosition?
    var zoomMode: PDFZoomMode

    init(position: PDFDocumentViewportPosition?, zoomMode: PDFZoomMode) {
        self.position = position
        self.zoomMode = zoomMode
    }

    func isMeaningfullyDifferent(from other: PDFDocumentViewportState?, scaleTolerance: Double = 0.002) -> Bool {
        guard let other else { return true }

        let zoomIsDifferent: Bool
        switch (zoomMode, other.zoomMode) {
        case (.fitToView, .fitToView):
            zoomIsDifferent = false
        case (.fixed(let scaleFactor), .fixed(let otherScaleFactor)):
            zoomIsDifferent = abs(scaleFactor - otherScaleFactor) > scaleTolerance
        case (.fitToView, .fixed), (.fixed, .fitToView):
            zoomIsDifferent = true
        }

        let positionIsDifferent: Bool
        switch (position, other.position) {
        case (nil, nil):
            positionIsDifferent = false
        case (.some(let position), .some(let otherPosition)):
            positionIsDifferent = position.isMeaningfullyDifferent(from: otherPosition)
        case (.some, nil), (nil, .some):
            positionIsDifferent = true
        }

        return zoomIsDifferent || positionIsDifferent
    }
}

enum DocumentViewportStateChange {
    case textScrollPosition(DocumentScrollPosition)
    case markdownPreviewScrollPosition(DocumentScrollPosition)
    case htmlPreviewScrollPosition(DocumentScrollPosition)
    case pdfViewportState(PDFDocumentViewportState)
}
