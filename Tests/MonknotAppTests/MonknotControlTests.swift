import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

/// Renders a view and reports its most opaque pixel: the ink of a glyph or a knob at full coverage.
@MainActor
enum MonknotRenderedInk {
    static func peakAlpha<Content: View>(of view: Content) -> CGFloat? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var peak: CGFloat = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent {
                    peak = max(peak, alpha)
                }
            }
        }
        return peak
    }
}

/// The shared controls (design.md §5): one box height, one disabled look, one way to set a value.
@MainActor
final class MonknotControlTests: XCTestCase {
    private let themes = [AppTheme.defaultLight, AppTheme.defaultDark]

    private func height<Content: View>(_ view: Content) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    /// design.md §5.5, §9.3, §15: every 28 pt control is one rounding of 28 at every zoom, so a bar's
    /// controls stay one height side by side; parts rounded separately drift a point apart.
    func testEvery28PointControlMeasuresOneRoundingOf28AtEveryZoom() {
        let symbols = [
            MonknotSegmentOption(id: "source", systemImage: "text.alignleft", accessibilityLabel: "Source"),
            MonknotSegmentOption(id: "preview", systemImage: "eye", accessibilityLabel: "Preview"),
        ]
        let words = [
            MonknotSegmentOption(id: "light", title: "Light"),
            MonknotSegmentOption(id: "dark", title: "Dark"),
        ]
        let items = [MonknotPopUpItem(id: "a4", title: "A4"), MonknotPopUpItem(id: "letter", title: "US Letter")]

        for theme in themes {
            for zoom in WorkspaceZoomPolicy.supportedLevels {
                let control = MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoom)
                let measured: [(String, CGFloat)] = [
                    ("segmented", height(MonknotSegmentedControl(options: symbols, selection: .constant("source"), theme: theme, zoomScale: zoom))),
                    ("text segmented", height(MonknotSegmentedControl(options: words, selection: .constant("dark"), theme: theme, zoomScale: zoom))),
                    ("toggles", height(MonknotSegmentedControl(options: symbols, toggled: .constant([]), theme: theme, zoomScale: zoom))),
                    ("pop-up", height(MonknotPopUpButton(label: "Page size", selection: .constant("a4"), items: items, theme: theme, zoomScale: zoom))),
                    ("stepper", height(MonknotStepper(title: "Size", value: .constant(14), range: 6...144, displayValue: "14", theme: theme, zoomScale: zoom))),
                    ("field", height(TextField("Name", text: .constant("")).textFieldStyle(.plain).monknotField(isFocused: false, theme: theme, zoomScale: zoom))),
                    ("icon button", height(MonknotIconButton(systemImage: "plus", label: "Add", theme: theme, zoomScale: zoom, action: {}))),
                    ("menu button", height(MonknotMenuButton(systemImage: "ellipsis", label: "More", theme: theme, zoomScale: zoom, commands: []))),
                    ("push button", height(MonknotActionButton(title: "Revert", role: .secondary, theme: theme, zoomScale: zoom, size: .bar, action: {}))),
                    ("tab", height(MonknotTab(title: "Note.md", systemImage: "doc.text", isSelected: true, placement: .chrome, theme: theme, zoomScale: zoom, select: {}))),
                ]
                for (name, value) in measured {
                    XCTAssertEqual(value, control, accuracy: 0.01, "\(name) at zoom \(zoom)")
                }
            }
        }
    }

    /// design.md §6: a bar's groups sit one rounding of 8 apart at every zoom, the gap view taking what
    /// the bar's two item gaps leave.
    func testBarGroupsSitOneRoundingOfEightApartAtEveryZoom() {
        for theme in themes {
            for zoom in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    MonknotBarGroupGap.width(theme: theme, zoomScale: zoom)
                        + 2 * MonknotMetrics.interfaceDensity(MonknotMetrics.barItemGapBase, theme: theme, zoomScale: zoom),
                    MonknotMetrics.interfaceDensity(MonknotMetrics.barGroupGapBase, theme: theme, zoomScale: zoom),
                    "zoom \(zoom)"
                )
            }
        }
    }

    /// A card's bar pads 6; a header over a list pads by the list's 10 inset, so its title or glyph sits
    /// on the rows' glyph column (the sidebar, Find in Workspace and Links headers).
    func testBarsPadByTheirInsetAndStandFortyTall() {
        let theme = AppTheme.defaultDark
        for zoom in WorkspaceZoomPolicy.supportedLevels {
            for (inset, base) in [(MonknotBarInset.bar, CGFloat(6)), (.list, 10)] {
                let size = NSHostingView(rootView: MonknotBar(theme: theme, zoomScale: zoom, inset: inset) {
                    Color.clear.frame(width: 100, height: 1)
                }).fittingSize
                XCTAssertEqual(size.width, 100 + 2 * MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoom), accuracy: 0.01)
                XCTAssertEqual(size.height, MonknotMetrics.barHeight(theme: theme, zoomScale: zoom), accuracy: 0.01)
            }
        }
    }

    /// design.md §5.1: an open button (its menu or popover showing) holds the press fill and an ink
    /// glyph until it closes, as a pop-up does, and a disabled one still draws nothing.
    func testAnOpenIconButtonHoldsThePressFillAndInk() {
        for theme in themes {
            XCTAssertEqual(
                MonknotIconButton.fill(isActive: false, isOpen: true, drawsActiveBackground: true, isHovered: false, isPressed: false, isDisabled: false),
                .pressed
            )
            XCTAssertEqual(
                MonknotIconButton.fill(isActive: true, isOpen: true, drawsActiveBackground: true, isHovered: true, isPressed: false, isDisabled: false),
                .pressed,
                "Open wins over on and hover"
            )
            XCTAssertNil(MonknotIconButton.fill(isActive: false, isOpen: true, drawsActiveBackground: true, isHovered: false, isPressed: false, isDisabled: true))
            XCTAssertEqual(MonknotIconButton.iconColor(theme: theme, isActive: false, isOpen: true, isHovered: false, isDisabled: false), theme.foregroundColor)
            XCTAssertEqual(MonknotIconButton.iconColor(theme: theme, isActive: false, isOpen: true, isHovered: false, isDisabled: true), theme.disabledForegroundColor)
        }
    }

    /// A pop-up's menu is Monknot's menu (design.md §5.3): its values, the current one checked, then its
    /// commands after a separator. Highlighting a value previews it when asked, closing without a
    /// choice restores the value it opened with, a chosen value shows at once and commits as the menu
    /// leaves, and a command runs without being taken for a value.
    func testPopUpMenuChecksPreviewsCancelsAndCommits() throws {
        final class Recorder {
            var selection = "harbor-light"
            var previewed: String?
            var isPresented = true
            var previews: [String] = []
            var cancels = 0
            var strokeWidthRequests = 0
        }
        let recorder = Recorder()
        let presenter = MonknotMenuPresenter(
            isPresented: Binding(get: { recorder.isPresented }, set: { recorder.isPresented = $0 }),
            selection: Binding(get: { recorder.selection }, set: { recorder.selection = $0 }),
            previewedSelection: Binding(get: { recorder.previewed }, set: { recorder.previewed = $0 }),
            items: [
                MonknotPopUpItem(id: "harbor-light", title: "Harbor"),
                MonknotPopUpItem(id: "forge-light", title: "Forge"),
            ],
            actionGroups: [[MonknotPopUpAction(title: "Stroke Width…") { recorder.strokeWidthRequests += 1 }]],
            previewsSelection: true,
            onPreviewSelection: { recorder.previews.append($0) },
            onCancelPreview: { recorder.cancels += 1 },
            theme: .defaultLight,
            zoomScale: 1
        )
        let coordinator = presenter.makeCoordinator()

        let entries = coordinator.makeEntries()
        XCTAssertEqual(entries.map { $0.item?.title ?? "-" }, ["Harbor", "Forge", "-", "Stroke Width…"])
        XCTAssertEqual(entries.map { $0.item?.isChecked ?? false }, [true, false, false, false])
        XCTAssertEqual(entries.map { $0.item?.isValue ?? false }, [true, true, false, false], "Commands follow the values after a separator")
        XCTAssertTrue(entries.compactMap(\.item).allSatisfy { $0.systemImage == nil && $0.swatch == nil }, "Plain names have no glyph column")

        coordinator.highlight(1)
        XCTAssertEqual(recorder.previewed, "forge-light")
        XCTAssertEqual(recorder.previews, ["forge-light"])
        coordinator.highlight(3)
        coordinator.highlight(nil)
        XCTAssertEqual(recorder.previews, ["forge-light"], "Only a value previews")
        coordinator.finishTracking(chosen: nil)
        XCTAssertEqual(recorder.cancels, 1, "Closing without a choice cancels the preview")
        XCTAssertEqual(recorder.selection, "harbor-light")
        XCTAssertNil(recorder.previewed)
        XCTAssertFalse(recorder.isPresented, "The button leaves its open state")

        recorder.isPresented = true
        let second = coordinator.makeEntries()
        coordinator.finishTracking(chosen: 1)
        XCTAssertEqual(recorder.previewed, "forge-light", "The chosen value shows while its choice lands")
        second[1].item?.perform()
        XCTAssertEqual(recorder.selection, "forge-light")
        XCTAssertNil(recorder.previewed)
        XCTAssertEqual(recorder.cancels, 1, "A chosen value is not cancelled")

        let third = coordinator.makeEntries()
        XCTAssertEqual(third.map { $0.item?.isChecked ?? false }, [false, true, false, false], "The new value is checked")
        coordinator.finishTracking(chosen: 3)
        third[3].item?.perform()
        XCTAssertEqual(recorder.strokeWidthRequests, 1)
        XCTAssertEqual(recorder.selection, "forge-light", "A command is not a value")
        XCTAssertEqual(recorder.cancels, 2, "A command cancels a preview, as closing does")
    }

    /// A pop-up's values carry their glyph or swatch into the menu's glyph column.
    func testPopUpMenuShowsAToolsGlyphAndAColoursSwatch() {
        let presenter = MonknotMenuPresenter(
            isPresented: .constant(true),
            selection: .constant("pen"),
            items: [
                MonknotPopUpItem(id: "pen", title: "Draw", systemImage: "pencil.tip"),
                MonknotPopUpItem(id: "yellow", title: "Yellow", swatch: .yellow),
            ],
            theme: .defaultDark,
            zoomScale: 1
        )
        let entries = presenter.makeCoordinator().makeEntries()
        XCTAssertEqual(entries.first?.item?.systemImage, "pencil.tip")
        XCTAssertEqual(entries.last?.item?.swatch, .yellow)
        XCTAssertTrue(MonknotContextMenuLayout(entries: entries, theme: .defaultDark, zoomScale: 1).hasGlyphColumn)
    }

    /// A menu button's menu ("More"): groups of commands with their glyphs, separated, each enabled or
    /// not, and nothing checked.
    func testMenuButtonCommandsAreGroupedWithTheirGlyphsAndEnabledState() {
        var undone = 0
        let presenter = MonknotMenuPresenter(
            isPresented: .constant(true),
            actionGroups: [
                [
                    MonknotPopUpAction(title: "Undo", systemImage: "arrow.uturn.backward", isEnabled: true) { undone += 1 },
                    MonknotPopUpAction(title: "Redo", systemImage: "arrow.uturn.forward", isEnabled: false) {},
                ],
                [MonknotPopUpAction(title: "Highlight Selection", systemImage: "highlighter") {}],
            ],
            theme: .defaultLight,
            zoomScale: 1
        )
        let entries = presenter.makeCoordinator().makeEntries()
        XCTAssertEqual(entries.map { $0.item?.title ?? "-" }, ["Undo", "Redo", "-", "Highlight Selection"])
        XCTAssertEqual(entries.compactMap(\.item).map(\.isEnabled), [true, false, true])
        XCTAssertTrue(entries.compactMap(\.item).allSatisfy { $0.systemImage != nil && !$0.isChecked && !$0.isValue })
        XCTAssertFalse(MonknotContextMenuLayout(entries: entries, theme: .defaultLight, zoomScale: 1).reservesCheck)
        entries[0].item?.perform()
        XCTAssertEqual(undone, 1)
    }

    /// design.md §5.7: dragging, the arrow keys and VoiceOver all set the slider through one path that
    /// keeps the value in range and on its step.
    func testSliderKeepsEveryInputInRangeAndOnItsStep() {
        var value = 3.0
        let slider = MonknotSlider(
            title: "Stroke Width",
            value: Binding(get: { value }, set: { value = $0 }),
            range: 1...10,
            step: 1,
            valueDescription: "3 points",
            theme: .defaultLight,
            zoomScale: 1
        )
        // The binding VoiceOver's slider adjusts, and the drag and the arrow keys write through.
        slider.snappedValue.wrappedValue = 4.4
        XCTAssertEqual(value, 4)
        slider.snappedValue.wrappedValue = 7.6
        XCTAssertEqual(value, 8)
        slider.snappedValue.wrappedValue = 12
        XCTAssertEqual(value, 10)
        slider.snappedValue.wrappedValue = -3
        XCTAssertEqual(value, 1)

        XCTAssertEqual(MonknotSlider.resolvedValue(70.4, in: 55...100, step: nil), 70.4, accuracy: 0.0001, "No step, no snapping")
        XCTAssertEqual(MonknotSlider.resolvedValue(9.9, in: 0...10, step: 3), 9, "On the step from the range's start")
        XCTAssertEqual(MonknotSlider.resolvedValue(11, in: 0...10, step: 4), 10, "Never past the range")
    }

    /// design.md §5.7: the stepper moves a whole step from where the value is (a 10.5 pt text box goes
    /// to 11.5 and 9.5) and never leaves its range.
    func testStepperStepsFromTheCurrentValueAndKeepsItsRange() {
        XCTAssertEqual(MonknotStepper.value(10.5, steppedBy: 1, in: 6...144), 11.5)
        XCTAssertEqual(MonknotStepper.value(10.5, steppedBy: -1, in: 6...144), 9.5)
        XCTAssertEqual(MonknotStepper.value(143.5, steppedBy: 1, in: 6...144), 144)
        XCTAssertEqual(MonknotStepper.value(6.4, steppedBy: -1, in: 6...144), 6)
    }

    /// design.md §5.7: a disabled switch draws its track at half and dims its knob, on or off, whether
    /// its own row or an enclosing container disables it.
    func testSwitchDrawsItsDisabledStateOnAndOff() throws {
        for theme in themes {
            for isOn in [false, true] {
                let track = isOn ? theme.accentColor : theme.controlTrackFillColor
                XCTAssertEqual(MonknotSwitchStyle.trackFill(theme: theme, isOn: isOn, isEnabled: true), track.opacity(1))
                XCTAssertEqual(MonknotSwitchStyle.trackFill(theme: theme, isOn: isOn, isEnabled: false), track.opacity(0.5))
            }
            XCTAssertEqual(MonknotSwitchStyle.trackRing(theme: theme, isOn: false, isEnabled: true), theme.borderColor.opacity(1))
            XCTAssertEqual(MonknotSwitchStyle.trackRing(theme: theme, isOn: false, isEnabled: false), theme.borderColor.opacity(0.5))
            XCTAssertEqual(MonknotSwitchStyle.trackRing(theme: theme, isOn: true, isEnabled: true), .clear)
        }

        func toggle(isOn: Bool) -> some View {
            Toggle("Automatically download updates", isOn: .constant(isOn))
                .toggleStyle(MonknotSwitchStyle(theme: .defaultLight, zoomScale: 1))
                .labelsHidden()
        }
        for isOn in [false, true] {
            let enabled = try XCTUnwrap(MonknotRenderedInk.peakAlpha(of: toggle(isOn: isOn)))
            let disabled = try XCTUnwrap(MonknotRenderedInk.peakAlpha(of: toggle(isOn: isOn).disabled(true)))
            XCTAssertGreaterThan(enabled, 0.95, "An operable switch has an opaque knob")
            XCTAssertLessThan(disabled, 0.75, "A disabled switch dims, \(isOn ? "on" : "off")")
        }
    }

    /// Settings' workspace zoom counts in zoom levels: each level is its own index, a zoom between two
    /// levels counts as the one above, and a step moves to the next level as ⌘+ and ⌘− do.
    func testWorkspaceZoomStepperCountsInSupportedLevels() {
        for (index, level) in WorkspaceZoomPolicy.supportedLevels.enumerated() {
            XCTAssertEqual(WorkspaceZoomPolicy.levelIndex(level), index)
        }
        XCTAssertEqual(WorkspaceZoomPolicy.levelIndex(1.3), 5, "Between 125 % and 150 % counts as 150 %")
        XCTAssertEqual(WorkspaceZoomPolicy.levelIndex(5), WorkspaceZoomPolicy.supportedLevels.count - 1)
        XCTAssertEqual(WorkspaceZoomPolicy.zoom(steppingToLevel: 3, from: 1), 1.1)
        XCTAssertEqual(WorkspaceZoomPolicy.zoom(steppingToLevel: 1, from: 1), 0.9)
        XCTAssertEqual(WorkspaceZoomPolicy.zoom(steppingToLevel: 6, from: 1.3), 1.5)
        XCTAssertEqual(WorkspaceZoomPolicy.zoom(steppingToLevel: 4, from: 1.3), 1.25)
        XCTAssertEqual(WorkspaceZoomPolicy.zoom(steppingToLevel: 7, from: 2), 2)
    }

    /// design.md §1.2: `danger` is the theme's removed colour, `dangersoft` it at 12 / 10 %.
    func testDangerTokensFollowTheDerivation() {
        for theme in themes {
            XCTAssertEqual(theme.dangerColor, Color(hex: theme.semanticColors.diffRemoved))
            XCTAssertEqual(theme.dangerSoftFillColor, theme.dangerColor.opacity(theme.isDark ? 0.12 : 0.10))
        }
    }
}
