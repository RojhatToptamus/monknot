import AppKit
import MonknotCore
import SwiftUI

// MARK: - Row Primitives

/// Full-width settings row: label + description on the left, control on the right, divider below.
struct SettingsRow<Control: View>: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    @ViewBuilder let control: () -> Control
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: scaled(4)) {
                Text(title)
                    .font(MonknotTypography.settingsRowTitle(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(theme.foregroundColor)
                if let detail {
                    Text(detail)
                        .font(MonknotTypography.settingsRowDetail(theme: theme, zoomScale: settingsZoomScale))
                        .foregroundStyle(theme.mutedForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: scaled(20))
            control()
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.settingsRowHorizontal))
        .padding(.vertical, scaled(MonknotMetrics.Spacing.settingsRowVertical))
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 1)
                    .padding(.leading, scaled(MonknotMetrics.Spacing.settingsRowHorizontal))
            }
        }
    }
}

// MARK: - Buttons

struct SettingsOutlineButton: View {
    let title: String
    let theme: AppTheme
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    private var cornerRadius: CGFloat {
        theme.chromeRadius(theme.settingsControlCornerRadius, zoomScale: settingsZoomScale)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MonknotTypography.settingsButton(theme: theme, zoomScale: settingsZoomScale))
                .padding(.horizontal, scaled(14))
                .padding(.vertical, scaled(6))
                .foregroundStyle(theme.foregroundColor.opacity(isDisabled ? 0.38 : 0.92))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.insetFillColor)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(theme.foregroundColor.opacity(isHovered && !isDisabled ? 0.045 : 0))
                        }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(isFocused ? theme.accentColor.opacity(0.9) : theme.borderColor, lineWidth: isFocused ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .opacity(isDisabled ? 0.55 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .monknotPointerCursor(enabled: !isDisabled)
    }
}

/// Convenience: toggle row.
struct SettingsToggleRow: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(MonknotSettingsSwitchStyle(theme: theme))
                .labelsHidden()
                .accessibilityHint(detail ?? "")
                .monknotPointerCursor()
        }
    }
}

/// Convenience: stepper row with numeric display.
struct SettingsStepperRow: View {
    let theme: AppTheme
    let title: String
    let detail: String
    var showsDivider: Bool = true
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var suffix = "px"
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    private var cornerRadius: CGFloat {
        theme.chromeRadius(theme.settingsControlCornerRadius, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            HStack(spacing: scaled(8)) {
                Text(displayValue)
                    .font(.system(
                        size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: settingsZoomScale),
                        weight: .medium,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.foregroundColor)
                    .padding(.horizontal, scaled(10))
                    .padding(.vertical, scaled(5))
                    .background(
                        theme.insetFillColor,
                        in: RoundedRectangle(cornerRadius: cornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                    )
                    .accessibilityHidden(true)
                Text(suffix)
                    .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale)))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue("\(displayValue) \(suffix)")
                    .accessibilityHint(detail)
                    .monknotPointerCursor()
            }
        }
    }

    private var displayValue: String {
        guard suffix == "x" else { return "\(Int(value.rounded()))" }
        let usesHundredths = abs((value * 10).rounded() - value * 10) > 0.001
        return String(format: usesHundredths ? "%.2f" : "%.1f", value)
    }
}

/// Convenience: slider row.
struct SettingsSliderRow: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            HStack(spacing: scaled(10)) {
                MonknotSettingsSlider(
                    title: title,
                    detail: detail,
                    value: $value,
                    range: range,
                    suffix: suffix,
                    theme: theme
                )
                    .frame(width: scaled(100))
                Text("\(Int(value.rounded()))\(suffix)")
                    .font(.system(
                        size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                        weight: .medium,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: scaled(suffix.isEmpty ? 30 : 44), alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct MonknotSettingsSwitchStyle: ToggleStyle {
    let theme: AppTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(
                        configuration.isOn
                            ? theme.accentColor
                            : theme.foregroundColor.opacity(theme.isDark ? 0.16 : 0.12)
                    )

                Circle()
                    .fill(Color.white.opacity(configuration.isOn ? 1 : 0.78))
                    .frame(width: scaled(16), height: scaled(16))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: configuration.isOn ? scaled(7) : -scaled(7))
            }
            .frame(width: scaled(34), height: scaled(20))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
    }
}

private struct MonknotSettingsSlider: View {
    let title: String
    let detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let theme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let fraction = normalizedFraction
            let knobDiameter = scaled(16)
            let travel = max(0, geometry.size.width - knobDiameter)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.foregroundColor.opacity(theme.isDark ? 0.15 : 0.12))
                    .frame(height: scaled(4))

                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: knobDiameter / 2 + travel * fraction, height: scaled(4))

                Circle()
                    .fill(theme.isDark ? Color.white : theme.foregroundColor)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, gesture.location.x / max(1, geometry.size.width)))
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: scaled(20))
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.rounded()))\(suffix)")
                .accessibilityHint(detail ?? "")
        }
        .monknotPointerCursor()
    }

    private var normalizedFraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

// MARK: - Editable Color Row

struct EditableThemeColorRow: View {
    let theme: AppTheme
    let label: String
    var showsDivider: Bool = true
    @Binding var hex: String
    @FocusState private var isHexFieldFocused: Bool
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    private var cornerRadius: CGFloat {
        theme.chromeRadius(theme.settingsControlCornerRadius, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsRow(theme: theme, title: label, showsDivider: showsDivider) {
            HStack(spacing: scaled(10)) {
                ColorPicker(
                    label,
                    selection: Binding(
                        get: { Color(hex: hex) },
                        set: { color in
                            if let nextHex = NSColor.monknotHexString(from: color) {
                                hex = nextHex
                            }
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: scaled(28), height: scaled(22))
                .monknotPointerCursor()

                TextField("#000000", text: Binding(
                    get: { hex },
                    set: { hex = Self.normalizedInput($0) }
                ))
                .textFieldStyle(.plain)
                .focused($isHexFieldFocused)
                .font(.system(
                    size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                    weight: .medium,
                    design: .monospaced
                ))
                .foregroundStyle(isHexValid ? theme.foregroundColor : validationColor)
                .padding(.horizontal, scaled(10))
                .padding(.vertical, scaled(6))
                .frame(width: scaled(112), alignment: .leading)
                .background(
                    theme.insetFillColor,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            isHexValid
                                ? (isHexFieldFocused ? theme.accentColor.opacity(0.9) : theme.borderColor)
                                : validationColor,
                            lineWidth: isHexFieldFocused ? 1.5 : 1
                        )
                )
                .accessibilityLabel("\(label) hexadecimal value")
                .accessibilityValue(isHexValid ? hex : "\(hex), invalid")
                .accessibilityHint("Enter a six-digit hexadecimal color such as #0169CC")
            }
        }
    }

    private var isHexValid: Bool {
        RGBHex(hex) != nil
    }

    private var validationColor: Color {
        Color(hex: theme.semanticColors.diffRemoved)
    }

    private static func normalizedInput(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        normalized.removeAll { character in
            character != "#" && !character.isHexDigit
        }

        if !normalized.hasPrefix("#") {
            normalized = "#\(normalized)"
        }

        if normalized.count > 7 {
            normalized = String(normalized.prefix(7))
        }

        return normalized
    }
}

// MARK: - Theme Value Row

/// Key-value row with an optional color chip — used inside theme panels.
struct ThemeValueRow: View {
    let theme: AppTheme
    let label: String
    let value: String
    var chipColor: Color? = nil
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: settingsZoomScale)))
                .foregroundStyle(theme.mutedForegroundColor)
            Spacer()
            if let chipColor {
                HStack(spacing: scaled(8)) {
                    Circle()
                        .fill(chipColor)
                        .frame(width: scaled(14), height: scaled(14))
                        .overlay {
                            Circle().stroke(theme.borderColor, lineWidth: 1)
                        }
                    Text(value)
                        .font(.system(
                            size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                            weight: .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(theme.foregroundColor)
                }
            } else {
                Text(value)
                    .font(.system(
                        size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                        weight: .medium,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
        }
        .padding(.horizontal, scaled(18))
        .padding(.vertical, scaled(10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
                .padding(.leading, scaled(MonknotMetrics.Spacing.settingsRowHorizontal))
        }
    }
}

// MARK: - Section Header

struct SettingsSectionHeader: View {
    let theme: AppTheme
    let title: String
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        Text(title)
            .font(.system(
                size: MonknotMetrics.interfaceText(11, theme: theme, zoomScale: settingsZoomScale),
                weight: .semibold
            ))
            .tracking(scaled(1.1))
            .foregroundStyle(theme.mutedForegroundColor)
            .textCase(.uppercase)
            .padding(.horizontal, scaled(2))
            .padding(.bottom, scaled(7))
    }
}

private extension NSColor {
    static func monknotHexString(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }

        return String(
            format: "#%02X%02X%02X",
            Int((Double(rgb.redComponent) * 255).rounded()),
            Int((Double(rgb.greenComponent) * 255).rounded()),
            Int((Double(rgb.blueComponent) * 255).rounded())
        )
    }
}
