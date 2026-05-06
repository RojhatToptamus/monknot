import MarkprevCore
import SwiftUI

struct ThemeSettingsView: View {
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Theme")
                            .font(.title3.weight(.semibold))
                        Text("Use light, dark, or match your system.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Theme", selection: Binding(
                        get: { themePreference },
                        set: { themePreference = $0 }
                    )) {
                        ForEach(ThemePreference.allCases) { theme in
                            Label(theme.title, systemImage: theme.systemImage).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                CodePreviewCard()

                ThemeSwatchCard(
                    title: "Light theme",
                    background: "#FFFFFF",
                    foreground: "#1A1C1F",
                    contrast: 45
                )

                ThemeSwatchCard(
                    title: "Dark theme",
                    background: "#181818",
                    foreground: "#FFFFFF",
                    contrast: 60
                )
            }
            .padding(22)
        }
        .frame(width: 620, height: 560)
    }
}

private struct CodePreviewCard: View {
    var body: some View {
        HStack(spacing: 0) {
            codePane(accent: "#2563eb", surface: "sidebar", contrast: "42", isLeft: true)
            Divider()
            codePane(accent: "#0ea5e9", surface: "sidebar-editor", contrast: "68", isLeft: false)
        }
        .frame(height: 154)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
        }
    }

    private func codePane(accent: String, surface: String, contrast: String, isLeft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            codeLine(number: "1", text: "const themePreview: Theme = {", color: .purple)
            codeLine(number: "2", text: "  surface: \"\(surface)\",", color: .orange)
                .background(isLeft ? Color.red.opacity(0.18) : Color.green.opacity(0.15))
            codeLine(number: "3", text: "  accent: \"\(accent)\",", color: .orange)
                .background(isLeft ? Color.red.opacity(0.18) : Color.green.opacity(0.15))
            codeLine(number: "4", text: "  contrast: \(contrast),", color: .orange)
                .background(isLeft ? Color.red.opacity(0.18) : Color.green.opacity(0.15))
            codeLine(number: "5", text: "};", color: .secondary)
        }
        .font(.system(size: 16, weight: .regular, design: .monospaced))
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func codeLine(number: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text(text)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemeSwatchCard: View {
    let title: String
    let background: String
    let foreground: String
    let contrast: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                Label("Codex", systemImage: "textformat")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ThemeRow(label: "Accent", value: "#339CFF", isAccent: true)
            ThemeRow(label: "Background", value: background)
            ThemeRow(label: "Foreground", value: foreground)
            ThemeRow(label: "UI font", value: "-apple-system")
            ThemeRow(label: "Code font", value: "ui-monospace")

            HStack {
                Text("Contrast")
                Spacer()
                Slider(value: .constant(Double(contrast)), in: 0...100)
                    .frame(width: 180)
                Text("\(contrast)")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
        }
    }
}

private struct ThemeRow: View {
    let label: String
    let value: String
    var isAccent = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.body, design: isAccent ? .default : .monospaced))
                .foregroundStyle(isAccent ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isAccent ? Color.blue : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
