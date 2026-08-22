import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

class WorkspaceSearchServiceTestCase: XCTestCase {

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeSearchablePDF(_ text: String, to url: URL) throws {
        try writeSearchablePDF(pages: [text], to: url)
    }

    func writeSearchablePDF(pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "MonknotTests", code: 1)
        }

        for text in pages {
            context.beginPDFPage(nil)

            let attributed = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 72, y: 72, width: 468, height: 648))
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                path,
                nil
            )
            CTFrameDraw(frame, context)

            context.endPDFPage()
        }
        context.closePDF()
    }

    func writeAnnotatedPDF(pageText: String, annotationText: String, to url: URL) throws {
        let scratchURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).pdf")
        try writeSearchablePDF(pageText, to: scratchURL)
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        guard let document = PDFDocument(url: scratchURL), let page = document.page(at: 0) else {
            throw NSError(domain: "MonknotTests", code: 2)
        }

        let annotation = PDFAnnotation(
            bounds: CGRect(x: 72, y: 620, width: 240, height: 24),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = annotationText
        page.addAnnotation(annotation)

        guard let data = document.dataRepresentation() else {
            throw NSError(domain: "MonknotTests", code: 3)
        }
        try data.write(to: url)
    }
}
