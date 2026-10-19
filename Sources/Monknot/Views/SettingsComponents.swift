import AppKit
import MonknotCore
import SwiftUI

// MARK: - Row Primitives

/// A Settings row (design.md §12): label and detail on the left, the control on the right, at least
/// 40 tall, 12 padding, and a `line2` separator inset 12 below it. A disabled row draws its words in
/// `ink4`; nothing is dimmed by opacity on top.
struct SettingsRow<Control: View>: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    var isDisabled: Bool = false
    @ViewBuilder let control: () -> Control
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    static var minimumHeightBase: CGFloat { 40 }
    static var horizontalPaddingBase: CGFloat { 12 }
    static var verticalPaddingBase: CGFloat { 8 }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack(alignment: .center, spacing: scaled(12)) {
            VStack(alignment: .leading, spacing: scaled(3)) {
                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.foregroundColor)
                if let detail {
                    Text(detail)
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: settingsZoomScale))
                        .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.tertiaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, scaled(Self.horizontalPaddingBase))
        .padding(.vertical, scaled(Self.verticalPaddingBase))
        .frame(minHeight: scaled(Self.minimumHeightBase))
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(height: 1)
                    .padding(.leading, scaled(Self.horizontalPaddingBase))
            }
        }
    }
}

// MARK: - Buttons

/// Convenience: toggle row.
struct SettingsToggleRow: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    var isDisabled: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(
            theme: theme,
            title: title,
            detail: detail,
            showsDivider: showsDivider,
            isDisabled: isDisabled
        ) {
            // The switch style draws no label, so name the control for VoiceOver explicitly.
            Toggle(title, isOn: $isOn)
                .toggleStyle(MonknotSwitchStyle(theme: theme, isDisabled: isDisabled))
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(detail ?? "")
                .monknotPointerCursor(enabled: !isDisabled)
        }
        .disabled(isDisabled)
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

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            MonknotStepper(
                title: title,
                value: $value,
                range: range,
                step: step,
                displayValue: displayValue,
                suffix: suffix,
                theme: theme,
                zoomScale: settingsZoomScale
            )
            .accessibilityHint(detail)
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
                MonknotSlider(
                    title: title,
                    value: $value,
                    range: range,
                    valueDescription: "\(Int(value.rounded()))\(suffix)",
                    hint: detail,
                    theme: theme,
                    zoomScale: settingsZoomScale
                )
                    .frame(width: scaled(100))
                Text("\(Int(value.rounded()))\(suffix)")
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: settingsZoomScale))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .frame(width: scaled(suffix.isEmpty ? 30 : 44), alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The one switch (design.md §5.7): a 32 × 18 capsule with a 14 knob, `accent` when on, the control
/// `track` inside a `line` hairline when off; disabled at `ink4`.
struct MonknotSwitchStyle: ToggleStyle {
    let theme: AppTheme
    var isDisabled = false
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
                    .monknotStateStyle(configuration.isOn ? theme.accentColor.opacity(isDisabled ? 0.45 : 1) : theme.controlTrackFillColor)
                    .overlay {
                        Capsule()
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                            .monknotStateOpacity(configuration.isOn ? 0 : 1)
                    }

                // Only the knob moves; it slides over the hover duration, or jumps with Reduce Motion.
                Circle()
                    .fill(Color.white)
                    .frame(width: scaled(14), height: scaled(14))
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .animation(reduceMotion ? nil : MonknotMotion.hoverAnimation) {
                        $0.offset(x: configuration.isOn ? scaled(7) : -scaled(7))
                    }
            }
            .frame(width: scaled(32), height: scaled(18))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        SettingsRow(theme: theme, title: label, showsDivider: showsDivider) {
            HStack(spacing: scaled(8)) {
                MonknotColorWell(color: NSColor(hex: hex)) { color in
                    if let nextHex = NSColor.monknotHexString(from: Color(nsColor: color)) {
                        hex = nextHex
                    }
                }
                .frame(width: scaled(44), height: scaled(22))
                .accessibilityLabel("\(label) color")
                .monknotPointerCursor()

                TextField("#000000", text: Binding(
                    get: { hex },
                    set: { hex = Self.normalizedInput($0) }
                ))
                .textFieldStyle(.plain)
                .focused($isHexFieldFocused)
                .font(.system(
                    size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                    weight: .regular,
                    design: .monospaced
                ))
                .foregroundStyle(isHexValid ? theme.foregroundColor : validationColor)
                .monknotField(
                    isFocused: isHexFieldFocused,
                    isInvalid: !isHexValid,
                    theme: theme,
                    zoomScale: settingsZoomScale
                )
                .frame(width: scaled(104))
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

// MARK: - Section Header

/// A Settings group header (design.md §4.3, §12): 12 / 400 `ink3` on the rows' text edge, 18 above
/// (none at the top of a page) and 8 above its group. An accessory, such as Revert, sits centred on the
/// header's line without changing the rhythm.
struct SettingsSectionHeader<Accessory: View>: View {
    let theme: AppTheme
    let title: String
    var isFirst = false
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    static var topSpacingBase: CGFloat { 18 }
    static var bottomSpacingBase: CGFloat { 8 }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        Text(title)
            .font(MonknotTypography.groupHeader(theme: theme, zoomScale: settingsZoomScale))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                accessory()
            }
            .padding(.horizontal, scaled(SettingsRow<EmptyView>.horizontalPaddingBase))
            .padding(.top, isFirst ? 0 : scaled(Self.topSpacingBase))
            .padding(.bottom, scaled(Self.bottomSpacingBase))
    }
}

extension SettingsSectionHeader where Accessory == EmptyView {
    init(theme: AppTheme, title: String, isFirst: Bool = false) {
        self.init(theme: theme, title: title, isFirst: isFirst, accessory: { EmptyView() })
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
