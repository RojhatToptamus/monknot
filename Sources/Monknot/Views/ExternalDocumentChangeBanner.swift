import MonknotCore
import SwiftUI

struct ExternalDocumentChangeBanner: View {
    let isRemovedExternally: Bool
    let isSaving: Bool
    let documentKind: WorkspaceDocumentKind?
    let theme: AppTheme
    let zoomScale: Double
    let review: () -> Void
    let reloadPDF: () -> Void
    let savePDFCopy: () -> Void

    @State private var isConfirmingPDFReload = false

    private var isPDF: Bool {
        documentKind == .pdf
    }

    private var message: String {
        if isRemovedExternally {
            return "This file was removed from the workspace while you have unsaved changes."
        }
        return "This file changed on disk while you have unsaved changes."
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(12)) {
            Image(systemName: isRemovedExternally ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: scaled(14), weight: .semibold))
                .foregroundStyle(theme.accentColor)

            Text(message)
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isPDF {
                MonknotActionButton(
                    title: "Save Copy",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving,
                    action: savePDFCopy
                )
                MonknotActionButton(
                    title: "Reload…",
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving || isRemovedExternally
                ) {
                    isConfirmingPDFReload = true
                }
            } else {
                MonknotAccentButton(
                    title: "Review Changes…",
                    theme: theme,
                    isDisabled: isSaving,
                    action: review
                )
            }
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(10))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                .strokeBorder(theme.accentColor.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, scaled(12))
        .padding(.top, scaled(8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .confirmationDialog(
            "Reload PDF from Disk?",
            isPresented: $isConfirmingPDFReload,
            titleVisibility: .visible
        ) {
            Button("Reload from Disk", role: .destructive, action: reloadPDF)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards your unsaved PDF annotations. You can save them as a copy first.")
        }
    }

}

struct ExternalDocumentReconciliationSheet: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        if let state = store.externalDocumentReview {
            VStack(alignment: .leading, spacing: scaled(16)) {
                VStack(alignment: .leading, spacing: scaled(4)) {
                    Text("Review External Changes")
                        .font(MonknotTypography.panelTitle(theme: theme))
                        .foregroundStyle(theme.foregroundColor)
                    Text("Compare the last loaded text, your local edits, and the current disk copy of \(state.displayName). Nothing is written until you save.")
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.foregroundColor.opacity(0.68))
                }

                HStack(spacing: scaled(10)) {
                    revisionPane(
                        title: "Baseline",
                        subtitle: "Last loaded",
                        text: state.review.baselineText,
                        changed: false
                    )
                    revisionPane(
                        title: "Local",
                        subtitle: state.review.localText == state.review.baselineText ? "Unchanged" : "Edited",
                        text: state.review.localText,
                        changed: state.review.localText != state.review.baselineText
                    )
                    revisionPane(
                        title: "Disk",
                        subtitle: diskSubtitle(for: state),
                        text: state.review.diskText ?? "This file is no longer on disk.",
                        changed: state.review.diskText != state.review.baselineText
                    )
                }
                .frame(minHeight: scaled(360))

                HStack(spacing: scaled(10)) {
                    if state.review.diskRevision != nil, state.review.mergedText == nil {
                        Label("The local and disk edits overlap. Choose one complete version or cancel and reconcile manually.", systemImage: "exclamationmark.triangle")
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .foregroundStyle(theme.foregroundColor.opacity(0.68))
                    } else if state.review.diskRevision != nil,
                              state.review.mergedText != state.review.localText,
                              state.review.mergedText != state.review.diskText {
                        Label("The edits are disjoint and can be merged safely.", systemImage: "checkmark.circle")
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .foregroundStyle(theme.foregroundColor.opacity(0.68))
                    }

                    Spacer()

                    Button("Cancel") {
                        store.cancelExternalDocumentReview()
                    }
                    .keyboardShortcut(.cancelAction)

                    if state.review.diskRevision != nil,
                       state.review.mergedText != nil,
                       state.review.mergedText != state.review.localText,
                       state.review.mergedText != state.review.diskText {
                        Button("Merge") {
                            store.resolveExternalDocumentReview(.merge)
                        }
                    }

                    Button("Keep Mine") {
                        store.resolveExternalDocumentReview(.keepLocal)
                    }

                    Button("Use Disk", role: .destructive) {
                        store.resolveExternalDocumentReview(.useDisk)
                    }
                    .disabled(state.review.diskRevision == nil)
                }
            }
            .padding(scaled(20))
            .frame(minWidth: scaled(880), minHeight: scaled(540))
            .background(theme.surfaceColor)
        } else {
            EmptyView()
        }
    }

    private func diskSubtitle(for state: ExternalDocumentReviewState) -> String {
        guard let diskText = state.review.diskText else { return "Removed" }
        return diskText == state.review.baselineText ? "Unchanged" : "Changed"
    }

    private func revisionPane(
        title: String,
        subtitle: String,
        text: String,
        changed: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(MonknotTypography.settingsSectionTitle(theme: theme))
                    .foregroundStyle(theme.foregroundColor)
                Spacer()
                Text(subtitle)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(changed ? theme.accentColor : theme.foregroundColor.opacity(0.62))
            }

            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text.isEmpty ? " " : text)
                    .font(.system(size: scaled(12), design: .monospaced))
                    .foregroundStyle(theme.foregroundColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(scaled(10))
            }
            .background(theme.elevatedSurfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .strokeBorder(changed ? theme.accentColor.opacity(0.45) : theme.borderColor, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
