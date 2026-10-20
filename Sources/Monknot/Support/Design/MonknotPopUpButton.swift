import AppKit
import MonknotCore
import SwiftUI

/// A value a pop-up button chooses. Its menu shows `systemImage` (a tool) or `swatch` (a colour) in
/// the glyph column; a menu of plain names has none.
struct MonknotPopUpItem: Identifiable, Equatable {
    let id: String
    let title: String
    var systemImage: String?
    var swatch: Color?
}

/// A command in a control's menu: after a pop-up's values, below a separator ("Stroke Width…"), or in
/// a menu button's menu ("More"), with its glyph.
struct MonknotPopUpAction: Identifiable {
    let title: String
    var systemImage: String?
    var isEnabled = true
    let action: () -> Void

    var id: String { title }
}

/// The one pop-up button (design.md §5.3): the value and a chevron on the control `track`, opening
/// Monknot's menu (§5.8) below it with the current value checked. Settings' pickers, the PDF zoom,
/// tool, markup colour and font, the PDF export options and Find in Workspace's replace scope all use
/// it. With `previewsSelection`, highlighting a value previews it and closing the menu without
/// choosing restores the value it opened with.
struct MonknotPopUpButton<Value: View>: View {
    let label: String
    @Binding var selection: String
    let items: [MonknotPopUpItem]
    var actions: [MonknotPopUpAction] = []
    let theme: AppTheme
    let zoomScale: Double
    var leadingPaddingBase: CGFloat = MonknotPopUpLabel<Value>.leadingPaddingBase
    /// A fixed width, for a value that can be longer than its room (a font family); nil hugs the value.
    var width: CGFloat?
    var previewsSelection = false
    var onPreviewSelection: ((String) -> Void)?
    var onCancelPreview: (() -> Void)?
    /// Something the button opened is showing (Stroke Width's popover): it holds `press`, as while its
    /// menu shows (design.md §5.1).
    var isOpen = false
    /// The button's value, given the id it shows (the previewed value while the menu tracks).
    @ViewBuilder let value: (String) -> Value

    @State private var isMenuPresented = false
    @State private var previewedSelection: String?
    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isMenuPresented = true
        } label: {
            MonknotPopUpLabel(
                theme: theme,
                zoomScale: zoomScale,
                isHovered: isHovered,
                isOpen: isMenuPresented || isPressed || isOpen,
                leadingPaddingBase: leadingPaddingBase
            ) {
                value(previewedSelection ?? selection)
                    .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
            }
            .frame(width: width)
            .monknotFocusRing(
                isVisible: isFocused && isEnabled,
                cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale),
                theme: theme
            )
        }
        // Held, it draws `press`, as it does while its menu is open (design.md §5.1).
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusable(isEnabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .fixedSize(horizontal: width == nil, vertical: true)
        .background(
            MonknotMenuPresenter(
                isPresented: $isMenuPresented,
                selection: $selection,
                previewedSelection: $previewedSelection,
                items: items,
                actionGroups: [actions],
                previewsSelection: previewsSelection,
                onPreviewSelection: onPreviewSelection,
                onCancelPreview: onCancelPreview,
                theme: theme,
                zoomScale: zoomScale
            )
            .allowsHitTesting(false)
        )
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(items.first { $0.id == selection }?.title ?? "")
        .monknotPointerCursor(enabled: isEnabled)
    }
}

extension MonknotPopUpButton where Value == MonknotPopUpTitle {
    /// A pop-up whose value is its item's title, as wide as the longest title so previewing values
    /// never resizes the button.
    init(
        label: String,
        selection: Binding<String>,
        items: [MonknotPopUpItem],
        actions: [MonknotPopUpAction] = [],
        theme: AppTheme,
        zoomScale: Double,
        previewsSelection: Bool = false,
        onPreviewSelection: ((String) -> Void)? = nil,
        onCancelPreview: (() -> Void)? = nil
    ) {
        self.label = label
        self._selection = selection
        self.items = items
        self.actions = actions
        self.theme = theme
        self.zoomScale = zoomScale
        self.previewsSelection = previewsSelection
        self.onPreviewSelection = onPreviewSelection
        self.onCancelPreview = onCancelPreview
        self.value = { shown in
            MonknotPopUpTitle(
                title: items.first { $0.id == shown }?.title ?? "",
                reservedTitles: items.map(\.title),
                theme: theme,
                zoomScale: zoomScale
            )
        }
    }
}

/// The look of every pop-up (design.md §5.3): a value and a chevron on the control `track`, 28 tall, 10
/// leading and 8 trailing, the chevron 10 pt `ink3`. Hovered, the track takes the `hover` tint; while
/// its menu is open, the `press` fill. A disabled pop-up shows its track at half and `ink4`.
struct MonknotPopUpLabel<Value: View>: View {
    static var leadingPaddingBase: CGFloat { 10 }
    static var trailingPaddingBase: CGFloat { 8 }
    static var heightBase: CGFloat { MonknotMetrics.iconButtonSizeBase }

    let theme: AppTheme
    let zoomScale: Double
    var isHovered = false
    var isOpen = false
    /// 10 for text, whose side bearing adds optical space; 8 for a swatch or a glyph.
    var leadingPaddingBase: CGFloat = Self.leadingPaddingBase
    @ViewBuilder let value: () -> Value

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
        HStack(spacing: MonknotMetrics.interfaceDensity(6, theme: theme, zoomScale: zoomScale)) {
            value()
            Image(systemName: "chevron.down")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(MonknotMetrics.chevronPointSizeBase, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                // `ink3` at rest, `ink` with its control hovered or open (design.md §5.3).
                .monknotStateStyle(
                    !isEnabled ? theme.disabledForegroundColor
                        : (isHovered || isOpen) ? theme.foregroundColor : theme.tertiaryForegroundColor
                )
                .accessibilityHidden(true)
        }
        .padding(.leading, MonknotMetrics.interfaceDensity(leadingPaddingBase, theme: theme, zoomScale: zoomScale))
        .padding(.trailing, MonknotMetrics.interfaceDensity(Self.trailingPaddingBase, theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.interfaceControl(Self.heightBase, theme: theme, zoomScale: zoomScale))
        .background {
            shape.monknotStateStyle(isOpen && isEnabled ? theme.pressedFillColor : theme.controlTrackFillColor.opacity(isEnabled ? 1 : 0.5))
            shape.monknotStateStyle(isHovered && !isOpen && isEnabled ? theme.hoverFillColor : .clear)
        }
        .contentShape(shape)
        .environment(\.monknotPopUpDisabled, !isEnabled)
    }
}

private struct MonknotPopUpDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `MonknotPopUpLabel` for its value, so a value drawn by its owner can dim with it.
    var monknotPopUpDisabled: Bool {
        get { self[MonknotPopUpDisabledKey.self] }
        set { self[MonknotPopUpDisabledKey.self] = newValue }
    }
}

/// A pop-up's text value: 13 / 400 `ink` with tabular figures, as wide as its longest option when given
/// them, so previewing options never resizes the button.
struct MonknotPopUpTitle: View {
    let title: String
    let reservedTitles: [String]
    let theme: AppTheme
    let zoomScale: Double

    @Environment(\.monknotPopUpDisabled) private var isDisabled

    var body: some View {
        Text(title)
            .monknotReservingWidth(of: reservedTitles.isEmpty ? [title] : reservedTitles, alignment: .leading)
            .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
            .monospacedDigit()
            .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.foregroundColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A pop-up's glyph value (a tool): the segmented control's 16 pt glyph in `ink`, `ink4` disabled.
struct MonknotPopUpGlyph: View {
    let systemImage: String
    let theme: AppTheme
    let zoomScale: Double

    @Environment(\.monknotPopUpDisabled) private var isDisabled

    var body: some View {
        MonknotSystemGlyph(
            systemImage: systemImage,
            nominalPointSizeBase: MonknotSegmentButton.glyphPointSizeBase,
            theme: theme,
            zoomScale: zoomScale
        )
        .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.foregroundColor)
        .accessibilityHidden(true)
    }
}

/// Shows a control's menu (design.md §5.1, §5.3): Monknot's menu (§5.8) below the control, a pop-up's
/// values first, the current one checked, highlighted and in view, then groups of commands, each
/// after a separator. A menu button ("More") has only the commands. It opens on the turn after
/// `isPresented` becomes true, so the control draws its open fill first, and sets `isPresented` back
/// once the menu closes. With `previewsSelection`, highlighting a value previews it and closing the
/// menu without choosing one cancels the preview.
struct MonknotMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    var selection: Binding<String>?
    var previewedSelection: Binding<String?>?
    var items: [MonknotPopUpItem] = []
    var actionGroups: [[MonknotPopUpAction]] = []
    var previewsSelection = false
    var onPreviewSelection: ((String) -> Void)?
    var onCancelPreview: (() -> Void)?
    let theme: AppTheme
    let zoomScale: Double

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

        // Presented on the next turn, so the control shows its open fill before the menu opens.
        context.coordinator.isPresentationScheduled = true
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator else { return }
            coordinator.isPresentationScheduled = false
            guard coordinator.parent.isPresented else { return }
            coordinator.presentMenu(from: nsView)
        }
    }

    /// A menu never outlives its control: its commands would act on a view that is gone.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard coordinator.isTracking else { return }
        MonknotContextMenuController.shared.close(animated: false)
    }

    @MainActor
    final class Coordinator {
        var parent: MonknotMenuPresenter
        var isTracking = false
        var isPresentationScheduled = false
        /// The value each row of the menu being shown chooses, by entry.
        private(set) var values: [Int: String] = [:]

        init(parent: MonknotMenuPresenter) {
            self.parent = parent
        }

        /// The menu's rows for the current values and commands.
        func makeEntries() -> [MonknotContextMenuModel.Entry] {
            let current = parent.selection?.wrappedValue
            var entries: [MonknotContextMenuModel.Entry] = []
            values = [:]
            for option in parent.items {
                values[entries.count] = option.id
                entries.append(.item(MonknotContextMenuModel.Item(
                    title: option.title,
                    systemImage: option.systemImage,
                    swatch: option.swatch,
                    isEnabled: true,
                    isDestructive: false,
                    isValue: true,
                    isChecked: option.id == current,
                    perform: { [weak self] in self?.commit(option.id) }
                )))
            }
            for group in parent.actionGroups where !group.isEmpty {
                if !entries.isEmpty {
                    entries.append(.separator)
                }
                for command in group {
                    let known = MonknotMenuCommand(rawValue: command.title)
                    entries.append(.item(MonknotContextMenuModel.Item(
                        title: command.title,
                        systemImage: command.systemImage ?? known?.systemImage,
                        isEnabled: command.isEnabled,
                        isDestructive: known?.isDestructive == true,
                        perform: command.action
                    )))
                }
            }
            return entries
        }

        func presentMenu(from anchor: NSView) {
            guard !isTracking else { return }
            let presented = MonknotContextMenuController.shared.presentMenu(
                makeEntries(),
                below: anchor,
                theme: parent.theme,
                zoomScale: parent.zoomScale,
                maximumHeightBase: parent.items.isEmpty ? nil : MonknotContextMenuLayout.valueMenuMaximumHeightBase,
                onHighlight: { [weak self] in self?.highlight($0) },
                onClose: { [weak self] in self?.finishTracking(chosen: $0) }
            )
            if presented {
                isTracking = true
            } else {
                parent.isPresented = false
            }
        }

        /// The highlight reached the row at `index`: a value previews where the control previews.
        func highlight(_ index: Int?) {
            guard parent.previewsSelection, let index, let value = values[index] else { return }
            parent.previewedSelection?.wrappedValue = value
            parent.onPreviewSelection?(value)
        }

        /// The menu closed, choosing the row at `chosen` or nothing: a preview that no value chose is
        /// cancelled, and the control closes. A chosen value shows at once; it is committed as the menu
        /// leaves.
        func finishTracking(chosen: Int?) {
            isTracking = false
            if let chosen, let value = values[chosen] {
                parent.previewedSelection?.wrappedValue = value
            } else {
                if parent.previewsSelection {
                    parent.onCancelPreview?()
                }
                parent.previewedSelection?.wrappedValue = nil
            }
            parent.isPresented = false
        }

        private func commit(_ value: String) {
            parent.selection?.wrappedValue = value
            parent.previewedSelection?.wrappedValue = nil
        }
    }
}
