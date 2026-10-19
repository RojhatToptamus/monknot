import AppKit
import MonknotCore
import SwiftUI

/// A value a pop-up button chooses; `image` shows beside its title in the menu (a colour's swatch).
struct MonknotPopUpItem: Identifiable, Equatable {
    let id: String
    let title: String
    var image: NSImage?
}

/// A command in a native menu: after a pop-up's values, below a separator ("Stroke Width…"), or in a
/// menu button's menu ("More"), with its glyph.
struct MonknotPopUpAction: Identifiable {
    let title: String
    var systemImage: String?
    var isEnabled = true
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
            MonknotMenuPresenter(
                isPresented: $isMenuPresented,
                selection: $selection,
                previewedSelection: $previewedSelection,
                items: items,
                actionGroups: [actions],
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
                .monknotStateStyle(isEnabled ? theme.tertiaryForegroundColor : theme.disabledForegroundColor)
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

/// Shows a native menu from a SwiftUI control (design.md §5.1, §5.3): a pop-up's values, the current
/// one checked and the menu opened over the control with it under the pointer, as `NSPopUpButton` does,
/// then groups of commands, each after a separator. A command menu ("More") drops below its button. It
/// opens on the turn after `isPresented` becomes true, so the control draws its open fill first, and
/// sets `isPresented` back once the menu closes. With `previewsSelection`, highlighting a value previews
/// it and closing the menu without choosing cancels the preview.
struct MonknotMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    var selection: Binding<String>?
    var previewedSelection: Binding<String?>?
    var items: [MonknotPopUpItem] = []
    var actionGroups: [[MonknotPopUpAction]] = []
    var previewsSelection = false
    var onPreviewSelection: ((String) -> Void)?
    var onCancelPreview: (() -> Void)?

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

        // Presented on the next turn, so the control shows its open fill before the menu tracks.
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
        var parent: MonknotMenuPresenter
        var isTracking = false
        var isPresentationScheduled = false
        /// The commands of the menu being shown, by item tag.
        private var commands: [MonknotPopUpAction] = []
        private var didChooseValue = false

        init(parent: MonknotMenuPresenter) {
            self.parent = parent
        }

        /// The menu for the current values and commands; showing it starts a new choice.
        func makeMenu(minimumWidth: CGFloat) -> NSMenu {
            didChooseValue = false
            commands = []
            let current = parent.selection?.wrappedValue

            let menu = NSMenu(title: current ?? "")
            menu.autoenablesItems = false
            menu.delegate = self
            menu.minimumWidth = minimumWidth

            for option in parent.items {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(commitSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.image = option.image
                item.state = option.id == current ? .on : .off
                menu.addItem(item)
            }

            for group in parent.actionGroups where !group.isEmpty {
                if !menu.items.isEmpty {
                    menu.addItem(.separator())
                }
                for command in group {
                    let item = NSMenuItem(
                        title: command.title,
                        action: #selector(performCommand(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = commands.count
                    item.image = command.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: nil)
                    }
                    item.isEnabled = command.isEnabled
                    menu.addItem(item)
                    commands.append(command)
                }
            }
            return menu
        }

        func presentMenu(from anchor: NSView) {
            guard !isTracking else { return }

            // A menu of commands (More) is Monknot's own menu, as a context menu is (design.md §5.8);
            // a pop-up's values stay the system's menu, placed over the control.
            if parent.items.isEmpty, parent.selection == nil,
               MonknotContextMenuController.shared.presentCommands(
                   parent.actionGroups,
                   below: anchor,
                   onClose: { [weak self] in
                       self?.isTracking = false
                       self?.finishTracking()
                   }
               ) {
                isTracking = true
                return
            }

            let menu = makeMenu(minimumWidth: anchor.bounds.width)
            // The current value opens over the control; with none (a zoom between presets, a command
            // menu) the menu drops below it.
            let current = parent.selection?.wrappedValue
            let positioningItem = current.flatMap { current in
                menu.items.first { ($0.representedObject as? String) == current }
            }
            isTracking = true
            _ = menu.popUp(
                positioning: positioningItem,
                at: NSPoint(x: 0, y: positioningItem == nil ? 0 : anchor.bounds.maxY),
                in: anchor
            )
            isTracking = false
            finishTracking()
        }

        /// The menu closed: a preview that nothing chose is cancelled, and the control closes.
        func finishTracking() {
            if parent.previewsSelection, !didChooseValue {
                parent.onCancelPreview?()
            }
            parent.previewedSelection?.wrappedValue = nil
            parent.isPresented = false
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard parent.previewsSelection,
                  let selection = item?.representedObject as? String else {
                return
            }
            parent.previewedSelection?.wrappedValue = selection
            parent.onPreviewSelection?(selection)
        }

        @objc private func commitSelection(_ sender: NSMenuItem) {
            guard let selection = sender.representedObject as? String else { return }
            didChooseValue = true
            parent.selection?.wrappedValue = selection
            parent.previewedSelection?.wrappedValue = nil
        }

        @objc private func performCommand(_ sender: NSMenuItem) {
            guard commands.indices.contains(sender.tag) else { return }
            commands[sender.tag].action()
        }
    }
}
