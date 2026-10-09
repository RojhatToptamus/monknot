import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import MonknotCore
import XCTest
@testable import MonknotApp

/// Images open in the PDF viewer on a page that draws the file's own pixels; markup is saved by
/// drawing it into the image and writing the image's own format.
@MainActor
final class ImageMarkupDocumentTests: WorkspaceStorePDFTestCase {
    private let width = 120
    private let height = 80

    func testTheImagePageDrawsTheFilesPixelsExactly() throws {
        let original = makeNoiseImage()
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(try encode(original, as: .png)))
        let page = try XCTUnwrap(ImageMarkupDocument.makeDocument(from: decoded, markupData: nil).page(at: 0))

        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: width, height: height))
        XCTAssertEqual(try differingBytes(original, render(page)), 0, "PDFKit must not recompress the image")
        XCTAssertTrue(decoded.canSaveMarkup)
    }

    func testARetinaScreenshotShowsAtThePointSizeItWasTakenAt() throws {
        let data = try encode(makeNoiseImage(), as: .png, properties: [
            kCGImagePropertyDPIWidth: 144,
            kCGImagePropertyDPIHeight: 144,
        ])
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(data))

        XCTAssertEqual(decoded.pageSize, CGSize(width: width / 2, height: height / 2))
        XCTAssertEqual(decoded.image.width, width, "Pixels are kept at full resolution")
    }

    func testAPhotoTakenSidewaysOpensUpright() throws {
        let data = try encode(makeNoiseImage(), as: .jpeg, properties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
        ])
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(data))

        XCTAssertEqual(decoded.image.width, height)
        XCTAssertEqual(decoded.image.height, width)

        let markup = try markupData(highlighting: CGRect(x: 4, y: 4, width: 10, height: 10), on: decoded)
        let flattened = try ImageMarkupDocument.flattenedImageData(imageData: data, markupData: markup)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(flattened as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(
            (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            CGImagePropertyOrientation.up.rawValue,
            "The saved pixels are upright, so the file must not rotate them again"
        )
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, height)
    }

    func testUnsavedMarkupTravelsWithoutTheImageAndComesBackOnTheImage() throws {
        let imageData = try encode(makeNoiseImage(), as: .png)
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(imageData))
        let document = ImageMarkupDocument.makeDocument(from: decoded, markupData: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        let ink = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 10, y: 10))
        path.line(to: CGPoint(x: 100, y: 60))
        ink.add(path)
        page.addAnnotation(ink)

        let markup = try XCTUnwrap(ImageMarkupDocument.markupData(from: document))
        let fullDocument = try XCTUnwrap(document.dataRepresentation())
        XCTAssertLessThan(markup.count, fullDocument.count, "Each edit must not re-encode the image")

        let reopened = ImageMarkupDocument.makeDocument(from: decoded, markupData: markup)
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(reopenedPage.annotations.map(\.type), ["Ink"])
        XCTAssertTrue(reopenedPage is ImageMarkupPage, "The pixels come from the file, not the markup")
    }

    func testSavingDrawsTheMarkupIntoTheImageInItsOwnFormat() throws {
        let original = makeNoiseImage()
        let imageData = try encode(original, as: .png)
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(imageData))
        let highlighted = CGRect(x: 10, y: 10, width: 40, height: 20)

        let flattened = try ImageMarkupDocument.flattenedImageData(
            imageData: imageData,
            markupData: try markupData(highlighting: highlighted, on: decoded)
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithData(flattened as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(saved.width, width)
        XCTAssertEqual(saved.height, height)

        let originalPixels = try rgbaPixels(original)
        let savedPixels = try rgbaPixels(saved)
        var changedInside = 0
        var changedOutside = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let changed = originalPixels[offset..<offset + 3] != savedPixels[offset..<offset + 3]
                // Pixel rows run top-down; page coordinates run bottom-up.
                let pagePoint = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(height - y) - 0.5)
                if highlighted.insetBy(dx: -1, dy: -1).contains(pagePoint) {
                    changedInside += changed ? 1 : 0
                } else if changed {
                    changedOutside += 1
                }
            }
        }
        XCTAssertGreaterThan(changedInside, Int(highlighted.width * highlighted.height) / 2)
        XCTAssertEqual(changedOutside, 0, "Pixels outside the markup are written back unchanged")
    }

    func testAJPEGIsSavedAsAJPEG() throws {
        let imageData = try encode(makeNoiseImage(), as: .jpeg)
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(imageData))
        let flattened = try ImageMarkupDocument.flattenedImageData(
            imageData: imageData,
            markupData: try markupData(highlighting: CGRect(x: 4, y: 4, width: 20, height: 20), on: decoded)
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(flattened as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testAnAnimationIsReadOnlyBecauseSavingWouldDropItsFrames() throws {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, makeNoiseImage(), nil)
        CGImageDestinationAddImage(destination, makeNoiseImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(output as Data))

        XCTAssertFalse(decoded.canSaveMarkup)
        XCTAssertThrowsError(try ImageMarkupDocument.flattenedImageData(
            imageData: output as Data,
            markupData: try markupData(highlighting: CGRect(x: 4, y: 4, width: 20, height: 20), on: decoded)
        ))
    }

    func testSavingAMarkedUpImageWritesTheImageAndReopensIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("Screenshot.png")
        let imageData = try encode(makeNoiseImage(), as: .png)
        try imageData.write(to: imageURL)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && !store.documents.isEmpty }
        XCTAssertTrue(didLoad)
        let image = try XCTUnwrap(store.documents.first { $0.url == imageURL.standardizedFileURL })
        XCTAssertEqual(image.kind, .image)
        store.selectDocument(id: image.id)
        _ = await waitUntil { store.selectedDocumentID == image.id && !store.isDocumentLoading }
        let contentVersionBeforeSave = store.pdfContentVersion(for: image.id)

        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(imageData))
        store.markPDFDocumentEdited(
            id: image.id,
            previousData: imageData,
            data: try markupData(highlighting: CGRect(x: 10, y: 10, width: 40, height: 20), on: decoded)
        )
        XCTAssertFalse(store.saveState(for: image.id).isClean)

        store.saveSelectedFile()
        let didSave = await waitUntil { store.saveState(for: image.id).isClean && !store.isSaving }
        XCTAssertTrue(didSave, store.errorMessage ?? "")

        let savedData = try Data(contentsOf: imageURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(savedData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, "A PNG must stay a PNG")
        XCTAssertNotEqual(savedData, imageData)
        XCTAssertNil(store.dirtyPDFData(for: image.id))
        XCTAssertGreaterThan(
            store.pdfContentVersion(for: image.id),
            contentVersionBeforeSave,
            "The viewer reopens the saved file, so the next markup starts from its pixels"
        )
    }

    func testAClickWithTheHighlighterKeepsTheBaselineForTheNextHighlight() throws {
        let imageData = try encode(makeNoiseImage(), as: .png)
        let decoded = try XCTUnwrap(ImageMarkupDocument.decode(imageData))
        let view = AnnotatingPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.document = ImageMarkupDocument.makeDocument(from: decoded, markupData: nil)
        view.serializeDocument = ImageMarkupDocument.markupData(from:)
        view.replaceEditBaselineCapture(with: imageData, needsSnapshot: true)
        view.layoutDocumentView()
        var publishedBaselines: [Data?] = []
        view.onEdited = { previousData, _, _ in publishedBaselines.append(previousData) }
        view.annotationMode = .highlighter

        let page = try XCTUnwrap(view.document?.page(at: 0))
        func send(_ type: NSEvent.EventType, _ pagePoint: CGPoint) {
            let point = view.convert(view.convert(pagePoint, from: page), to: nil)
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }

        send(.leftMouseDown, CGPoint(x: 20, y: 20))
        send(.leftMouseUp, CGPoint(x: 20, y: 20))
        XCTAssertTrue(publishedBaselines.isEmpty, "A click is not a highlight")

        send(.leftMouseDown, CGPoint(x: 10, y: 10))
        send(.leftMouseDragged, CGPoint(x: 60, y: 40))
        send(.leftMouseUp, CGPoint(x: 60, y: 40))
        XCTAssertEqual(publishedBaselines, [imageData], "The first real highlight carries the file's bytes as its baseline")
    }

    // MARK: - Fixtures

    private func makeNoiseImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(width * height * 4) {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return context.makeImage()!
    }

    private func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func markupData(
        highlighting area: CGRect,
        on decoded: ImageMarkupDocument.DecodedImage
    ) throws -> Data {
        let document = ImageMarkupDocument.makeDocument(from: decoded, markupData: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: area, forType: .highlight, withProperties: nil)
        highlight.color = NSColor.systemYellow.withAlphaComponent(0.46)
        highlight.quadrilateralPoints = pdfTextMarkupQuadrilateralPoints(for: area.size)
        page.addAnnotation(highlight)
        return try XCTUnwrap(ImageMarkupDocument.markupData(from: document))
    }

    private func render(_ page: PDFPage) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.interpolationQuality = .none
        page.draw(with: .mediaBox, to: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Colour bytes that differ; the fourth byte of each pixel is padding.
    private func differingBytes(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
        zip(try rgbaPixels(lhs), try rgbaPixels(rhs))
            .enumerated()
            .filter { $0.offset % 4 != 3 && $0.element.0 != $0.element.1 }
            .count
    }
}

@MainActor
final class MarkdownOutlineRailEqualityTests: XCTestCase {
    func testRailsForDifferentDocumentsWithTheSameHeadingsAreNotEqual() {
        let position = MarkdownOutlinePosition()
        let items = [
            MarkdownOutlineItem(id: "1-1-Today", title: "Today", level: 1, location: MarkdownSourceLocation(line: 1, offset: 0)),
        ]
        func rail(_ documentID: String) -> MarkdownOutlineRail {
            MarkdownOutlineRail(
                documentID: documentID, items: items, position: position,
                theme: .defaultLight, zoomScale: 1, select: { _ in }
            )
        }
        XCTAssertEqual(rail("/a.md"), rail("/a.md"))
        XCTAssertNotEqual(rail("/a.md"), rail("/b.md"), "Each rail's select records against its own document")
    }
}
