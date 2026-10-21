import AppKit
import MonknotCore
import SwiftUI

extension View {
    /// The one text field look (design.md §5.7): 28 tall, the canvas inside a `line` hairline, 8
    /// padding; while focused an `accent` hairline and a 3 pt `accsoft` ring, as the page's fields
    /// draw it; a `danger` hairline when its value is invalid. Find, Find in Workspace, Replace, the
    /// rename sheets and Settings' hex and name fields all use it.
    func monknotField(
        isFocused: Bool,
        isInvalid: Bool = false,
        isDisabled: Bool = false,
        trailingPadding: CGFloat = 8,
        theme: AppTheme,
        zoomScale: Double
    ) -> some View {
        modifier(MonknotFieldModifier(
            isFocused: isFocused,
            isInvalid: isInvalid,
            isDisabled: isDisabled,
            trailingPadding: trailingPadding,
            theme: theme,
            zoomScale: zoomScale
        ))
    }
}

private struct MonknotFieldModifier: ViewModifier {
    let isFocused: Bool
    let isInvalid: Bool
    let isDisabled: Bool
    let trailingPadding: CGFloat
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        let radius = theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .padding(.leading, MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: zoomScale))
            .padding(.trailing, MonknotMetrics.interfaceDensity(trailingPadding, theme: theme, zoomScale: zoomScale))
            .frame(height: MonknotMetrics.interfaceControl(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale))
            .background(theme.surfaceColor, in: shape)
            .overlay {
                shape.strokeBorder(lineWidth: 1).monknotStateStyle(strokeColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius + 1.5)
                    .stroke(theme.accentSoftFillColor, lineWidth: 3)
                    .padding(-1.5)
                    .allowsHitTesting(false)
                    .monknotStateOpacity(isFocused && !isDisabled ? 1 : 0)
            }
    }

    private var strokeColor: Color {
        if isInvalid { return theme.dangerColor }
        if isDisabled { return theme.borderColor.opacity(0.5) }
        return isFocused ? theme.accentColor : theme.borderColor
    }
}

/// The one stepper (design.md §5.7): a value in tabular figures between two small icon buttons, on the
/// control `track`, 28 tall. Settings' text size and workspace zoom, and the PDF export sheet.
struct MonknotStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    let displayValue: String
    var suffix = ""
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        HStack(spacing: MonknotMetrics.interfaceDensity(2, theme: theme, zoomScale: zoomScale)) {
            MonknotIconButton(
                systemImage: "minus",
                label: "Decrease \(title)",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: value <= range.lowerBound,
                size: .small,
                focusRingPlacement: .contained,
                action: decrement
            )
            Text(suffix.isEmpty ? displayValue : "\(displayValue) \(suffix)")
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .monospacedDigit()
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .frame(minWidth: MonknotMetrics.interfaceDensity(40, theme: theme, zoomScale: zoomScale))
                .accessibilityHidden(true)
            MonknotIconButton(
                systemImage: "plus",
                label: "Increase \(title)",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: value >= range.upperBound,
                size: .small,
                focusRingPlacement: .contained,
                action: increment
            )
        }
        .padding(.horizontal, MonknotMetrics.interfaceDensity(3, theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.interfaceControl(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale))
        .background(
            theme.controlTrackFillColor,
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(suffix.isEmpty ? displayValue : "\(displayValue) \(suffix)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    private func increment() {
        value = Self.value(value, steppedBy: step, in: range)
    }

    private func decrement() {
        value = Self.value(value, steppedBy: -step, in: range)
    }

    /// `value` moved by `delta` and kept in `range`. A value between steps (a 10.5 pt text box) moves by
    /// the whole step from where it is.
    static func value(_ value: Double, steppedBy delta: Double, in range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value + delta))
    }
}

/// The white knob of the switch and the slider (design.md §5.7): a `line` hairline and a one-point
/// shadow, so it reads on the canvas beside a track as well as on the accent. Dimmed while its control
/// is disabled.
struct MonknotKnob: View {
    let diameter: CGFloat
    let theme: AppTheme
    var isDimmed = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay { Circle().strokeBorder(theme.borderColor, lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .frame(width: diameter, height: diameter)
            .opacity(isDimmed ? 0.5 : 1)
    }
}

/// The one slider (design.md §5.7): a 4 pt track in the `on` fill, `accent` up to a 16 pt white knob.
/// Dragging, ← and → while it has keyboard focus, and VoiceOver all set the value through one path,
/// which keeps it in range and on its step. Settings' content width and the PDF stroke width use it.
struct MonknotSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueDescription: String
    var hint: String?
    let theme: AppTheme
    let zoomScale: Double

    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let knobDiameter = scaled(16)
            let travel = max(0, geometry.size.width - knobDiameter)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.onFillColor)
                    .frame(height: scaled(4))

                Capsule()
                    .fill(theme.accentColor.opacity(isEnabled ? 1 : 0.5))
                    .frame(width: knobDiameter / 2 + travel * fraction, height: scaled(4))

                MonknotKnob(diameter: knobDiameter, theme: theme, isDimmed: !isEnabled)
                    .monknotFocusRing(isVisible: isFocused && isEnabled, cornerRadius: knobDiameter / 2, theme: theme)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, (gesture.location.x - knobDiameter / 2) / max(1, travel)))
                        snappedValue.wrappedValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: scaled(20))
        .focusable(isEnabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: snappedValue.wrappedValue = value - keyboardStep
            case .right, .up: snappedValue.wrappedValue = value + keyboardStep
            @unknown default: break
            }
        }
        .accessibilityRepresentation {
            accessibilitySlider
                .accessibilityLabel(title)
                .accessibilityValue(valueDescription)
                .accessibilityHint(hint ?? "")
        }
        .monknotPointerCursor(enabled: isEnabled)
    }

    @ViewBuilder
    private var accessibilitySlider: some View {
        if let step, step > 0 {
            Slider(value: snappedValue, in: range, step: step)
        } else {
            Slider(value: snappedValue, in: range)
        }
    }

    /// The value as every input sets it: kept in range and on the step.
    var snappedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { proposed in
                let next = Self.resolvedValue(proposed, in: range, step: step)
                if next != value {
                    value = next
                }
            }
        )
    }

    /// One arrow press: the step, or one unit when the slider has none (every slider counts in whole
    /// percents or points).
    private var keyboardStep: Double {
        if let step, step > 0 { return step }
        return 1
    }

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// `proposed` kept in `range` and, with a step, on the nearest step from the range's start.
    static func resolvedValue(_ proposed: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        var next = min(range.upperBound, max(range.lowerBound, proposed))
        if let step, step > 0 {
            next = min(range.upperBound, range.lowerBound + ((next - range.lowerBound) / step).rounded() * step)
        }
        return next
    }
}

/// An `NSColorWell` that reports a colour once the user settles on it, not on every step of a drag in
/// the colour panel, so one choice is one change (and one undo step where there is one).
final class MonknotCommittedColorWell: NSColorWell {
    private var onCommit: ((NSColor) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControl()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureControl()
    }

    func update(color: NSColor, onCommit: @escaping (NSColor) -> Void) {
        self.onCommit = onCommit
        if !self.color.isEqual(color) {
            self.color = color
        }
    }

    func tearDown() {
        deactivate()
        target = nil
        action = nil
        onCommit = nil
    }

    private func configureControl() {
        isContinuous = false
        colorWellStyle = .minimal
        target = self
        action = #selector(commitColorChange(_:))
    }

    @objc private func commitColorChange(_ sender: NSColorWell) {
        onCommit?(sender.color)
    }
}

/// A colour as a value (design.md §5.3): a 14 pt circle inside a `line` hairline. The markup colour
/// pop-up shows it, and so does each colour's row in its menu. It dims with a disabled pop-up.
struct MonknotColorSwatch: View {
    static let diameterBase: CGFloat = 14

    let color: Color
    var isDisabled = false
    let theme: AppTheme
    let zoomScale: Double

    @Environment(\.monknotPopUpDisabled) private var isPopUpDisabled

    var body: some View {
        let diameter = MonknotMetrics.interfaceGlyph(Self.diameterBase, theme: theme, zoomScale: zoomScale)
        Circle()
            .fill(color)
            .overlay { Circle().strokeBorder(theme.borderColor, lineWidth: 1) }
            .frame(width: diameter, height: diameter)
            .opacity(isDisabled || isPopUpDisabled ? 0.35 : 1)
            .accessibilityHidden(true)
    }
}

/// The one colour well (design.md §5.7): the system's minimal well, a swatch that opens the colour
/// picker. Settings' theme colours and a PDF text box's colour use it.
struct MonknotColorWell: NSViewRepresentable {
    let color: NSColor
    let onCommit: (NSColor) -> Void

    func makeNSView(context: Context) -> MonknotCommittedColorWell {
        let colorWell = MonknotCommittedColorWell(frame: .zero)
        colorWell.update(color: color, onCommit: onCommit)
        return colorWell
    }

    func updateNSView(_ colorWell: MonknotCommittedColorWell, context: Context) {
        colorWell.update(color: color, onCommit: onCommit)
    }

    static func dismantleNSView(_ colorWell: MonknotCommittedColorWell, coordinator: ()) {
        colorWell.tearDown()
    }
}
