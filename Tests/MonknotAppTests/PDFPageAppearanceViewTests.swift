import AppKit
import CoreImage
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

/// The page appearance (design.md §10.7a) changes only what the screen shows of a PDF's pages: the
/// canvas around them, an image, the document and every save keep their colours.
final class PDFPageAppearanceViewTests: PDFNavigatorTestCase {
    private static let colorContext = CIContext()

    func testDarkFiltersThePagesAndNotTheCanvas() throws {
        let (window, pdfView) = makeWindow(showing: try makeLectureDocument())
        defer { window.orderOut(nil) }
        let coordinator = PDFKitPreviewRepresentable.Coordinator()

        coordinator.applyAppearance(theme: .defaultDark, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView)
        window.layoutIfNeeded()

        let documentView = try XCTUnwrap(pdfView.documentView)
        try assertShown(documentView, as: .dark, in: .defaultDark, "Dark")
        XCTAssertFalse(pdfView.pageShadowsEnabled, "A page's shadow would show as a glow of ink")
        let scrollView = try XCTUnwrap(documentView.enclosingScrollView)
        for canvas in [pdfView, scrollView, scrollView.contentView] {
            XCTAssertEqual(canvas.contentFilters.count, 0, "\(type(of: canvas)) draws the canvas, which keeps the theme's colour")
        }

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView)
        try assertShown(documentView, as: .dark, in: .defaultLight, "Dark in a light theme")

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .dim, workspaceZoomScale: 1, in: pdfView)
        try assertShown(documentView, as: .dim, in: .defaultLight, "Dim")
        XCTAssertTrue(pdfView.pageShadowsEnabled)

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .original, workspaceZoomScale: 1, in: pdfView)
        XCTAssertEqual(documentView.contentFilters.count, 0)
        XCTAssertTrue(pdfView.pageShadowsEnabled)
    }

    func testTheFiltersShowEachColourAsTheAppearanceSays() throws {
        let colors: [[Double]] = [[1, 1, 1], [0, 0, 0], [0.5, 0.5, 0.5], [1, 0.9, 0.2], [0.2, 0.45, 0.95]]
        for (appearance, theme) in [(PDFPageAppearance.dark, AppTheme.defaultDark), (.dark, .defaultLight), (.dim, .defaultDark)] {
            let transform = try XCTUnwrap(appearance.colorTransform(in: theme))
            for color in colors {
                let expected = (0..<3).map { row in
                    min(max(zip(transform.matrix[row], color).map(*).reduce(transform.bias[row], +), 0), 1)
                }
                let shown = try shown(color, through: transform.contentFilters)
                for (value, target) in zip(shown, expected) {
                    XCTAssertEqual(value, target, accuracy: 1.5 / 255, "\(appearance) in \(theme.name): \(color) shows as \(shown), not \(expected)")
                }
            }
        }
    }

    /// The viewer keeps its PDF view when the file changes on disk or another PDF takes its tab,
    /// and PDFKit shows the new document in a new document view.
    func testAnotherDocumentInTheSameViewKeepsTheAppearance() throws {
        let (window, pdfView) = makeWindow(showing: try makeLectureDocument())
        defer { window.orderOut(nil) }
        PDFKitPreviewRepresentable.Coordinator()
            .applyAppearance(theme: .defaultDark, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView)
        let first = pdfView.documentView

        pdfView.document = try makeTextPDFDocument(linesByPage: [["Another file"]])

        XCTAssertFalse(pdfView.documentView === first)
        try assertShown(try XCTUnwrap(pdfView.documentView), as: .dark, in: .defaultDark, "Another document")
    }

    func testTheNavigatorShowsItsThumbnailsAsThePagesShow() throws {
        let pdfView = AnnotatingPDFView()
        let navigator = PDFNavigatorView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        let thumbnails = try XCTUnwrap(thumbnailCollection(in: navigator))

        coordinator.applyAppearance(theme: .defaultDark, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView, navigator: navigator)
        try assertShown(thumbnails, as: .dark, in: .defaultDark, "Thumbnails")
        // Dark shows black as the theme's text, so the labels are drawn in the light appearance.
        XCTAssertEqual(thumbnails.appearance?.name, .aqua)
        XCTAssertEqual(navigator.thumbnailView.contentFilters.count, 0, "The scroll bar keeps the theme's colours")
        XCTAssertEqual(navigator.contentFilters.count, 0, "The panel's surface keeps the theme's colour")

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView, navigator: navigator)
        try assertShown(thumbnails, as: .dark, in: .defaultLight, "Thumbnails in a light theme")
        XCTAssertEqual(thumbnails.appearance?.name, .darkAqua)

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .dim, workspaceZoomScale: 1, in: pdfView, navigator: navigator)
        try assertShown(thumbnails, as: .dim, in: .defaultLight, "Dim thumbnails")
        XCTAssertNil(thumbnails.appearance, "Dim keeps the theme's own labels")

        coordinator.applyAppearance(theme: .defaultLight, pageAppearance: .original, workspaceZoomScale: 1, in: pdfView, navigator: navigator)
        XCTAssertEqual(thumbnails.contentFilters.count, 0)
        XCTAssertNil(thumbnails.appearance)
    }

    func testATextBoxBeingEditedLooksLikeThePageAroundIt() throws {
        let (window, pdfView) = makeWindow(showing: try makeLectureDocument())
        defer {
            pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
            window.orderOut(nil)
        }
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        coordinator.applyAppearance(theme: .defaultDark, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView)

        pdfView.addFreeTextBox()

        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        let editor = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? NSScrollView }.last)
        XCTAssertFalse(editor === pdfView.documentView?.enclosingScrollView, "The editor is the text box's own view")
        try assertShown(editor, as: .dark, in: .defaultDark, "The text box being edited")

        coordinator.applyAppearance(theme: .defaultDark, pageAppearance: .original, workspaceZoomScale: 1, in: pdfView)
        XCTAssertEqual(editor.contentFilters.count, 0)
    }

    func testTheSettingReachesAnOpenPDFAndAnImageShowsAsItIs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotPDFPageAppearance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("Lecture.pdf")
        XCTAssertTrue(try makeLectureDocument().write(to: pdfURL))
        let imageURL = root.appendingPathComponent("Photo.png")
        try makePhotoPNG().write(to: imageURL)
        let defaultsName = "PDFPageAppearanceViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(PDFPageAppearance.dark.rawValue, forKey: PDFPageAppearance.preferenceKey)

        let (pdfWindow, pdfView) = try await host(WorkspaceDocument(url: pdfURL, rootURL: root), defaults: defaults)
        defer { pdfWindow.orderOut(nil) }
        let dark = await waitUntil { self.isClose((try? self.shownWhite(pdfView)) ?? nil, to: self.paper(of: .defaultDark)) }
        XCTAssertTrue(dark, "A PDF opens in the appearance the setting holds")
        XCTAssertFalse(pdfView.pageShadowsEnabled)
        let container = try XCTUnwrap(sequence(first: pdfView as NSView, next: \.superview)
            .compactMap { $0 as? PDFPreviewContainerView }.first)
        XCTAssertEqual(try XCTUnwrap(thumbnailCollection(in: container.navigatorView)).contentFilters.count, 3, "The navigator's thumbnails too")

        defaults.set(PDFPageAppearance.dim.rawValue, forKey: PDFPageAppearance.preferenceKey)
        let dim = await waitUntil { self.isClose((try? self.shownWhite(pdfView)) ?? nil, to: [204, 204, 204]) }
        XCTAssertTrue(dim, "An open PDF follows the setting")
        defaults.set(PDFPageAppearance.original.rawValue, forKey: PDFPageAppearance.preferenceKey)
        let original = await waitUntil { pdfView.documentView?.contentFilters.isEmpty == true }
        XCTAssertTrue(original)

        defaults.set(PDFPageAppearance.dark.rawValue, forKey: PDFPageAppearance.preferenceKey)
        let (imageWindow, imageView) = try await host(WorkspaceDocument(url: imageURL, rootURL: root), defaults: defaults)
        defer { imageWindow.orderOut(nil) }
        XCTAssertEqual(WorkspaceDocument(url: imageURL, rootURL: root).kind, .image)
        try await Task.sleep(nanoseconds: 300_000_000)
        imageWindow.layoutIfNeeded()
        XCTAssertEqual(imageView.documentView?.contentFilters.count, 0, "Dark would show a picture as its negative")
        XCTAssertTrue(imageView.pageShadowsEnabled)
        XCTAssertEqual(barPopUpFrames(in: imageWindow).count, 2, "An image's bar has the colour and the zoom, no page appearance")
    }

    /// The bar's pop-up (design.md §10.7a): its menu shows the pages in the appearance it highlights,
    /// Esc puts them back, and a choice holds for every PDF.
    func testTheBarsPopUpPreviewsWhatItsMenuHighlightsAndKeepsWhatItChooses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotPDFPageAppearanceBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Lecture.pdf")
        XCTAssertTrue(try makeLectureDocument().write(to: url))
        let defaultsName = "PDFPageAppearanceViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(PDFPageAppearance.original.rawValue, forKey: PDFPageAppearance.preferenceKey)
        let menu = MonknotContextMenuController.shared
        menu.close(animated: false)
        let (window, pdfView) = try await host(WorkspaceDocument(url: url, rootURL: root), defaults: defaults)
        defer {
            menu.close(animated: false)
            window.orderOut(nil)
        }
        let popUps = barPopUpFrames(in: window)
        XCTAssertEqual(popUps.count, 3, "The colour, the page appearance and the zoom")
        // The view's group: the page appearance, then the zoom.
        let button = try XCTUnwrap(popUps.dropLast().last)

        try await click(button, in: window)
        XCTAssertEqual(menu.openTitles, ["Original", "Dim", "Dark"])
        XCTAssertEqual(menu.openModel?.entries.map { $0.item?.isChecked == true }, [true, false, false])
        XCTAssertEqual(menu.openModel?.entries.map { $0.item?.systemImage }, ["sun.max", "sun.min", "moon"])
        press(125, in: menu)
        press(125, in: menu)
        let previewed = await waitUntil { self.isClose((try? self.shownWhite(pdfView)) ?? nil, to: self.paper(of: .defaultDark)) }
        XCTAssertTrue(previewed, "The pages show the appearance the menu highlights")
        XCTAssertEqual(defaults.string(forKey: PDFPageAppearance.preferenceKey), "original", "A highlight is not a choice")

        press(53, in: menu)
        let restored = await waitUntil { pdfView.documentView?.contentFilters.isEmpty == true }
        XCTAssertTrue(restored, "Esc puts the pages back")
        XCTAssertEqual(defaults.string(forKey: PDFPageAppearance.preferenceKey), "original")

        try await click(button, in: window)
        press(125, in: menu)
        press(36, in: menu)
        let chosen = await waitUntil { defaults.string(forKey: PDFPageAppearance.preferenceKey) == "dim" }
        XCTAssertTrue(chosen, "Return chooses Dim for every PDF")
        let dim = await waitUntil { self.isClose((try? self.shownWhite(pdfView)) ?? nil, to: [204, 204, 204]) }
        XCTAssertTrue(dim)
    }

    func testSavingWhileDarkKeepsThePagesAndTheirMarkupAsTheFileHasThem() throws {
        let document = try makeLectureDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 44, y: 266, width: 330, height: 24), forType: .highlight, withProperties: nil)
        highlight.color = NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1)
        page.addAnnotation(highlight)
        let (window, pdfView) = makeWindow(showing: document)
        defer { window.orderOut(nil) }
        PDFKitPreviewRepresentable.Coordinator()
            .applyAppearance(theme: .defaultDark, pageAppearance: .dark, workspaceZoomScale: 1, in: pdfView)
        window.orderFrontRegardless()
        window.displayIfNeeded()

        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        // PDFKit draws pages the same way for thumbnails, printing and saving as for the screen.
        for (name, drawn) in [("The page", page), ("The saved page", try XCTUnwrap(saved.page(at: 0)))] {
            XCTAssertEqual(try pixel(of: drawn, at: Self.paperPoint), [255, 255, 255], "\(name): the paper stays white")
            XCTAssertEqual(try pixel(of: drawn, at: Self.inkPoint), [0, 0, 0], "\(name): the ink stays black")
        }
        let savedHighlight = try XCTUnwrap(saved.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        let color = try XCTUnwrap(savedHighlight.color.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.9, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.2, accuracy: 0.01)
    }

    /// With `MONKNOT_PDF_PAGE_APPEARANCE_SNAPSHOT_DIR` set, captures a lecture with a chart, a photo
    /// and markup in each appearance, in Harbor light and dark, and Dark at zoom 0.8 and 2, with the
    /// navigator open, with a text box being edited and with the bar's menu previewing a row, as the
    /// window server composites them (the filters are not in a view's own drawing).
    func testCaptureThePageAppearances() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_PDF_PAGE_APPEARANCE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_PDF_PAGE_APPEARANCE_SNAPSHOT_DIR to capture the page appearances")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotPDFPageAppearanceShots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Lecture.pdf")
        let document = try makeLectureDocument()
        try addMarkup(to: try XCTUnwrap(document.page(at: 0)))
        XCTAssertTrue(document.write(to: url))

        typealias Shot = (name: String, theme: AppTheme, appearance: PDFPageAppearance, zoom: Double, state: ShotState)
        var shots: [Shot] = []
        for (themeName, theme) in [("light", AppTheme.defaultLight), ("dark", .defaultDark)] {
            for appearance in PDFPageAppearance.allCases {
                shots.append(("\(themeName)-\(appearance.rawValue)", theme, appearance, 1, .pages))
            }
        }
        shots += [
            ("dark-dark-zoom-0.8", .defaultDark, .dark, 0.8, .pages),
            ("dark-dark-zoom-2", .defaultDark, .dark, 2, .pages),
            ("dark-dark-navigator", .defaultDark, .dark, 1, .navigator),
            ("light-dark-navigator", .defaultLight, .dark, 1, .navigator),
            ("dark-dim-navigator", .defaultDark, .dim, 1, .navigator),
            ("dark-dark-editing", .defaultDark, .dark, 1, .editing),
            ("light-original-menu", .defaultLight, .original, 1, .menu),
            ("dark-original-menu", .defaultDark, .original, 1, .menu),
            ("dark-dark-menu-zoom-2", .defaultDark, .dark, 2, .menu),
        ]

        for (name, theme, appearance, zoom, state) in shots {
            let defaultsName = "PDFPageAppearanceShots.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defaults.set(appearance.rawValue, forKey: PDFPageAppearance.preferenceKey)
            let (window, pdfView) = try await host(
                WorkspaceDocument(url: url, rootURL: root),
                defaults: defaults,
                theme: theme,
                zoomScale: zoom,
                size: NSSize(width: 980, height: 720)
            )
            window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            switch state {
            case .pages:
                break
            case .navigator:
                let container = try XCTUnwrap(window.contentView?.allDescendantsForTesting()
                    .compactMap { $0 as? PDFPreviewContainerView }.first)
                container.setNavigatorPresented(true)
            case .menu:
                // The bar's pop-up, open on the row after the current one, which the pages preview.
                try await click(try XCTUnwrap(barPopUpFrames(in: window, zoomScale: zoom).dropLast().last), in: window)
                press(125, in: MonknotContextMenuController.shared)
            case .editing:
                pdfView.addFreeTextBox()
                let editor = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? NSScrollView }.last?.documentView as? NSTextView)
                window.makeFirstResponder(editor)
                editor.insertText("Revise before Friday", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let image = try XCTUnwrap(CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("pdf-pages-\(name).png"))
            if let panel = MonknotContextMenuController.shared.openPanel,
               let menuImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(panel.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
               ) {
                try NSBitmapImageRep(cgImage: menuImage).representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("pdf-pages-\(name)-panel.png"))
            }
            MonknotContextMenuController.shared.close(animated: false)
            pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private enum ShotState {
        case pages
        case navigator
        case editing
        case menu
    }

    // MARK: - Fixtures

    /// Where the lecture's paper and its ink square are, in page points.
    private static let paperPoint = CGPoint(x: 300, y: 120)
    private static let inkPoint = CGPoint(x: 60, y: 50)

    /// Two slides like a lecture's: white paper, a black title, grey bullets, a black square of
    /// ink, coloured bars and a photo.
    private func makeLectureDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 720, height: 405)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFPageAppearanceViewTests", code: 1)
        }
        let photo = try makePhoto()
        for number in 4...5 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(mediaBox)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Lecture \(number): Sorting" as NSString).draw(
                at: CGPoint(x: 40, y: 330),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black]
            )
            let bullets = ["Merge sort splits the list in half", "Each half is sorted, then merged", "O(n log n) comparisons"]
            for (line, text) in bullets.enumerated() {
                ("•  \(text)" as NSString).draw(
                    at: CGPoint(x: 48, y: 268 - CGFloat(line) * 32),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 0.2, alpha: 1)]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 40, height: 20))
            let bars = [
                (CGFloat(120), CGColor(srgbRed: 0.16, green: 0.4, blue: 0.85, alpha: 1)),
                (80, CGColor(srgbRed: 0.95, green: 0.55, blue: 0.1, alpha: 1)),
                (150, CGColor(srgbRed: 0.2, green: 0.65, blue: 0.3, alpha: 1)),
            ]
            for (index, (height, color)) in bars.enumerated() {
                context.setFillColor(color)
                context.fill(CGRect(x: 420 + CGFloat(index) * 46, y: 40, width: 34, height: height))
            }
            context.draw(photo, in: CGRect(x: 580, y: 40, width: 110, height: 150))
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    /// A small picture: a sky over the sea with a sun.
    private func makePhoto() throws -> CGImage {
        let width = 110
        let height = 150
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let sky = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                    CGColor(srgbRed: 0.35, green: 0.6, blue: 0.92, alpha: 1),
                ] as CFArray,
                locations: [0, 1]
              )
        else {
            throw NSError(domain: "PDFPageAppearanceViewTests", code: 2)
        }
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 50), end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 70, width: 30, height: 30))
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.25, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 50))
        return try XCTUnwrap(context.makeImage())
    }

    private func makePhotoPNG() throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: try makePhoto()).representation(using: .png, properties: [:]))
    }

    /// A highlight, a pen circle and a note, as the PDF bar's tools leave them.
    private func addMarkup(to page: PDFPage) throws {
        let highlight = PDFAnnotation(bounds: CGRect(x: 44, y: 266, width: 330, height: 24), forType: .highlight, withProperties: nil)
        highlight.color = NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1)
        page.addAnnotation(highlight)

        let circleBounds = CGRect(x: 40, y: 196, width: 250, height: 40)
        let pen = PDFAnnotation(bounds: circleBounds, forType: .ink, withProperties: nil)
        pen.add(NSBezierPath(ovalIn: CGRect(x: 4, y: 4, width: circleBounds.width - 8, height: circleBounds.height - 8)))
        pen.color = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1)
        let border = PDFBorder()
        border.lineWidth = 3
        pen.border = border
        page.addAnnotation(pen)

        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 196, width: 110, height: 28), forType: .freeText, withProperties: nil)
        note.contents = "On the exam"
        note.font = NSFont.systemFont(ofSize: 16)
        note.fontColor = NSColor(srgbRed: 0.1, green: 0.3, blue: 0.85, alpha: 1)
        note.color = .clear
        page.addAnnotation(note)
    }

    private func makeWindow(showing document: PDFDocument) -> (NSWindow, AnnotatingPDFView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let pdfView = AnnotatingPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        pdfView.autoresizingMask = [.width, .height]
        window.contentView = pdfView
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.layoutDocumentView()
        window.layoutIfNeeded()
        return (window, pdfView)
    }

    private func host(
        _ document: WorkspaceDocument,
        defaults: UserDefaults,
        theme: AppTheme = .defaultDark,
        zoomScale: Double = 1,
        size: NSSize = NSSize(width: 900, height: 700)
    ) async throws -> (NSWindow, AnnotatingPDFView) {
        let host = NSHostingView(rootView: PDFPageAppearanceHost(document: document, theme: theme, zoomScale: zoomScale)
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults))
        host.frame = NSRect(origin: .zero, size: size)
        // Key, as the app's window is, so a click on the bar reaches its control.
        let window = KeyTestWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<150 {
            if let pdfView = host.allDescendantsForTesting().compactMap({ $0 as? AnnotatingPDFView }).first,
               pdfView.document != nil {
                // The view reports the load a turn later, and the bar enables then.
                try await Task.sleep(nanoseconds: 300_000_000)
                return (window, pdfView)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.orderOut(nil)
        XCTFail("\(document.relativePath) did not open")
        throw CancellationError()
    }

    // MARK: - The bar

    /// The bar's pop-ups, from its leading edge, in window coordinates: each lays a plain view, its
    /// menu's presenter, under itself, and nothing else in the bar is one.
    private func barPopUpFrames(in window: NSWindow, zoomScale: Double = 1) -> [NSRect] {
        guard let content = window.contentView else { return [] }
        let height = MonknotMetrics.interfaceDensity(40, theme: .defaultLight, zoomScale: zoomScale)
        let bar = NSRect(x: 0, y: content.bounds.height - height, width: content.bounds.width, height: height)
        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        // The bar lays out each of its widths to choose one, so a control can appear more than once.
        let frames = descendants(of: content)
            .filter { type(of: $0) == NSView.self }
            .map { $0.convert($0.bounds, to: nil) }
            .filter { bar.contains($0) && $0.width >= 20 && $0.height >= 20 }
        return Array(Set(frames.map { [$0.minX, $0.minY, $0.width, $0.height] }))
            .map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            .sorted { $0.minX < $1.minX }
    }

    private func click(_ frame: NSRect, in window: NSWindow) async throws {
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        // A control in a key window tracks the press in a loop of its own until the mouse comes up,
        // so the release waits in the queue; if nothing tracked the press it is still there.
        deliverPendingAppKitEvents()
        NSApp.postEvent(events[1], atStart: false)
        window.sendEvent(events[0])
        try await Task.sleep(nanoseconds: 40_000_000)
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {
            window.sendEvent(events[1])
        }
        let opened = await waitUntil(timeout: 3) { MonknotContextMenuController.shared.isOpen }
        XCTAssertTrue(opened, "Clicking the pop-up opens its menu")
    }

    private func press(_ keyCode: UInt16, in menu: MonknotContextMenuController) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return XCTFail("Could not make a key event")
        }
        XCTAssertTrue(menu.handleForTesting(event), "The open menu takes the key")
    }

    // MARK: - Colours

    private func assertShown(
        _ view: NSView,
        as appearance: PDFPageAppearance,
        in theme: AppTheme,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let transform = try XCTUnwrap(appearance.colorTransform(in: theme), file: file, line: line)
        XCTAssertEqual(view.contentFilters.count, 3, message, file: file, line: line)
        for (white, target) in zip(try shown([1, 1, 1], through: view.contentFilters), transform.bias.indices.map { row in
            min(max(transform.matrix[row].reduce(transform.bias[row], +), 0), 1)
        }) {
            XCTAssertEqual(white, target, accuracy: 1.5 / 255, "\(message): white paper", file: file, line: line)
        }
        for (black, target) in zip(try shown([0, 0, 0], through: view.contentFilters), transform.bias) {
            XCTAssertEqual(black, min(max(target, 0), 1), accuracy: 1.5 / 255, "\(message): black ink", file: file, line: line)
        }
    }

    /// The collection view PDFKit lays the navigator's thumbnails out in.
    private func thumbnailCollection(in navigator: PDFNavigatorView) -> NSView? {
        func firstScrollView(in view: NSView) -> NSScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? NSScrollView ?? firstScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }
        return firstScrollView(in: navigator.thumbnailView)?.documentView
    }

    /// White as the pages show it, in 8-bit sRGB.
    private func shownWhite(_ pdfView: AnnotatingPDFView) throws -> [Int]? {
        guard let filters = pdfView.documentView?.contentFilters, !filters.isEmpty else { return nil }
        return try shown([1, 1, 1], through: filters).map { Int(($0 * 255).rounded()) }
    }

    /// Within one step of 8-bit rounding.
    private func isClose(_ shown: [Int]?, to expected: [Int]?) -> Bool {
        guard let shown, let expected, shown.count == expected.count else { return false }
        return zip(shown, expected).allSatisfy { abs($0 - $1) <= 1 }
    }

    private func paper(of theme: AppTheme) -> [Int]? {
        guard let paper = RGBHex(theme.isDark ? theme.background : theme.foreground) else { return nil }
        return [paper.red, paper.green, paper.blue].map { Int(($0 * 255).rounded()) }
    }

    /// `color` in sRGB as Core Image composites it through `filters`, the way the window server
    /// applies a layer's filters.
    private func shown(_ color: [Double], through filters: [CIFilter]) throws -> [Double] {
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var image = CIImage(color: try XCTUnwrap(CIColor(
            red: color[0],
            green: color[1],
            blue: color[2],
            alpha: 1,
            colorSpace: sRGB
        ))).cropped(to: unit)
        for filter in filters {
            let copy = try XCTUnwrap(filter.copy() as? CIFilter)
            copy.setValue(image, forKey: kCIInputImageKey)
            image = try XCTUnwrap(copy.outputImage)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.colorContext.render(image, toBitmap: &pixel, rowBytes: 4, bounds: unit, format: .RGBA8, colorSpace: sRGB)
        return pixel.prefix(3).map { Double($0) / 255 }
    }

    /// The 8-bit sRGB colour PDFKit draws at `point` of `page`.
    private func pixel(of page: PDFPage, at point: CGPoint) throws -> [Int] {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw NSError(domain: "PDFPageAppearanceViewTests", code: 3)
        }
        page.draw(with: .mediaBox, to: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (height - 1 - Int(point.y)) * width * 4 + Int(point.x) * 4
        return (0..<3).map { Int(bytes[offset + $0]) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// The PDF viewer as the editor pane shows it, without a workspace.
private struct PDFPageAppearanceHost: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double
    @State private var search = DocumentSearchState()
    @State private var target: WorkspaceSearchPDFTarget?
    @StateObject private var bridge = PDFViewportCaptureBridge()

    var body: some View {
        PDFPreviewView(
            document: document,
            theme: theme,
            zoomScale: zoomScale,
            saveState: .clean,
            dirtyData: nil,
            savedEditCheckpoint: nil,
            contentVersion: 0,
            viewportState: nil,
            viewportCaptureBridge: bridge,
            externalUndoCommandSerial: 0,
            externalRedoCommandSerial: 0,
            searchState: $search,
            searchTarget: $target,
            markEdited: { _, _, _ in },
            restoreSavedEditCheckpoint: { _ in true },
            reportError: { _ in },
            saveDocument: {},
            onViewportStateChange: { _ in },
            updateAnnotationUndoState: { _, _ in }
        )
    }
}
