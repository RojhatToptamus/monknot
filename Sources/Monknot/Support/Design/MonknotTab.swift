import MonknotCore
import SwiftUI

/// The one tab (design.md §10.3), for files in the titlebar and terminal sessions in their card's bar:
/// `10 padding · 15 glyph in the 18 column · 8 gap · 13 / 400 label · 10 padding`, 28 tall, radius 8,
/// hugging its label, 3 apart, so a file reads the same in a tab as in a sidebar row.
///
/// While the pointer is over a tab that can close, its close button takes the glyph's place, as
/// Safari's does: no slot is reserved, so hovering never moves a label and an inactive tab costs only
/// its name. The glyph column also carries the tab's state: a 6 pt `accent` dot on its corner while
/// unsaved, a spinner while saving, a `danger` triangle when saving failed.
struct MonknotTab: View {
    /// Where the strip sits decides how the active tab stands out.
    enum Placement {
        /// The titlebar: the active tab is the chip lifted out of the chrome (§5.5), its glyph `accent`.
        case chrome
        /// Inside a card (the terminal): the active tab takes the neutral `selected` fill, as a
        /// selected row does.
        case card
    }

    typealias Status = MonknotDocumentStatus

    /// A mark after the label: the tab is pinned, or its file is missing on disk.
    enum Badge: Hashable {
        case pinned
        case warning

        var systemImage: String {
            switch self {
            case .pinned: return "pin.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    static let heightBase: CGFloat = MonknotMetrics.rowHeightBase
    static let paddingBase: CGFloat = 10
    static let glyphGapBase: CGFloat = MonknotMetrics.rowGlyphGapBase
    static let spacingBase: CGFloat = 3
    static let badgePointSizeBase: CGFloat = 10

    let title: String
    let systemImage: String
    let isSelected: Bool
    let placement: Placement
    var status: Status = .clean
    /// Replaces the glyph's resting colour: a terminal's run state, a file missing on disk.
    var glyphTint: Color?
    var badges: [Badge] = []
    var isDisabled = false
    var isDragging = false
    /// The close button's label, or nil when the tab cannot be closed from the strip (a pinned file).
    var closeLabel: String?
    let theme: AppTheme
    let zoomScale: Double
    let select: () -> Void
    var close: () -> Void = {}

    @State private var isHovered = false
    @State private var isPressed = false

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyph(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
    }

    private var showsClose: Bool {
        isHovered && closeLabel != nil && !isDisabled
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: density(Self.glyphGapBase)) {
                // The glyph column is drawn over the button, so the close button is not nested in it.
                Color.clear
                    .frame(width: glyphColumn, height: glyphColumn)

                // Already fitted by the owner where a cap applies; never truncated again here.
                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .monknotStateStyle(textColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ForEach(badges, id: \.self) { badge in
                    Image(systemName: badge.systemImage)
                        .font(.system(size: glyph(Self.badgePointSizeBase), weight: .regular))
                        .foregroundStyle(badgeColor(badge))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, density(Self.paddingBase))
            .frame(height: MonknotMetrics.interfaceControl(Self.heightBase, theme: theme, zoomScale: zoomScale))
            .contentShape(shape)
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .disabled(isDisabled)
        .overlay(alignment: .leading) {
            glyphSlot
                .frame(width: glyphColumn, height: glyphColumn)
                .padding(.leading, density(Self.paddingBase))
        }
        .background { background }
        .fixedSize()
        .opacity(isDragging ? 0.45 : 1)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .modifier(MonknotTabCloseAction(label: isDisabled ? nil : closeLabel, close: close))
    }

    private var glyphColumn: CGFloat {
        glyph(MonknotMetrics.rowIconColumnWidthBase)
    }

    /// Under the pointer, close crossfades with the glyph in the same place. Only colour and
    /// opacity animate, so a tab that moves as another opens or closes moves at once.
    private var glyphSlot: some View {
        ZStack {
            MonknotDocumentGlyph(systemImage: systemImage, status: status, color: glyphColor, theme: theme, zoomScale: zoomScale)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .monknotStateOpacity(showsClose ? 0 : 1)
            if let closeLabel {
                MonknotTabCloseButton(label: closeLabel, theme: theme, zoomScale: zoomScale, isVisible: showsClose, action: close)
                    .accessibilityHidden(true)
            }
        }
    }

    private var background: some View {
        ZStack {
            switch placement {
            case .chrome:
                MonknotChip(
                    cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale),
                    theme: theme
                )
                .monknotStateOpacity(isSelected ? 1 : 0)
            case .card:
                shape.monknotStateStyle(isSelected ? theme.chromeSelectedFillColor : .clear)
            }
            shape.monknotStateStyle(stateFill)
        }
    }

    /// Hover and pressed tint a tab that is not the current one.
    private var stateFill: Color {
        guard !isSelected, !isDisabled else { return .clear }
        if isPressed {
            return theme.pressedFillColor
        }
        return isHovered ? theme.hoverFillColor : .clear
    }

    /// design.md §1.4: the label rests at `ink2` and goes to `ink` hovered or active; `ink4` disabled.
    private var textColor: Color {
        if isSelected {
            return theme.foregroundColor
        }
        if isDisabled {
            return theme.disabledForegroundColor
        }
        return isHovered ? theme.foregroundColor : theme.mutedForegroundColor
    }

    /// The glyph rests at `ink3` and goes to `ink` hovered; the active file tab's glyph is `accent`
    /// (§1.3, place 1). A tint (run state, missing file) is information, so it wins.
    private var glyphColor: Color {
        if let glyphTint {
            return glyphTint
        }
        if isSelected {
            return placement == .chrome ? theme.accentColor : theme.foregroundColor
        }
        if isDisabled {
            return theme.disabledForegroundColor
        }
        return isHovered ? theme.foregroundColor : theme.tertiaryForegroundColor
    }

    private func badgeColor(_ badge: Badge) -> Color {
        switch badge {
        case .warning:
            return theme.dangerColor
        case .pinned:
            return isDisabled ? theme.disabledForegroundColor : theme.tertiaryForegroundColor
        }
    }
}

/// Close appears only under the pointer, so VoiceOver and keyboard users reach it as a named action.
private struct MonknotTabCloseAction: ViewModifier {
    let label: String?
    let close: () -> Void

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityAction(named: label, close)
        } else {
            content
        }
    }
}

/// A document's save state, as its glyph shows it in a tab or a sidebar row.
enum MonknotDocumentStatus: Equatable {
    case clean
    case edited
    case saving
    case failed

    init(_ saveState: DocumentSaveState) {
        switch saveState {
        case .clean: self = .clean
        case .edited: self = .edited
        case .saving: self = .saving
        case .failed: self = .failed
        }
    }
}

/// A document's kind glyph in the 18 column, carrying its save state (design.md §1.3, §10.3): a 6 pt
/// `accent` dot on its corner while unsaved, a spinner in its place while saving, a `danger` triangle
/// when saving failed. Tabs and sidebar rows draw the same mark.
struct MonknotDocumentGlyph: View {
    let systemImage: String
    var status: MonknotDocumentStatus = .clean
    let color: Color
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        let column = MonknotMetrics.interfaceGlyph(MonknotMetrics.rowIconColumnWidthBase, theme: theme, zoomScale: zoomScale)
        Group {
            switch status {
            case .saving:
                MonknotProgressIndicator(
                    size: MonknotMetrics.interfaceControl(MonknotMetrics.inlineSpinnerSizeBase, theme: theme, zoomScale: zoomScale),
                    theme: theme
                )
            case .failed:
                MonknotSystemGlyph(
                    systemImage: "exclamationmark.triangle.fill",
                    nominalPointSizeBase: MonknotMetrics.sidebarIconPointSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                .foregroundStyle(theme.dangerColor)
            case .clean, .edited:
                // Ink changes fade over the hover duration, as a row's label does (design.md §5.6).
                MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                    .monknotStateStyle(color)
                    .frame(width: column, height: column)
                    .monknotDirtyDot(isVisible: status == .edited, theme: theme, zoomScale: zoomScale)
            }
        }
        .frame(width: column, height: column)
    }
}
