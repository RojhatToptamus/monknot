import AppKit
import MonknotCore
import SwiftUI

// MARK: - Surfaces

/// Bordered card grouping for settings sections (Codex-style layered panels).
struct SettingsGroupCard<Content: View>: View {
    let theme: AppTheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: theme.settingsCardCornerRadius)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsCardCornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Row Primitives

/// Full-width settings row: label + description on the left, control on the right, divider below.
struct SettingsRow<Control: View>: View {
    let theme: AppTheme
    let title: String
    var detail: String? = nil
    var showsDivider: Bool = true
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.foregroundColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.mutedForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 20)
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 1)
                    .padding(.leading, 18)
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

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(theme.foregroundColor.opacity(isDisabled ? 0.38 : 0.92))
                .background(
                    RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                        .fill(theme.insetFillColor)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                                .fill(theme.foregroundColor.opacity(isHovered && !isDisabled ? 0.045 : 0))
                        }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
    let detail: String
    var showsDivider: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(theme.accentColor)
                .labelsHidden()
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

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        theme.insetFillColor,
                        in: RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                    )
                Text(suffix)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.mutedForegroundColor)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                    .monknotPointerCursor()
            }
        }
    }

    private var displayValue: String {
        suffix == "x" ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
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

    var body: some View {
        SettingsRow(theme: theme, title: title, detail: detail, showsDivider: showsDivider) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .tint(theme.accentColor)
                    .frame(width: 168)
                    .monknotPointerCursor()
                Text("\(Int(value.rounded()))\(suffix)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: suffix.isEmpty ? 30 : 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Editable Color Row

struct EditableThemeColorRow: View {
    let theme: AppTheme
    let label: String
    var showsDivider: Bool = true
    @Binding var hex: String

    var body: some View {
        SettingsRow(theme: theme, title: label, showsDivider: showsDivider) {
            HStack(spacing: 10) {
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
                .frame(width: 28, height: 22)
                .monknotPointerCursor()

                TextField("#000000", text: Binding(
                    get: { hex },
                    set: { hex = Self.normalizedInput($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 112, alignment: .leading)
                .background(
                    theme.insetFillColor,
                    in: RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                )
            }
        }
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

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.mutedForegroundColor)
            Spacer()
            if let chipColor {
                HStack(spacing: 8) {
                    Circle()
                        .fill(chipColor)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().stroke(theme.borderColor, lineWidth: 1)
                        }
                    Text(value)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.foregroundColor)
                }
            } else {
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }
}

// MARK: - Section Header

struct SettingsSectionHeader: View {
    let theme: AppTheme
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.foregroundColor)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 10)
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
