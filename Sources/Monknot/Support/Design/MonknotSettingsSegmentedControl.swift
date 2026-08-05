import AppKit
import MonknotCore
import SwiftUI

/// Theme-aware segmented control for Settings (avoids system `.segmented` tint/contrast bugs on light themes).
struct MonknotSettingsSegmentedControl: View {
    let options: [MonknotSettingsSegment]
    @Binding var selection: String
    let theme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    private var cornerRadius: CGFloat {
        theme.chromeRadius(theme.settingsControlCornerRadius, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(2)) {
            ForEach(options) { option in
                MonknotSettingsSegmentButton(
                    title: option.title,
                    isSelected: selection == option.id,
                    theme: theme,
                    action: { selection = option.id }
                )
            }
        }
        .padding(scaled(2))
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(theme.controlTrackFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
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
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, scaled(12))
                .padding(.vertical, scaled(6))
                .frame(minHeight: scaled(28))
                .background(background, in: RoundedRectangle(cornerRadius: max(0, cornerRadius - 1)))
                .contentShape(RoundedRectangle(cornerRadius: max(0, cornerRadius - 1)))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .monknotPointerCursor()
    }

    private var labelColor: Color {
        if isSelected {
            return theme.foregroundColor
        }
        return theme.foregroundColor.opacity(isHovered ? 0.92 : 0.72)
    }

    private var background: Color {
        if isSelected {
            return theme.insetFillColor
        }
        if isHovered || isFocused {
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
    let previewsSelection: Bool
    let onPreviewSelection: ((String) -> Void)?
    let onCancelPreview: (() -> Void)?
    @State private var isMenuPresented = false
    @State private var previewedSelection: String?
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    init(
        title: String,
        selection: Binding<String>,
        options: [(id: String, title: String)],
        theme: AppTheme,
        previewsSelection: Bool = false,
        onPreviewSelection: ((String) -> Void)? = nil,
        onCancelPreview: (() -> Void)? = nil
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.theme = theme
        self.previewsSelection = previewsSelection
        self.onPreviewSelection = onPreviewSelection
        self.onCancelPreview = onCancelPreview
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    private var cornerRadius: CGFloat {
        theme.chromeRadius(theme.settingsControlCornerRadius, zoomScale: settingsZoomScale)
    }

    var body: some View {
        Button {
            isMenuPresented = true
        } label: {
            HStack(spacing: scaled(6)) {
                Text(selectedTitle)
                    .font(MonknotTypography.settingsButton(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: scaled(9), weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .padding(.horizontal, scaled(12))
            .padding(.vertical, scaled(6))
            .frame(minHeight: scaled(28))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        isHovered || isFocused
                            ? theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
                            : theme.insetFillColor
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .fixedSize()
        .background(
            SettingsMenuPresenter(
                isPresented: $isMenuPresented,
                selection: $selection,
                previewedSelection: $previewedSelection,
                options: options,
                previewsSelection: previewsSelection,
                onPreviewSelection: onPreviewSelection,
                onCancelPreview: onCancelPreview
            )
            .allowsHitTesting(false)
        )
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .monknotPointerCursor()
    }

    private var selectedTitle: String {
        options.first(where: { $0.id == previewedSelection ?? selection })?.title ?? "Theme"
    }
}

struct SettingsMenuSelectionTransaction: Equatable {
    let initialSelection: String
    private(set) var previewedSelection: String
    private(set) var committedSelection: String?

    init(initialSelection: String) {
        self.initialSelection = initialSelection
        self.previewedSelection = initialSelection
    }

    mutating func preview(_ selection: String) {
        previewedSelection = selection
    }

    mutating func commit(_ selection: String) {
        previewedSelection = selection
        committedSelection = selection
    }

    var selectionAfterClose: String {
        committedSelection ?? initialSelection
    }
}

private struct SettingsMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var selection: String
    @Binding var previewedSelection: String?
    let options: [(id: String, title: String)]
    let previewsSelection: Bool
    let onPreviewSelection: ((String) -> Void)?
    let onCancelPreview: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard isPresented,
              !context.coordinator.isTracking,
              !context.coordinator.isPresentationScheduled else {
            return
        }

        context.coordinator.isPresentationScheduled = true
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator else { return }
            coordinator.isPresentationScheduled = false
            guard coordinator.parent.isPresented else { return }
            coordinator.presentMenu(from: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SettingsMenuPresenter
        var isTracking = false
        var isPresentationScheduled = false
        private var transaction: SettingsMenuSelectionTransaction?

        init(parent: SettingsMenuPresenter) {
            self.parent = parent
        }

        func presentMenu(from anchor: NSView) {
            guard !isTracking else { return }

            let initialSelection = parent.selection
            transaction = SettingsMenuSelectionTransaction(initialSelection: initialSelection)

            let menu = NSMenu(title: parent.selection)
            menu.autoenablesItems = false
            menu.delegate = self
            menu.minimumWidth = max(anchor.bounds.width, 160)

            for option in parent.options {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(commitSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.state = option.id == initialSelection ? .on : .off
                menu.addItem(item)
            }

            let positioningItem = menu.items.first { ($0.representedObject as? String) == initialSelection }
            isTracking = true
            _ = menu.popUp(
                positioning: positioningItem,
                at: NSPoint(x: 0, y: anchor.bounds.maxY),
                in: anchor
            )
            isTracking = false

            if parent.previewsSelection,
               transaction?.committedSelection == nil {
                parent.onCancelPreview?()
            }
            parent.previewedSelection = nil
            transaction = nil
            parent.isPresented = false
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard parent.previewsSelection,
                  let selection = item?.representedObject as? String else {
                return
            }
            transaction?.preview(selection)
            parent.previewedSelection = selection
            parent.onPreviewSelection?(selection)
        }

        @objc private func commitSelection(_ sender: NSMenuItem) {
            guard let selection = sender.representedObject as? String else { return }
            transaction?.commit(selection)
            parent.selection = selection
            parent.previewedSelection = nil
        }
    }
}
