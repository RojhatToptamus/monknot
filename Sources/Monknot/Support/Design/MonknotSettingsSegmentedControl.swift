import MonknotCore
import SwiftUI

/// Theme-aware segmented control for Settings (avoids system `.segmented` tint/contrast bugs on light themes).
struct MonknotSettingsSegmentedControl: View {
    let options: [MonknotSettingsSegment]
    @Binding var selection: String
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                MonknotSettingsSegmentButton(
                    title: option.title,
                    isSelected: selection == option.id,
                    theme: theme,
                    action: { selection = option.id }
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                .fill(theme.controlTrackFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }
}

struct MonknotSettingsSegment: Identifiable {
    let id: String
    let title: String
}

private struct MonknotSettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let theme: AppTheme
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MonknotTypography.settingsButton(theme: theme))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(background, in: RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius - 1))
                .contentShape(RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius - 1))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .monknotPointerCursor()
    }

    private var labelColor: Color {
        if isSelected {
            return theme.onAccentForegroundColor
        }
        return theme.foregroundColor.opacity(isHovered ? 0.92 : 0.72)
    }

    private var background: Color {
        if isSelected {
            return theme.accentColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.04)
        }
        return .clear
    }
}

/// Theme preset menu styled for readable labels on any background.
struct MonknotSettingsMenuPicker: View {
    let title: String
    @Binding var selection: String
    let options: [(id: String, title: String)]
    let theme: AppTheme

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button(option.title) {
                    selection = option.id
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedTitle)
                    .font(MonknotTypography.settingsButton(theme: theme))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .fill(theme.insetFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .monknotPointerCursor()
    }

    private var selectedTitle: String {
        options.first(where: { $0.id == selection })?.title ?? "Theme"
    }
}
