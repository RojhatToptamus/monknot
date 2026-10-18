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
        leadingPadding: CGFloat = 8,
        trailingPadding: CGFloat = 8,
        theme: AppTheme,
        zoomScale: Double
    ) -> some View {
        modifier(MonknotFieldModifier(
            isFocused: isFocused,
            isInvalid: isInvalid,
            isDisabled: isDisabled,
            leadingPadding: leadingPadding,
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
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        let radius = theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .padding(.leading, MonknotMetrics.interfaceDensity(leadingPadding, theme: theme, zoomScale: zoomScale))
            .padding(.trailing, MonknotMetrics.interfaceDensity(trailingPadding, theme: theme, zoomScale: zoomScale))
            .frame(height: MonknotMetrics.interfaceControl(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale))
            .background(theme.surfaceColor, in: shape)
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: 1)
            }
            .overlay {
                if isFocused, !isDisabled {
                    RoundedRectangle(cornerRadius: radius + 1.5)
                        .stroke(theme.accentSoftFillColor, lineWidth: 3)
                        .padding(-1.5)
                        .allowsHitTesting(false)
                }
            }
            .animation(MonknotMotion.hoverAnimation, value: isFocused)
    }

    private var strokeColor: Color {
        if isInvalid { return Color(hex: theme.semanticColors.diffRemoved) }
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
        value = min(range.upperBound, value + step)
    }

    private func decrement() {
        value = max(range.lowerBound, value - step)
    }
}

/// The one slider (design.md §5.7): a 4 pt track in the `on` fill, `accent` up to a 16 pt white knob.
/// Settings' content width and the PDF stroke width use it.
struct MonknotSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueDescription: String
    var hint: String?
    let theme: AppTheme
    let zoomScale: Double

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
                    .fill(theme.accentColor)
                    .frame(width: knobDiameter / 2 + travel * fraction, height: scaled(4))

                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .overlay { Circle().strokeBorder(theme.borderColor, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, (gesture.location.x - knobDiameter / 2) / max(1, travel)))
                        setValue(range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: scaled(20))
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueDescription)
                .accessibilityHint(hint ?? "")
        }
        .monknotPointerCursor()
    }

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func setValue(_ newValue: Double) {
        var next = min(range.upperBound, max(range.lowerBound, newValue))
        if let step, step > 0 {
            next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        }
        if next != value {
            value = next
        }
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
