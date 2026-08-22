import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

final class PDFNavigatorReloadCountingDataSource: NSObject, NSTableViewDataSource {
    private(set) var numberOfRowsCallCount = 0
    var onNumberOfRows: (() -> Void)?

    func numberOfRows(in tableView: NSTableView) -> Int {
        numberOfRowsCallCount += 1
        onNumberOfRows?()
        return 0
    }
}

@MainActor
class PDFNavigatorTestCase: XCTestCase {

    func makeImagePDFDocument(
        pageCount: Int,
        pageSize: NSSize = NSSize(width: 240, height: 300)
    ) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFNavigatorAndSelectionTests", code: 2)
        }

        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func makeTextPDFDocument(linesByPage: [[String]]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 260, height: 220)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFNavigatorAndSelectionTests", code: 1)
        }

        for lines in linesByPage {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 20, y: 154 - CGFloat(index * 26)),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: NSColor.black
                    ]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

}

@MainActor
final class NavigatorLaggingPDFView: PDFView {
    var navigatorCurrentPage: PDFPage?
    var laggingDestination: PDFDestination?

    override var currentPage: PDFPage? {
        navigatorCurrentPage ?? super.currentPage
    }

    override var currentDestination: PDFDestination? {
        laggingDestination ?? super.currentDestination
    }
}
