import AppKit
import MonknotCore
import SwiftUI

struct TypingAssistantBar: View {
    @ObservedObject var session: TypingAssistantSession
    let theme: AppTheme
    let zoomScale: Double
    let accept: () -> Void
    let dismiss: () -> Void

    private var scale: CGFloat {
        theme.layoutScale(zoomScale: zoomScale)
    }

    private var diagnostics: TypingAssistantSessionDiagnostics {
        session.diagnostics()
    }

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 16 * scale, height: 16 * scale)
                .accessibilityHidden(true)

            Text("Flow")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(theme.foregroundColor)

            Text(statusText)
                .font(.system(size: 11 * scale, weight: .regular))
                .foregroundStyle(theme.mutedForegroundColor)
                .lineLimit(1)

            if let suggestion = session.suggestion {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(width: 1, height: 16 * scale)

                Text(suggestion.replacementText)
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MonknotIconButton(
                    systemImage: "checkmark",
                    label: "Apply Suggestion",
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .compact,
                    action: accept
                )
                .help("Apply suggestion (Tab)")

                MonknotIconButton(
                    systemImage: "xmark",
                    label: "Dismiss Suggestion",
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .compact,
                    action: dismiss
                )
                .help("Dismiss suggestion (Esc)")
            } else {
                Spacer(minLength: 8 * scale)
            }

            settingsMenu
        }
        .padding(.horizontal, 12 * scale)
        .frame(height: 30 * scale)
        .background(theme.insetFillColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local writing assistance")
    }

    private var settingsMenu: some View {
        Menu {
            Toggle(
                "Automatic Word Corrections",
                isOn: $session.wordBoundaryCorrectionEnabled
            )
            Toggle(
                "Grammar Suggestions",
                isOn: $session.grammarSuggestionsEnabled
            )
            Toggle(
                "Record Local Diagnostics",
                isOn: $session.telemetryRecordingEnabled
            )
            if FileManager.default.fileExists(
                atPath: session.telemetryFileURL.path
            ) {
                Button("Reveal Diagnostics File") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        session.telemetryFileURL
                    ])
                }
            }
            Divider()
            Button(session.isEnabled ? "Turn Off Flow" : "Turn On Flow") {
                session.isEnabled.toggle()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 26 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Writing assistance settings")
        .accessibilityLabel("Writing assistance settings")
    }

    private var statusText: String {
        switch session.status {
        case .disabled:
            return "Off"
        case .idle:
            return routeDetail ?? "Ready"
        case .waitingForPause:
            return "Waiting for pause"
        case .checking:
            return "Checking locally"
        case .suggestionReady:
            return routeDetail ?? "Suggestion"
        case let .fallback(route):
            return "No change · \(routeLabel(route))"
        }
    }

    private var routeDetail: String? {
        guard let route = diagnostics.latestRoute else { return nil }
        if let latency = diagnostics.latestLatencyMilliseconds {
            return "\(routeLabel(route)) · \(Int(latency.rounded())) ms"
        }
        return routeLabel(route)
    }

    private func routeLabel(_ route: LocalTypingAssistantRoute) -> String {
        switch route {
        case .loadedForeground:
            return "Local model"
        case .modelBusy:
            return "Model busy"
        case .foregroundNoSuggestion:
            return "No correction"
        case .foregroundTimeout:
            return "Timed out"
        case .unloadedBackgroundWarmup:
            return "Warming locally"
        case .probeFailure:
            return "Local model unavailable"
        case .invalidResponse:
            return "Invalid model response"
        case .safetySuppressed:
            return "Unsafe change blocked"
        case .protectedContextSuppressed:
            return "Protected text"
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .checking, .waitingForPause:
            return "ellipsis"
        case .suggestionReady:
            return "sparkles"
        case .fallback:
            return "arrow.uturn.backward"
        case .disabled:
            return "circle"
        case .idle:
            return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .suggestionReady:
            return theme.accentColor
        case .fallback:
            return theme.mutedForegroundColor
        case .disabled:
            return theme.mutedForegroundColor.opacity(0.65)
        case .idle, .checking, .waitingForPause:
            return theme.foregroundColor.opacity(0.8)
        }
    }
}
