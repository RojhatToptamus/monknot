import AppKit
import MarkprevCore
import SwiftUI

// MARK: - Row Primitives
// Codex design system: flat rows on the window surface, separated by dividers.
// No rounded boxes, no nested containers. Spacing and dividers create hierarchy.

/// A full-width settings row: label + description on the left, control on the right, divider below.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 20)
        }
    }
}

/// Convenience: toggle row.
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Convenience: stepper row with numeric display.
struct SettingsStepperRow: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var suffix = "px"

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 6) {
                Text(displayValue)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text(suffix)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var displayValue: String {
        suffix == "x" ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }
}

/// Convenience: slider row.
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(width: 160)
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }
}

// MARK: - Theme Value Row

/// A key-value row with an optional color chip — used inside theme panels.
struct ThemeValueRow: View {
    let label: String
    let value: String
    var chipColor: Color? = nil
    var forceLightText = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let chipColor {
                HStack(spacing: 8) {
                    Circle()
                        .fill(chipColor)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().stroke(.white.opacity(0.2), lineWidth: 1)
                        }
                    Text(value)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            } else {
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 20)
        }
    }
}

// MARK: - Section Header

/// A quiet section header — just a label, like "Light theme" in Codex.
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}
