import AppKit
import MonknotCore
import SwiftUI

/// A value a pop-up button chooses; `image` shows beside its title in the menu (a colour's swatch).
struct MonknotPopUpItem: Identifiable, Equatable {
    let id: String
    let title: String
    var image: NSImage?
}

/// A command listed after a pop-up's values, below a separator ("Stroke Width…").
struct MonknotPopUpAction: Identifiable {
    let title: String
    let action: () -> Void

    var id: String { title }
}

/// The one pop-up button (design.md §5.3): the value and a chevron on the control `track`, opening a
/// native menu with the current value checked and placed over the button, as `NSPopUpButton` does.
/// Settings' pickers, the PDF zoom, markup colour and font, and Find in Workspace's replace scope all
/// use it. With `previewsSelection`, highlighting a value previews it and closing the menu without
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
    /// The button's value, given the id it shows (the previewed value while the menu tracks).
    @ViewBuilder let value: (String) -> Value

    @State private var isMenuPresented = false
    @State private var previewedSelection: String?
    @State private var isHovered = false
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
                isOpen: isMenuPresented,
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
        .buttonStyle(.plain)
        .focusable(isEnabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .fixedSize(horizontal: width == nil, vertical: true)
        .background(
            MonknotPopUpMenuPresenter(
                isPresented: $isMenuPresented,
                selection: $selection,
                previewedSelection: $previewedSelection,
                items: items,
                actions: actions,
                previewsSelection: previewsSelection,
                onPreviewSelection: onPreviewSelection,
                onCancelPreview: onCancelPreview
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
        placeholder: String = "",
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
                title: items.first { $0.id == shown }?.title ?? placeholder,
                reservedTitles: items.map(\.title) + (placeholder.isEmpty ? [] : [placeholder]),
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
    var isDisabled = false
    /// 10 for text, whose side bearing adds optical space; 8 for a swatch or a glyph.
    var leadingPaddingBase: CGFloat = Self.leadingPaddingBase
    @ViewBuilder let value: () -> Value

    @Environment(\.isEnabled) private var isEnabled

    private var disabled: Bool {
        isDisabled || !isEnabled
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
        HStack(spacing: MonknotMetrics.interfaceDensity(6, theme: theme, zoomScale: zoomScale)) {
            value()
            Image(systemName: "chevron.down")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(MonknotMetrics.chevronPointSizeBase, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .foregroundStyle(disabled ? theme.disabledForegroundColor : theme.tertiaryForegroundColor)
                .accessibilityHidden(true)
        }
        .padding(.leading, MonknotMetrics.interfaceDensity(leadingPaddingBase, theme: theme, zoomScale: zoomScale))
        .padding(.trailing, MonknotMetrics.interfaceDensity(Self.trailingPaddingBase, theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.interfaceControl(Self.heightBase, theme: theme, zoomScale: zoomScale))
        .background {
            shape.fill(isOpen && !disabled ? theme.pressedFillColor : theme.controlTrackFillColor.opacity(disabled ? 0.5 : 1))
            if isHovered, !isOpen, !disabled {
                shape.fill(theme.hoverFillColor)
            }
        }
        .contentShape(shape)
        .environment(\.monknotPopUpDisabled, disabled)
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isOpen)
    }
}

extension MonknotPopUpLabel where Value == MonknotPopUpTitle {
    /// A pop-up label whose value is text, in the chrome label style.
    init(
        title: String,
        reservingWidthOf titles: [String] = [],
        theme: AppTheme,
        zoomScale: Double,
        isHovered: Bool = false,
        isOpen: Bool = false,
        isDisabled: Bool = false
    ) {
        self.theme = theme
        self.zoomScale = zoomScale
        self.isHovered = isHovered
        self.isOpen = isOpen
        self.isDisabled = isDisabled
        self.value = {
            MonknotPopUpTitle(title: title, reservedTitles: titles, theme: theme, zoomScale: zoomScale)
        }
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

/// What a pop-up's menu has chosen so far: highlighted values preview, and only a chosen one stays.
struct MonknotPopUpSelectionTransaction: Equatable {
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

private struct MonknotPopUpMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var selection: String
    @Binding var previewedSelection: String?
    let items: [MonknotPopUpItem]
    let actions: [MonknotPopUpAction]
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

        // Presented on the next turn, so the button shows its open fill before the menu tracks.
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
        var parent: MonknotPopUpMenuPresenter
        var isTracking = false
        var isPresentationScheduled = false
        private var transaction: MonknotPopUpSelectionTransaction?

        init(parent: MonknotPopUpMenuPresenter) {
            self.parent = parent
        }

        func presentMenu(from anchor: NSView) {
            guard !isTracking else { return }

            let initialSelection = parent.selection
            transaction = MonknotPopUpSelectionTransaction(initialSelection: initialSelection)

            let menu = NSMenu(title: parent.selection)
            menu.autoenablesItems = false
            menu.delegate = self
            menu.minimumWidth = anchor.bounds.width

            for option in parent.items {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(commitSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.image = option.image
                item.state = option.id == initialSelection ? .on : .off
                menu.addItem(item)
            }

            if !parent.actions.isEmpty {
                menu.addItem(.separator())
                for (index, action) in parent.actions.enumerated() {
                    let item = NSMenuItem(
                        title: action.title,
                        action: #selector(performAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    menu.addItem(item)
                }
            }

            // The current value opens over the button; with none (a zoom between presets) the menu
            // drops below it.
            let positioningItem = menu.items.first { ($0.representedObject as? String) == initialSelection }
            isTracking = true
            _ = menu.popUp(
                positioning: positioningItem,
                at: NSPoint(x: 0, y: positioningItem == nil ? 0 : anchor.bounds.maxY),
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

        @objc private func performAction(_ sender: NSMenuItem) {
            guard parent.actions.indices.contains(sender.tag) else { return }
            parent.actions[sender.tag].action()
        }
    }
}
