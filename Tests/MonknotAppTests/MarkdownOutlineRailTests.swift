import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// The outline rail and its panel (design.md §10.5): the rail stays a bounded column whose every
/// heading can be pointed at, the panel is bounded and scrolls with its highlighted heading kept in
/// view, the panel opens only once the pointer stays on the rail, and neither takes the document's
/// clicks outside what it draws.
@MainActor
final class MarkdownOutlineRailTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        try await super.tearDown()
    }

    // MARK: - The rail

    func testTheRailKeepsEveryHeadingInABoundedColumn() {
        let theme = AppTheme.defaultLight
        // A short outline takes a 12 slot per heading.
        let short = MarkdownOutlineRailLayout.rail(count: 9, availableHeight: 700, theme: theme, zoomScale: 1)
        XCTAssertEqual(short.pitch, 12)
        XCTAssertEqual(short.height, 108)
        XCTAssertEqual(short.markThickness, 2)

        // A long one shrinks its slots to stay 380 tall, though the card has room for more.
        let long = MarkdownOutlineRailLayout.rail(count: 48, availableHeight: 700, theme: theme, zoomScale: 1)
        XCTAssertEqual(long.height, 380, accuracy: 0.001)
        XCTAssertEqual(long.pitch, 380.0 / 48, accuracy: 0.001)

        // Past 95 headings the slots stay 4 and the rail grows, up to the card less its margins.
        let longer = MarkdownOutlineRailLayout.rail(count: 120, availableHeight: 700, theme: theme, zoomScale: 1)
        XCTAssertEqual(longer.pitch, 4)
        XCTAssertEqual(longer.height, 480)
        let longest = MarkdownOutlineRailLayout.rail(count: 400, availableHeight: 700, theme: theme, zoomScale: 1)
        XCTAssertEqual(longest.height, 676, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(longest.markThickness, 1)

        // Zoom scales every number, and the rail never leaves the card's margins.
        for zoom in [0.8, 1, 2] {
            let margin = MonknotMetrics.interfaceDensity(12, theme: theme, zoomScale: zoom)
            for count in [2, 9, 31, 48, 95, 120, 400] {
                for height in [240.0, 520, 900] {
                    let rail = MarkdownOutlineRailLayout.rail(count: count, availableHeight: height, theme: theme, zoomScale: zoom)
                    XCTAssertLessThanOrEqual(rail.height, height - 2 * margin + 0.001, "\(count) headings at \(zoom)× in \(height)")
                    XCTAssertLessThanOrEqual(rail.pitch, MonknotMetrics.interfaceDensity(12, theme: theme, zoomScale: zoom))
                    // Every heading has a slot the pointer can find.
                    for index in [0, count / 2, count - 1] {
                        let y = (CGFloat(index) + 0.5) * rail.pitch
                        XCTAssertEqual(rail.index(atY: y), index, "\(count) headings at \(zoom)× in \(height)")
                    }
                }
            }
        }
        XCTAssertEqual(MarkdownOutlineRailLayout.rail(count: 48, availableHeight: 900, theme: theme, zoomScale: 2).pitch, 760.0 / 48, accuracy: 0.001)
        XCTAssertEqual(MarkdownOutlineRailLayout.rail(count: 9, availableHeight: 900, theme: theme, zoomScale: 0.8).pitch, 10)
    }

    func testThePointerFindsTheHeadingUnderItAtTheRailsEnds() {
        let rail = MarkdownOutlineRailLayout.rail(count: 10, availableHeight: 700, theme: .defaultLight, zoomScale: 1)
        XCTAssertEqual(rail.index(atY: -3), 0)
        XCTAssertEqual(rail.index(atY: 0), 0)
        XCTAssertEqual(rail.index(atY: 11.9), 0)
        XCTAssertEqual(rail.index(atY: 12), 1)
        XCTAssertEqual(rail.index(atY: rail.height), 9)
        XCTAssertNil(MarkdownOutlineRailLayout.Rail(pitch: 0, count: 0, markThickness: 2).index(atY: 4))
    }

    // MARK: - The panel's size

    func testThePanelIsBoundedAndScrollsPastIt() {
        let theme = AppTheme.defaultDark
        // As tall as its rows: 30 each, 1 apart, in the 6 inset.
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 5, availableHeight: 700, theme: theme, zoomScale: 1), 166)
        // A long outline stops at 380 and scrolls.
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 60, availableHeight: 700, theme: theme, zoomScale: 1), 380)
        XCTAssertGreaterThan(MarkdownOutlineRailLayout.panelContentHeight(rowCount: 60, theme: theme, zoomScale: 1), 380)
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 60, availableHeight: 700, theme: theme, zoomScale: 0.8), 304)
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 60, availableHeight: 1_000, theme: theme, zoomScale: 2), 760)
        // A short card keeps it 12 clear of its top and bottom.
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 60, availableHeight: 300, theme: theme, zoomScale: 1), 276)
        XCTAssertEqual(MarkdownOutlineRailLayout.panelHeight(rowCount: 60, availableHeight: 700, theme: theme, zoomScale: 2), 652)
        // Rows sit where the panel draws them.
        XCTAssertEqual(MarkdownOutlineRailLayout.panelRowSpan(index: 0, theme: theme, zoomScale: 1), 6...36)
        XCTAssertEqual(MarkdownOutlineRailLayout.panelRowSpan(index: 2, theme: theme, zoomScale: 1), 68...98)
    }

    func testThePanelWidthFollowsItsLongestTitleBetweenAMenusBounds() {
        let theme = AppTheme.defaultLight
        func width(_ titles: [String], levels: [Int]? = nil, available: CGFloat = 1_000, zoom: Double = 1) -> CGFloat {
            let items = titles.enumerated().map { index, title in
                MarkdownOutlineItem(id: "\(index)", title: title, level: levels?[index] ?? 2, location: .init(line: index + 1, offset: 0))
            }
            let outline = MarkdownOutlineRailOutline(items: items, theme: theme, zoomScale: zoom)
            return MarkdownOutlineRailLayout.panelWidth(widestRow: outline.widestRow, availableWidth: available, theme: theme, zoomScale: zoom)
        }
        XCTAssertEqual(width(["Goals", "Scope"]), 232)
        let longer = width(["Goals", "Accepting part of a suggestion, a word at a time"])
        XCTAssertGreaterThan(longer, 232)
        XCTAssertLessThanOrEqual(longer, 320)
        // A deeper heading needs its indent too.
        XCTAssertGreaterThan(
            width(["Title", "Accepting part of a suggestion"], levels: [1, 4]),
            width(["Title", "Accepting part of a suggestion"], levels: [1, 2])
        )
        XCTAssertEqual(width([String(repeating: "A very long heading ", count: 8)]), 320)
        XCTAssertEqual(width([String(repeating: "A very long heading ", count: 8)], zoom: 2), 640)
        XCTAssertEqual(width(["Goals"], zoom: 0.8), MonknotMetrics.interfaceDensity(232, theme: theme, zoomScale: 0.8))
        // A narrow card keeps the panel inside it, clear of its edge.
        XCTAssertEqual(width([String(repeating: "A very long heading ", count: 8)], available: 300), 300 - 10 - 38 - 8 - 12)
    }

    /// The width the panel works out fits its longest row as the menu row really lays it out, at
    /// every zoom, so a title that could fit is never cut short.
    func testThePanelFitsItsLongestTitleAsTheRowLaysItOut() {
        for zoom in [0.8, 1, 1.25, 2] {
            for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
                for (title, level) in [("Heading 4 about part of the plan", 3), ("Accepting part of a suggestion", 4), ("Goals", 2)] {
                    let items = [
                        MarkdownOutlineItem(id: "t", title: "Title", level: 1, location: .init(line: 1, offset: 0)),
                        MarkdownOutlineItem(id: "h", title: title, level: level, location: .init(line: 3, offset: 10)),
                    ]
                    let outline = MarkdownOutlineRailOutline(items: items, theme: theme, zoomScale: zoom)
                    let width = MarkdownOutlineRailLayout.panelWidth(widestRow: outline.widestRow, availableWidth: 2_000, theme: theme, zoomScale: zoom)
                    let row = NSHostingView(rootView: MonknotMenuRowLabel(
                        leading: .none,
                        title: title,
                        indentBase: MarkdownOutlineRailLayout.leadingIndentBase(forDepth: outline.depths[1]),
                        theme: theme,
                        zoomScale: zoom
                    ) {
                        Capsule().frame(width: MonknotMetrics.interfaceDensity(12, theme: theme, zoomScale: zoom), height: 2)
                    }.fixedSize())
                    let inset = MonknotMetrics.interfaceDensity(MonknotMetrics.menuListInsetBase, theme: theme, zoomScale: zoom)
                    XCTAssertLessThanOrEqual(row.fittingSize.width, width - 2 * inset + 0.5, "\(title) at \(zoom)×")
                }
            }
        }
    }

    // MARK: - Scrolling

    func testOpeningCentresTheHeadingAndScrubbingScrollsTheLeast() {
        func offset(_ row: ClosedRange<CGFloat>, from current: CGFloat, centred: Bool = false) -> CGFloat {
            MarkdownOutlineRailLayout.scrollOffset(
                revealing: row,
                from: current,
                viewportHeight: 380,
                contentHeight: 1_871,
                margin: 6,
                centred: centred
            )
        }
        // Opening centres it.
        XCTAssertEqual(offset(1_246...1_276, from: 0, centred: true), 1_071)
        // Near the ends the list cannot centre it, and stops at its ends.
        XCTAssertEqual(offset(6...36, from: 500, centred: true), 0)
        XCTAssertEqual(offset(1_835...1_865, from: 0, centred: true), 1_491)
        // A row already in view leaves the list where it is.
        XCTAssertEqual(offset(600...630, from: 500), 500)
        // Below the view: just enough to show it 6 clear of the bottom.
        XCTAssertEqual(offset(900...930, from: 500), 556)
        // Above it: 6 clear of the top.
        XCTAssertEqual(offset(400...430, from: 500), 394)
        // The first row shows the list's inset above it.
        XCTAssertEqual(offset(6...36, from: 300), 0)
    }

    /// The panel itself, hosted: it opens with the highlighted heading centred, then each heading
    /// the rail moves to is brought into view with the least scroll, and the first row the list
    /// shows is never at its top before that.
    func testThePanelKeepsTheHighlightedHeadingInView() async throws {
        let theme = AppTheme.defaultLight
        let items = Self.headings(60)
        let outline = MarkdownOutlineRailOutline(items: items, theme: theme, zoomScale: 1)
        let height = MarkdownOutlineRailLayout.panelHeight(rowCount: items.count, availableHeight: 800, theme: theme, zoomScale: 1)
        XCTAssertEqual(height, 380)
        let state = PanelState(reveal: .init(id: items[40].id, centred: true, serial: 1))
        let host = NSHostingView(rootView: PanelHarness(state: state, outline: outline, height: height, theme: theme))
        let window = makeWindow(host, size: NSSize(width: 320, height: 440))

        let scrollView = try await waitForScrollView(in: host)
        func span(_ index: Int) -> ClosedRange<CGFloat> {
            MarkdownOutlineRailLayout.panelRowSpan(index: index, theme: theme, zoomScale: 1)
        }
        func visible() -> ClosedRange<CGFloat>? {
            guard let document = scrollView.documentView else { return nil }
            let clip = scrollView.contentView
            let top = document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY
            return top...(top + clip.bounds.height)
        }

        var centred = await waitUntil { visible().map { $0.contains(span(40).lowerBound) && $0.contains(span(40).upperBound) } ?? false }
        XCTAssertTrue(centred, "The panel opens on its highlighted heading, not its top")
        let opened = try XCTUnwrap(visible())
        XCTAssertEqual((opened.lowerBound + opened.upperBound) / 2, (span(40).lowerBound + span(40).upperBound) / 2, accuracy: 1)
        XCTAssertEqual(opened.upperBound - opened.lowerBound, 380, accuracy: 0.5)

        // Down the rail past the bottom: the least scroll, 6 clear.
        state.reveal = .init(id: items[50].id, centred: false, serial: 2)
        centred = await waitUntil { visible().map { abs($0.upperBound - (span(50).upperBound + 6)) < 1 } ?? false }
        XCTAssertTrue(centred, "Row 50 ends 6 above the panel's bottom: \(String(describing: visible()))")

        // A heading already in view leaves the list still.
        let before = try XCTUnwrap(visible())
        state.reveal = .init(id: items[47].id, centred: false, serial: 3)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try XCTUnwrap(visible()).lowerBound, before.lowerBound, accuracy: 0.5)

        // Back up past the top.
        state.reveal = .init(id: items[5].id, centred: false, serial: 4)
        centred = await waitUntil { visible().map { abs($0.lowerBound - (span(5).lowerBound - 6)) < 1 } ?? false }
        XCTAssertTrue(centred, "Row 5 starts 6 below the panel's top: \(String(describing: visible()))")
        _ = window
    }

    // MARK: - When it opens

    func testThePanelOpensOnlyOnceThePointerStaysOnTheRail() async {
        let peek = makePeek()
        peek.pointerOnRail("b")
        XCTAssertEqual(peek.highlightedID, "b", "The mark answers the pointer at once")
        XCTAssertFalse(peek.isOpen)
        XCTAssertNil(peek.reveal)
        let opened = await waitUntil { peek.isOpen }
        XCTAssertTrue(opened)
        XCTAssertFalse(peek.openedFromKeyboard)
        XCTAssertEqual(peek.reveal?.id, "b")
        XCTAssertEqual(peek.reveal?.centred, true)
    }

    func testCrossingTheRailOpensNothing() async throws {
        let peek = makePeek()
        peek.pointerOnRail("b")
        peek.pointerOnRail(nil)
        XCTAssertNil(peek.highlightedID, "Leaving puts the mark back at once")
        try await Task.sleep(nanoseconds: UInt64((peek.openDelay + 0.15) * 1_000_000_000))
        XCTAssertFalse(peek.isOpen)
    }

    func testTheTripFromTheRailToThePanelKeepsItOpenAndRowsTakeTheHighlight() async throws {
        let peek = makePeek()
        peek.pointerOnRail("b")
        _ = await waitUntil { peek.isOpen }
        // The rail moves the highlight and asks for it to be kept in view.
        peek.pointerOnRail("c")
        XCTAssertEqual(peek.highlightedID, "c")
        XCTAssertEqual(peek.reveal?.id, "c")
        XCTAssertEqual(peek.reveal?.centred, false)
        let serial = try XCTUnwrap(peek.reveal?.serial)

        // Off the rail and onto the panel, in either order: still open, the highlight unchanged.
        peek.pointerOnRail(nil)
        peek.pointerOnPanel(true)
        try await Task.sleep(nanoseconds: UInt64((peek.closeGrace + 0.15) * 1_000_000_000))
        XCTAssertTrue(peek.isOpen)
        XCTAssertEqual(peek.highlightedID, "c")

        // The pointer's row takes the highlight and the list stays where it is.
        peek.pointerOnRow("e")
        XCTAssertEqual(peek.highlightedID, "e")
        XCTAssertEqual(peek.reveal?.serial, serial)

        // Back to the rail and out again in a moment: the grace keeps it.
        peek.pointerOnPanel(false)
        peek.pointerOnRail("a")
        XCTAssertEqual(peek.reveal?.id, "a")
        try await Task.sleep(nanoseconds: UInt64((peek.closeGrace + 0.15) * 1_000_000_000))
        XCTAssertTrue(peek.isOpen)

        // Leaving both closes it and lets the highlight go.
        peek.pointerOnRail(nil)
        let closed = await waitUntil { !peek.isOpen }
        XCTAssertTrue(closed)
        XCTAssertNil(peek.highlightedID)
        XCTAssertNil(peek.reveal)
    }

    func testKeyboardFocusOnAMarkOpensThePanelAtOnce() async {
        let peek = makePeek()
        peek.focus("d")
        XCTAssertTrue(peek.isOpen, "From the keys it shows at once")
        XCTAssertTrue(peek.openedFromKeyboard)
        XCTAssertEqual(peek.highlightedID, "d")
        XCTAssertEqual(peek.reveal?.centred, true)
        peek.focus("e")
        XCTAssertEqual(peek.highlightedID, "e")
        XCTAssertEqual(peek.reveal?.id, "e")
        XCTAssertEqual(peek.reveal?.centred, false)
        peek.focus(nil)
        let closed = await waitUntil { !peek.isOpen }
        XCTAssertTrue(closed)
    }

    // MARK: - The document keeps its clicks

    /// The rail covers the card to centre itself, but only its marks and an open panel take the
    /// pointer: a click beside, above or below them reaches the document under it.
    func testTheRailLeavesTheDocumentItsClicks() async throws {
        let theme = AppTheme.defaultLight
        let items = Self.headings(9)
        let document = ClickTarget()
        let host = NSHostingView(rootView: ZStack(alignment: .trailing) {
            ClickTargetView(view: document)
            MarkdownOutlineRail(
                documentID: "/doc.md",
                items: items,
                position: MarkdownOutlinePosition(),
                theme: theme,
                zoomScale: 1,
                select: { _ in }
            )
        }
        .frame(width: 800, height: 600))
        let window = makeWindow(host, size: NSSize(width: 800, height: 600))
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()

        func hit(_ x: CGFloat, _ yFromTop: CGFloat) -> NSView? {
            let point = NSPoint(x: x, y: host.isFlipped ? yFromTop : 600 - yFromTop)
            return host.hitTest(host.convert(point, to: host.superview))
        }
        func isDocument(_ view: NSView?) -> Bool {
            view.map { $0 === document || $0.isDescendant(of: document) } ?? false
        }
        // The rail: 108 tall, centred, its marks' trailing edge 10 from the right.
        let railX: CGFloat = 800 - 10 - 19
        XCTAssertFalse(isDocument(hit(railX, 300)), "A mark takes its own click")
        XCTAssertTrue(isDocument(hit(400, 300)), "The document beside the rail keeps its clicks")
        XCTAssertTrue(isDocument(hit(railX, 60)), "Above the rail is the document's")
        XCTAssertTrue(isDocument(hit(railX, 560)), "Below the rail is the document's")
        XCTAssertTrue(isDocument(hit(railX - 200, 300)), "Where the panel opens is the document's while it is closed")
        _ = window
    }

    // MARK: - Snapshots

    /// With `MONKNOT_OUTLINE_SNAPSHOT_DIR` set, captures the rail at rest and with its panel open on
    /// a long outline, over a card, light and dark, at zoom 0.8, 1 and 2.
    func testCaptureTheOutlineRailAndPanel() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_OUTLINE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_OUTLINE_SNAPSHOT_DIR to capture the outline rail and its panel")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let themes = [
            ("light", AppTheme.defaultLight), ("dark", AppTheme.defaultDark),
            ("latte", Self.theme("catppuccin-latte")), ("mocha", Self.theme("catppuccin-mocha")),
        ]
        for (themeName, theme) in themes {
            for zoom in [0.8, 1.0, 2.0] {
                let size = NSSize(width: 520 * zoom, height: 720 * zoom)
                for (variant, count, focused) in [("rest-short", 9, nil), ("rest-long", 48, nil), ("open-long", 48, 30), ("open-short", 9, 4)] as [(String, Int, Int?)] {
                    let items = Self.headings(count)
                    let position = MarkdownOutlinePosition()
                    position.update(items[min(count - 1, 6)].location.line, documentID: "/doc.md")
                    let peek = MarkdownOutlinePeek()
                    let host = NSHostingView(rootView: ZStack(alignment: .trailing) {
                        theme.surfaceColor
                        MarkdownOutlineRail(
                            documentID: "/doc.md",
                            items: items,
                            position: position,
                            theme: theme,
                            zoomScale: zoom,
                            peek: peek,
                            select: { _ in }
                        )
                    }
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, theme.isDark ? .dark : .light))
                    let window = makeWindow(host, size: size)
                    window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    if let focused {
                        peek.focus(items[focused].id)
                    }
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try capture(window, host: host, to: directory.appendingPathComponent("outline-\(themeName)-\(zoom)x-\(variant).png"))
                    peek.close(animated: false)
                    window.orderOut(nil)
                }
            }
        }
    }

    /// With `MONKNOT_OUTLINE_SNAPSHOT_DIR` set, records the panel opening from the pointer and
    /// closing, as often as the window server allows, and writes each frame's time and the panel's
    /// drawn width and ink beside the frames (`frames.txt`): it should grow in over about 150 ms and
    /// fade out over about 90 ms, with the rail still throughout.
    func testCaptureThePanelOpeningAndClosingFrameByFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONKNOT_OUTLINE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MONKNOT_OUTLINE_SNAPSHOT_DIR to record the outline panel's motion")
        }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("motion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let theme = AppTheme.defaultDark
        let items = Self.headings(48)
        let peek = MarkdownOutlinePeek()
        peek.openDelay = 0
        let size = NSSize(width: 520, height: 720)
        let host = NSHostingView(rootView: ZStack(alignment: .trailing) {
            theme.surfaceColor
            MarkdownOutlineRail(
                documentID: "/doc.md",
                items: items,
                position: MarkdownOutlinePosition(),
                theme: theme,
                zoomScale: 1,
                peek: peek,
                select: { _ in }
            )
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark))
        let window = makeWindow(host, size: size)
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(nanoseconds: 300_000_000)

        var log: [String] = []
        func record(_ phase: String, for duration: TimeInterval) async throws {
            let start = Date()
            var index = 0
            while Date().timeIntervalSince(start) < duration {
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { break }
                let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
                let (width, ink) = Self.panelMeasure(image)
                log.append("\(phase) \(milliseconds) ms: panel \(width) px wide, ink \(String(format: "%.1f", ink))")
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(phase)-\(String(format: "%02d", index))-\(milliseconds)ms.png"))
                index += 1
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        peek.pointerOnRail(items[20].id)
        try await record("open", for: 0.3)
        peek.pointerOnRail(nil)
        try await record("close", for: 0.3)
        try log.joined(separator: "\n").write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        _ = window
    }

    /// The panel's drawn width along the window's middle row, and its mean ink there, left of the
    /// rail: what changes as it grows in and fades.
    private static func panelMeasure(_ image: CGImage) -> (Int, Double) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0) }
        let row = image.height / 2
        let background = Int(bytes[row * image.bytesPerRow + 4 * 4])
        var first: Int?
        var last = 0
        var sum = 0
        let end = image.width - Int(Double(image.width) * 0.12)
        for x in 0..<end {
            let offset = row * image.bytesPerRow + x * 4
            let value = Int(bytes[offset + 1])
            sum += abs(value - background)
            if abs(value - background) > 6 {
                first = first ?? x
                last = x
            }
        }
        return (first.map { last - $0 } ?? 0, Double(sum) / Double(max(1, end)))
    }

    // MARK: - Helpers

    private func makePeek() -> MarkdownOutlinePeek {
        let peek = MarkdownOutlinePeek()
        peek.openDelay = 0.05
        peek.closeGrace = 0.05
        return peek
    }

    static func headings(_ count: Int) -> [MarkdownOutlineItem] {
        (0..<count).map { index in
            let level = index == 0 ? 1 : (index % 5 == 1 ? 2 : 3)
            return MarkdownOutlineItem(
                id: "\(index * 4 + 1)-\(level)-Heading \(index)",
                title: index == 0 ? "Offline writing assistance" : "Heading \(index) about part of the plan",
                level: level,
                location: .init(line: index * 4 + 1, offset: index * 80)
            )
        }
    }

    private static func theme(_ id: String) -> AppTheme {
        (MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets).first { $0.theme.id == id }?.theme ?? .defaultLight
    }

    private func makeWindow(_ host: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func waitForScrollView(in view: NSView) async throws -> NSScrollView {
        var found: NSScrollView?
        _ = await waitUntil {
            found = Self.descendant(of: NSScrollView.self, in: view)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private static func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = descendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// The window server's image of the window, or, where it has none (a locked screen), the
    /// window's layers drawn off screen.
    private func capture(_ window: NSWindow, host: NSView, to url: URL) throws {
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
        let rep: NSBitmapImageRep
        if let image, !Self.isBlank(image) {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            let cached = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: cached)
            rep = cached
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        var index = 0
        while index < length {
            if bytes[index] > 8 { return false }
            index += 97
        }
        return true
    }
}

@MainActor
private final class PanelState: ObservableObject {
    @Published var reveal: MarkdownOutlinePeek.Reveal?

    init(reveal: MarkdownOutlinePeek.Reveal?) {
        self.reveal = reveal
    }
}

private struct PanelHarness: View {
    @ObservedObject var state: PanelState
    let outline: MarkdownOutlineRailOutline
    let height: CGFloat
    let theme: AppTheme

    var body: some View {
        MarkdownOutlinePanel(
            outline: outline,
            currentID: outline.items[3].id,
            highlightedID: state.reveal?.id,
            reveal: state.reveal,
            size: CGSize(width: 260, height: height),
            theme: theme,
            zoomScale: 1,
            pointerOnRow: { _ in },
            select: { _ in }
        )
        .frame(width: 320, height: 440)
    }
}

private final class ClickTarget: NSView {}

private struct ClickTargetView: NSViewRepresentable {
    let view: ClickTarget

    func makeNSView(context: Context) -> ClickTarget {
        view
    }

    func updateNSView(_ nsView: ClickTarget, context: Context) {}
}
