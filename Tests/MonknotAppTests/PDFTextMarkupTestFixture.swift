import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

class PDFTextMarkupTestCase: XCTestCase {

    func makePage(size: NSSize) throws -> PDFPage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return try XCTUnwrap(PDFPage(image: image))
    }

    @MainActor
    func activeEditor(in pdfView: AnnotatingPDFView) throws -> NSTextView {
        let scrollView = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? NSScrollView }.last)
        return try XCTUnwrap(scrollView.documentView as? NSTextView)
    }
}

func freeTextMouseEvent(
    type: NSEvent.EventType,
    location: NSPoint,
    pressure: Float = 1,
    clickCount: Int = 1
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: clickCount,
        pressure: pressure
    )
}

func freeTextDeleteKeyEvent(keyCode: UInt16 = 51) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\u{7F}",
        charactersIgnoringModifiers: "\u{7F}",
        isARepeat: false,
        keyCode: keyCode
    )
}

func freeTextEscapeKeyEvent() -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    )
}

final class NoCommentingPDFDocument: PDFDocument {
    override var allowsCommenting: Bool { false }
}

final class ImportedAlignmentPDFAnnotation: PDFAnnotation {
    var assignedAlignments: [NSTextAlignment] = []

    override var alignment: NSTextAlignment {
        get { .justified }
        set { assignedAlignments.append(newValue) }
    }
}
