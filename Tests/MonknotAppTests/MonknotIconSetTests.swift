import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// The chrome's glyphs read as one set (design.md §8.2): every glyph in a place is drawn on that
/// place's stroke, every picture in it meets one optical size, and both hold for what SwiftUI really
/// renders, at every zoom, in light and dark.
@MainActor
final class MonknotIconSetTests: XCTestCase {
    /// Every place a glyph sits, with the glyphs it shows: the bars, the segmented controls, the small
    /// buttons in fields, menu rows (the chrome's and Preview's) and the file glyphs.
    static let places: [(name: String, nominal: CGFloat, glyphs: [String])] = [
        ("titlebar", 17, [MonknotWorkspaceIcons.sidebarLeft, MonknotWorkspaceIcons.back,
                          MonknotWorkspaceIcons.forward, MonknotWorkspaceIcons.sidebarRight]),
        ("view mode", 16, [EditorMode.source.systemImage, EditorMode.preview.systemImage]),
        ("sidebar header", 17, [MonknotWorkspaceIcons.searchWorkspace, MonknotWorkspaceIcons.newMarkdown]),
        ("terminal bar", 17, ["arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left", "plus", "xmark"]),
        ("PDF bar", 17, [MonknotWorkspaceIcons.sidebarLeft, "arrow.uturn.backward", "arrow.uturn.forward", "highlighter",
                         "underline", "strikethrough", "character.textbox", "textformat", "ellipsis",
                         MonknotWorkspaceIcons.save]),
        ("PDF modes", 16, ["cursorarrow", "highlighter", "pencil.tip", "eraser"]),
        ("PDF navigator", 16, ["rectangle.stack", MonknotWorkspaceIcons.outline, "note.text"]),
        ("Text Style", 16, ["bold", "italic", "text.alignleft", "text.aligncenter", "text.alignright"]),
        ("panel headers", 17, ["xmark", "arrow.clockwise"]),
        ("format bar and link card", 17, MarkdownEditorSymbolAssets.toolSymbols),
        ("small buttons", 13, ["textformat", "character.cursor.ibeam", "chevron.up", "chevron.down", "xmark",
                               "minus", "plus", "doc.on.doc", "checkmark", "magnifyingglass"]),
        ("menus", 15, MonknotMenuCommand.allCases.map(\.systemImage) + MarkdownEditorSymbolAssets.menuSymbols),
        ("file glyphs", 15, WorkspaceFileGlyph.allCases.map(\.systemImage)
            + ["folder", "folder.fill", MonknotWorkspaceIcons.newFolder, MonknotWorkspaceIcons.settings,
               MonknotWorkspaceIcons.terminal, MonknotWorkspaceIcons.dragItems]),
        ("Settings", 15, ["gearshape", "circle.lefthalf.filled", "text.alignleft", "square.and.arrow.up", "keyboard", "folder"]),
    ]


    private func existing(_ names: [String]) -> [String] {
        // Preview's "Remove link" names a symbol that does not exist and falls back to `xmark`.
        Array(Set(names)).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }.sorted()
    }

    // MARK: - The rule, as measured

    /// design.md §8.2: every glyph in a place but lettering is drawn within 8 % of the place's target,
    /// so its stroke is its neighbours'. A glyph its longest side would push below the band is the
    /// wrong glyph for the set.
    func testEveryGlyphInAPlaceIsDrawnOnThePlacesStroke() {
        for place in Self.places {
            let target = MonknotSymbolOptics.targetOpticalSize(nominal: place.nominal)
            for name in existing(place.glyphs) where MonknotSymbolOptics.role(for: name) != .lettering {
                let size = MonknotSymbolOptics.pointSizeBase(for: name, nominal: place.nominal)
                XCTAssertGreaterThanOrEqual(size, target * MonknotSymbolOptics.strokeBand.lowerBound - 0.001,
                                            "\(name) in the \(place.name) is drawn at \(size), a lighter stroke than the target \(target)")
                XCTAssertLessThanOrEqual(size, target * MonknotSymbolOptics.strokeBand.upperBound + 0.001,
                                         "\(name) in the \(place.name) is drawn at \(size), a heavier stroke than the target \(target)")
            }
        }
    }

    /// Every picture in a place reads at the place's optical size, within half a point. The exception
    /// is a picture the stroke band stops: a narrow one (a cursor, a bookmark, a list of lines), whose
    /// long side by then already spans the target, so it reads as tall as its neighbours, or a stack of
    /// pages that would need a lighter stroke to shrink further.
    func testEveryPictureMeetsItsPlacesOpticalSize() throws {
        var met = 0, held = 0
        for place in Self.places {
            let target = MonknotSymbolOptics.targetOpticalSize(nominal: place.nominal)
            for name in existing(place.glyphs) where MonknotSymbolOptics.role(for: name) == .picture {
                let metrics = try XCTUnwrap(SymbolInkMetrics.metrics(for: name), "\(name) was not measured")
                let size = MonknotSymbolOptics.pointSizeBase(for: name, nominal: place.nominal)
                let optical = metrics.opticalSizePerPoint * size
                if abs(optical - target) <= 0.5 {
                    met += 1
                    continue
                }
                held += 1
                let band = optical < target ? MonknotSymbolOptics.strokeBand.upperBound : MonknotSymbolOptics.strokeBand.lowerBound
                XCTAssertEqual(size, target * band, accuracy: 0.01,
                               "\(name) in the \(place.name) reads \(optical), not \(target)")
                if optical < target {
                    XCTAssertGreaterThanOrEqual(metrics.longestSidePerPoint * size, target,
                                                "\(name) in the \(place.name) reads \(optical) and is too small to span \(target)")
                }
            }
        }
        XCTAssertGreaterThan(met, held * 4, "Most pictures meet the target; the band holds only the narrow few")
    }

    /// Marks are drawn at the target, lettering at the nominal, and nothing draws longer than its
    /// place allows.
    func testMarksAndLetteringAndTheLongestSide() throws {
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "plus", nominal: 17), 14.5)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "xmark", nominal: 13), 11.7, accuracy: 0.001)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "arrow.left", nominal: 17), 14.5)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "bold", nominal: 17), 17)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "underline", nominal: 17), 17)
        XCTAssertEqual(MonknotSymbolOptics.role(for: "textformat"), .mark)
        XCTAssertEqual(MonknotSymbolOptics.role(for: "pencil"), .picture)
        for place in Self.places {
            for name in existing(place.glyphs) {
                let metrics = try XCTUnwrap(SymbolInkMetrics.metrics(for: name))
                let size = MonknotSymbolOptics.pointSizeBase(for: name, nominal: place.nominal)
                XCTAssertLessThanOrEqual(metrics.longestSidePerPoint * size, MonknotSymbolOptics.longestSide(nominal: place.nominal) + 0.01,
                                         "\(name) spills out of the \(place.name)")
            }
        }
    }

    func testAnUnknownSymbolIsDrawnAtTheTarget() {
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "not.a.real.symbol.name", nominal: 15), 13.5)
    }

    /// The pair the eye caught: search read bigger than New Markdown beside it, because New
    /// Markdown's pencil pokes out of its square and the old measure counted it whole. Measured by its
    /// square, New Markdown is now set a little larger, and the two read as one size.
    func testSearchAndNewMarkdownReadAsOneSize() throws {
        let search = try XCTUnwrap(SymbolInkMetrics.metrics(for: MonknotWorkspaceIcons.searchWorkspace))
        let compose = try XCTUnwrap(SymbolInkMetrics.metrics(for: MonknotWorkspaceIcons.newMarkdown))
        XCTAssertLessThan(compose.baseHeightPerPoint, compose.heightPerPoint * 0.95, "The square is the base the pencil sits on")
        let searchSize = MonknotSymbolOptics.pointSizeBase(for: MonknotWorkspaceIcons.searchWorkspace, nominal: 17)
        let composeSize = MonknotSymbolOptics.pointSizeBase(for: MonknotWorkspaceIcons.newMarkdown, nominal: 17)
        XCTAssertGreaterThan(composeSize, searchSize)
        XCTAssertEqual(search.opticalSizePerPoint * searchSize, compose.opticalSizePerPoint * composeSize, accuracy: 0.3)
    }

    // MARK: - What renders

    /// Renders every picture of every place through `MonknotSystemGlyph`, as the app draws it, at zoom
    /// 0.8, 1 and 2, measures the ink it draws, and checks that the pictures in each
    /// place read at one optical size and that each glyph's ink is centred in its box.
    func testRenderedGlyphsReadAsOneSizeAndSitCentred() throws {
        // A glyph's size depends on the zoom alone, and it is drawn in black whatever the theme.
        let theme = AppTheme.defaultLight
        for zoom in [0.8, 1.0, 2.0] {
            for place in Self.places {
                let target = MonknotSymbolOptics.targetOpticalSize(nominal: place.nominal)
                let glyphScale = MonknotMetrics.interfaceGlyph(100, theme: theme, zoomScale: zoom) / 100
                for name in existing(place.glyphs) {
                    let rendered = try XCTUnwrap(RenderedGlyph(name, nominal: place.nominal, theme: theme, zoomScale: zoom),
                                                 "\(name) drew nothing")
                    let metrics = try XCTUnwrap(SymbolInkMetrics.metrics(for: name))
                    // What it draws is what the measure promised, to a pixel at 2×.
                    let pointSize = MonknotMetrics.interfaceGlyph(
                        MonknotSymbolOptics.pointSizeBase(for: name, nominal: place.nominal), theme: theme, zoomScale: zoom)
                    // SF Symbols draw a touch tighter at display sizes, so the measure, taken at 100 pt,
                    // holds to 3 % past a pixel.
                    let tolerance = max(0.6, pointSize * 0.03)
                    XCTAssertEqual(rendered.ink.width, metrics.widthPerPoint * pointSize, accuracy: tolerance,
                                   "\(name) in the \(place.name) at \(zoom)")
                    XCTAssertEqual(rendered.ink.height, metrics.heightPerPoint * pointSize, accuracy: tolerance,
                                   "\(name) in the \(place.name) at \(zoom)")
                    if MonknotSymbolOptics.role(for: name) == .picture {
                        // Measured on what rendered: the drawn box, and the base's share of it.
                        let base = sqrt(metrics.baseWidthPerPoint * metrics.baseHeightPerPoint)
                            / sqrt(metrics.widthPerPoint * metrics.heightPerPoint)
                        let optical = sqrt(rendered.ink.width * rendered.ink.height) * sqrt(base)
                            * pow(max(metrics.inkCoverage, 0.05) / 0.33, 0.06)
                        let spansTarget = max(rendered.ink.width, rendered.ink.height) >= target * glyphScale - 0.5
                        XCTAssertTrue(abs(optical - target * glyphScale) <= 0.6 * max(1, glyphScale) || spansTarget,
                                      "\(name) in the \(place.name) at \(zoom) reads \(optical), not \(target * glyphScale)")
                    }
                    // Its ink sits where SF Symbols centres it: no glyph is pushed off its column.
                    XCTAssertEqual(rendered.ink.midX, rendered.box.midX + rendered.symbolInkOffset.x, accuracy: 0.35,
                                   "\(name) in the \(place.name) at \(zoom) sits off its column")
                    XCTAssertEqual(rendered.ink.midY, rendered.box.midY + rendered.symbolInkOffset.y, accuracy: 0.35,
                                   "\(name) in the \(place.name) at \(zoom) sits off its row")
                }
            }
        }
    }

    /// Secondary marks (design.md §6) are semibold so their stroke is a row glyph's: a 10 pt semibold
    /// stroke against a 13.5 pt regular one, measured on a `minus`.
    func testSecondaryMarksDrawTheRowsStroke() throws {
        func stroke(_ weight: Font.Weight, _ size: CGFloat) throws -> CGFloat {
            let view = Image(systemName: "minus").font(.system(size: size, weight: weight)).foregroundStyle(.black)
                .frame(width: 40, height: 40)
            return try XCTUnwrap(RenderedGlyph.inkBox(of: view, size: CGSize(width: 40, height: 40))).height
        }
        let secondary = try stroke(MonknotMetrics.secondaryGlyphWeight, MonknotMetrics.chevronPointSizeBase)
        let row = try stroke(.regular, MonknotSymbolOptics.targetOpticalSize(nominal: MonknotMetrics.sidebarIconPointSizeBase))
        XCTAssertEqual(secondary / row, 1, accuracy: 0.1, "secondary \(secondary), row \(row)")
        XCTAssertEqual(MonknotMenuRowCheck.pointSizeBase, MonknotMetrics.chevronPointSizeBase)
    }

    // MARK: - The glyphs themselves

    /// Back and Forward are arrows with a shaft, drawn as marks at the bar's target, so they carry the
    /// titlebar's stroke.
    func testBackAndForwardAreArrowsDrawnAsMarks() {
        XCTAssertEqual(MonknotWorkspaceIcons.back, "arrow.left")
        XCTAssertEqual(MonknotWorkspaceIcons.forward, "arrow.right")
        for name in [MonknotWorkspaceIcons.back, MonknotWorkspaceIcons.forward] {
            XCTAssertEqual(MonknotSymbolOptics.role(for: name), .mark)
            XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: name, nominal: MonknotMetrics.iconPointSizeBase), 14.5)
        }
    }

    /// Rename's glyph is a letter with the text cursor: not the pencil New File draws, and unlike any
    /// other glyph in the menus it appears in.
    func testRenameHasItsOwnGlyph() {
        let rename = MonknotMenuCommand.rename.systemImage
        XCTAssertEqual(rename, MonknotWorkspaceIcons.rename)
        XCTAssertNotNil(NSImage(systemSymbolName: rename, accessibilityDescription: nil))
        let others = MonknotMenuCommand.allCases.filter { $0 != .rename }.map(\.systemImage)
        XCTAssertFalse(others.contains(rename))
        XCTAssertFalse(rename.contains("pencil"))
    }

    /// Save in the PDF bar is an outline picture on the bar's stroke, not a drive with a filled badge.
    func testSaveIsAnOutlinePictureOnTheBarsStroke() {
        XCTAssertFalse(MonknotWorkspaceIcons.save.contains("fill"))
        XCTAssertFalse(MonknotWorkspaceIcons.save.contains("badge"))
        XCTAssertNotNil(NSImage(systemSymbolName: MonknotWorkspaceIcons.save, accessibilityDescription: nil))
    }
}

/// A glyph as SwiftUI draws it: `MonknotSystemGlyph` in a box the size of a bar button, rendered at
/// 4× with its ink measured.
@MainActor
struct RenderedGlyph {
    /// The ink, in points, in the box's coordinates (y down).
    let ink: CGRect
    let box: CGRect
    /// Where SF Symbols puts the ink's centre relative to the symbol's own image box, at this size.
    let symbolInkOffset: CGPoint

    init?(_ name: String, nominal: CGFloat, theme: AppTheme, zoomScale: Double) {
        let side = (MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale) + 8).rounded()
        let size = CGSize(width: side, height: side)
        let view = MonknotSystemGlyph(systemImage: name, nominalPointSizeBase: nominal, theme: theme, zoomScale: zoomScale)
            .foregroundStyle(Color.black)
            .frame(width: side, height: side)
        guard let ink = Self.inkBox(of: view, size: size) else { return nil }
        self.ink = ink
        self.box = CGRect(origin: .zero, size: size)
        let pointSize = MonknotMetrics.interfaceGlyph(
            MonknotSymbolOptics.pointSizeBase(for: name, nominal: nominal), theme: theme, zoomScale: zoomScale)
        self.symbolInkOffset = Self.imageInkOffset(name, pointSize: pointSize)
    }

    static let scale: CGFloat = 4

    static func inkBox<Content: View>(of view: Content, size: CGSize) -> CGRect? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.bitmapData else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let samples = bitmap.samplesPerPixel
        let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samples - 1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = data[y * bitmap.bytesPerRow + x * samples + alphaIndex]
                if alpha > 20 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX else { return nil }
        let pixelScale = CGFloat(bitmap.pixelsWide) / size.width
        return CGRect(x: CGFloat(minX) / pixelScale, y: CGFloat(minY) / pixelScale,
                      width: CGFloat(maxX - minX + 1) / pixelScale, height: CGFloat(maxY - minY + 1) / pixelScale)
    }

    /// Where SF Symbols itself places a glyph's ink, from the centre of its layout box, in points (y
    /// down). Across, a symbol is laid out by its alignment rect, so a badged folder sits on the column
    /// by its folder and the badge hangs outside; down, by its image, so `square.and.pencil`'s square
    /// sits a little low under the pencil. Measured once at 100 pt, centred on a 200 pt canvas, scaled.
    static func imageInkOffset(_ name: String, pointSize: CGFloat) -> CGPoint {
        let reference: CGFloat = 100
        let canvas = 200
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: reference, weight: .regular)),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let data = bitmap.bitmapData
        else { return .zero }
        let size = symbol.size
        let origin = CGPoint(x: (CGFloat(canvas) - size.width) / 2, y: (CGFloat(canvas) - size.height) / 2)
        let alignment = symbol.alignmentRect
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<canvas {
            for x in 0..<canvas where data[y * bitmap.bytesPerRow + x * 4 + 3] > 20 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        // The alignment rect is in the image's coordinates; the bitmap's first row is the top, and the
        // image's centre sits on the canvas's centre either way.
        let alignmentCentre = CGPoint(x: origin.x + alignment.midX, y: CGFloat(canvas) / 2)
        return CGPoint(
            x: (CGFloat(minX + maxX + 1) / 2 - alignmentCentre.x) * pointSize / reference,
            y: (CGFloat(minY + maxY + 1) / 2 - alignmentCentre.y) * pointSize / reference
        )
    }
}
