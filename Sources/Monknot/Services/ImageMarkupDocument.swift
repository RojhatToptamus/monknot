import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Shows an image as a one-page PDF document, so it gets the PDF viewer's zoom and markup tools the
/// way Preview marks up images. The page draws the decoded image itself, pixel for pixel; markup
/// stays PDF annotations until a save draws it into the image and writes the image's own format.
///
/// Unsaved markup travels as a small PDF holding only the page size and its annotations. The image
/// file on disk stays the source of the pixels until the markup is saved into it.
enum ImageMarkupDocument {
    enum Failure: LocalizedError {
        case unreadableImage
        case unreadableMarkup
        case unsupportedFormat
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                "The image could not be read."
            case .unreadableMarkup:
                "The markup could not be read."
            case .unsupportedFormat:
                "Markup can't be saved into this image format."
            case .encodingFailed:
                "The marked-up image could not be encoded."
            }
        }
    }

    /// A decoded image, upright, with the size it has on the page.
    struct DecodedImage {
        let image: CGImage
        let pageSize: CGSize
        let contentType: String
        /// Markup is saved by re-encoding the image as 8-bit RGB in its own format. Formats ImageIO
        /// cannot write (WebP), animations, and deeper or non-RGB images would lose data, so those
        /// are read-only.
        let canSaveMarkup: Bool
        fileprivate let properties: [CFString: Any]
    }

    static func decode(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let contentType = CGImageSourceGetType(source) as String?,
              let image = uprightImage(from: source)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let colorModel = image.colorSpace?.model
        let isEightBitRGBOrGray = image.bitsPerComponent <= 8
            && (colorModel == .rgb || colorModel == .monochrome)
        // Points follow the image's resolution, so a Retina screenshot shows at the size it was
        // taken at, as in Preview.
        func points(_ pixels: Int, dpi key: CFString) -> CGFloat {
            let dpi = (properties[key] as? NSNumber)?.doubleValue ?? 72
            return CGFloat(pixels) * 72 / CGFloat(dpi > 0 ? dpi : 72)
        }
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return DecodedImage(
            image: image,
            pageSize: CGSize(
                width: points(image.width, dpi: kCGImagePropertyDPIWidth),
                height: points(image.height, dpi: kCGImagePropertyDPIHeight)
            ),
            contentType: contentType,
            canSaveMarkup: writableTypes.contains(contentType)
                && CGImageSourceGetCount(source) == 1
                && isEightBitRGBOrGray,
            properties: properties
        )
    }

    /// The image as a document, with any unsaved markup from `markupData` back on its page.
    static func makeDocument(from decoded: DecodedImage, markupData: Data?) -> PDFDocument {
        let page = ImageMarkupPage(image: decoded.image, size: decoded.pageSize)
        if let markupData,
           let markupPage = PDFDocument(data: markupData)?.page(at: 0) {
            // Annotations move between pages intact; copying them corrupts PDFKit's state.
            for annotation in markupPage.annotations {
                markupPage.removeAnnotation(annotation)
                page.addAnnotation(annotation)
            }
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    /// The markup on an image document: its page size and annotations, without the image.
    static func markupData(from document: PDFDocument) -> Data? {
        ImageMarkupPage.withoutImage {
            document.dataRepresentation()
        }
    }

    /// The image with its markup drawn in, encoded in the image's own format.
    static func flattenedImageData(imageData: Data, markupData: Data) throws -> Data {
        guard let decoded = decode(imageData) else { throw Failure.unreadableImage }
        guard decoded.canSaveMarkup else { throw Failure.unsupportedFormat }
        guard let markupPage = PDFDocument(data: markupData)?.page(at: 0) else {
            throw Failure.unreadableMarkup
        }

        let image = decoded.image
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: (hasAlpha
                ? CGImageAlphaInfo.premultipliedLast
                : CGImageAlphaInfo.noneSkipLast).rawValue
        ) else { throw Failure.encodingFailed }

        let pixelRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: pixelRect)
        let pageBox = markupPage.bounds(for: .mediaBox)
        context.scaleBy(x: pixelRect.width / pageBox.width, y: pixelRect.height / pageBox.height)
        context.translateBy(x: -pageBox.minX, y: -pageBox.minY)
        // Text boxes draw their text through AppKit.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in markupPage.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let flattened = context.makeImage() else { throw Failure.encodingFailed }

        // Keep the file's metadata, but its pixels are now upright.
        var properties = decoded.properties
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, decoded.contentType as CFString, 1, nil) else {
            throw Failure.unsupportedFormat
        }
        CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return output as Data
    }

    private static func uprightImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        guard orientation != CGImagePropertyOrientation.up.rawValue,
              let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        // ImageIO applies the EXIF orientation when it makes a full-size thumbnail.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    }
}

/// A PDF page that draws an image. PDFKit draws pages on background threads too, so the image
/// is immutable and the page only reads it.
final class ImageMarkupPage: PDFPage {
    private static let markupOnlyKey = "Monknot.ImageMarkupPage.markupOnly"
    private let image: CGImage

    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init()
        setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
    }

    /// Runs `body` with image pages on this thread drawing only their annotations, so serializing
    /// a document writes the markup without re-encoding the image into it.
    static func withoutImage<Result>(_ body: () -> Result) -> Result {
        let threadDictionary = Thread.current.threadDictionary
        threadDictionary[markupOnlyKey] = true
        defer { threadDictionary.removeObject(forKey: markupOnlyKey) }
        return body()
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        if Thread.current.threadDictionary[Self.markupOnlyKey] == nil {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: bounds(for: .mediaBox))
            context.restoreGState()
        }
        super.draw(with: box, to: context)
    }
}
