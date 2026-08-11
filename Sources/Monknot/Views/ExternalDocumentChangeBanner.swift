import MonknotCore
import SwiftUI

struct ExternalDocumentChangeBanner: View {
    let isRemovedExternally: Bool
    let isSaving: Bool
    let documentKind: WorkspaceDocumentKind?
    let visualReviewEnabled: Bool
    let theme: AppTheme
    let zoomScale: Double
    let review: () -> Void
    let saveTextCopy: () -> Void
    let keepLocalText: () -> Void
    let useDiskText: () -> Void
    let reloadPDF: () -> Void
    let savePDFCopy: () -> Void

    @State private var isConfirmingPDFReload = false
    @State private var isConfirmingTextUseDisk = false

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
            } else if visualReviewEnabled {
                MonknotAccentButton(
                    title: "Review Changes…",
                    theme: theme,
                    isDisabled: isSaving,
                    action: review
                )
            } else {
                MonknotActionButton(
                    title: "Save a Copy…",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving,
                    action: saveTextCopy
                )
                MonknotActionButton(
                    title: "Keep Mine",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving,
                    action: keepLocalText
                )
                MonknotActionButton(
                    title: "Use Disk",
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving || isRemovedExternally
                ) {
                    isConfirmingTextUseDisk = true
                }
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
        .confirmationDialog(
            "Use the Disk Version?",
            isPresented: $isConfirmingTextUseDisk,
            titleVisibility: .visible
        ) {
            Button("Use Disk", role: .destructive, action: useDiskText)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces your unsaved local text with the latest validated disk copy.")
        }
    }

}

struct ExternalDocumentReconciliationSheet: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let zoomScale: Double
    let saveCopy: () -> Void

    @State private var showsBaseline = false

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
                    Text("Disk → Mine · \(state.displayName)")
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.foregroundColor.opacity(0.68))
                }

                if state.review.diskRevision == nil {
                    Label(
                        "The disk file is missing. The diff shows your retained local text as additions.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor.opacity(0.72))
                }

                unifiedDiff(state.diskToMineDiff)
                    .frame(minHeight: scaled(330))

                DisclosureGroup(isExpanded: $showsBaseline) {
                    baselinePane(state.review.baselineText)
                        .padding(.top, scaled(8))
                } label: {
                    Text("Show baseline used for three-way comparison")
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                }

                HStack(spacing: scaled(10)) {
                    if state.hasMergeConflict {
                        Label("Monknot could not prove a safe nonoverlapping merge. Choose one version or reconcile manually.", systemImage: "exclamationmark.triangle")
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

                    Button("Save a Copy…", action: saveCopy)

                    Button("Cancel") {
                        store.cancelExternalDocumentReview()
                    }
                    .keyboardShortcut(.cancelAction)

                    if state.canMerge {
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
            .frame(minWidth: scaled(760), minHeight: scaled(520))
            .background(theme.surfaceColor)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func unifiedDiff(_ diff: ExternalDocumentUnifiedDiff?) -> some View {
        ScrollView([.horizontal, .vertical]) {
            if let diff, diff.hasChanges {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        Text("@@ −\(hunk.oldStartLine),\(hunk.oldLineCount) +\(hunk.newStartLine),\(hunk.newLineCount) @@")
                            .foregroundStyle(theme.accentColor)
                            .padding(.vertical, scaled(5))
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            diffRow(line)
                        }
                    }
                }
                .padding(scaled(10))
                .textSelection(.enabled)
            } else {
                Text("Disk and local text are identical.")
                    .foregroundStyle(theme.foregroundColor.opacity(0.65))
                    .padding(scaled(14))
            }
        }
        .font(.system(size: scaled(12), design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.elevatedSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
        .accessibilityLabel("Unified diff from disk to my version")
    }

    private func diffRow(_ line: ExternalDocumentDiffLine) -> some View {
        let foreground: Color
        let background: Color
        switch line.kind {
        case .removal:
            foreground = theme.isDark ? Color(red: 1, green: 0.65, blue: 0.65) : Color(red: 0.58, green: 0.08, blue: 0.10)
            background = Color.red.opacity(theme.isDark ? 0.14 : 0.09)
        case .addition:
            foreground = theme.isDark ? Color(red: 0.58, green: 0.90, blue: 0.66) : Color(red: 0.04, green: 0.42, blue: 0.15)
            background = Color.green.opacity(theme.isDark ? 0.13 : 0.08)
        case .context:
            foreground = theme.foregroundColor.opacity(0.78)
            background = .clear
        }

        return HStack(spacing: scaled(8)) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: scaled(38), alignment: .trailing)
                .foregroundStyle(theme.foregroundColor.opacity(0.42))
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: scaled(38), alignment: .trailing)
                .foregroundStyle(theme.foregroundColor.opacity(0.42))
            Text(line.indicator)
                .fontWeight(line.kind == .context ? .regular : .bold)
                .accessibilityLabel(line.kind == .removal ? "Removed" : line.kind == .addition ? "Added" : "Context")
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
            if !line.hasTerminatingNewline {
                Text("⏎ no newline")
                    .foregroundStyle(theme.foregroundColor.opacity(0.48))
            }
        }
        .foregroundStyle(foreground)
        .padding(.vertical, scaled(1))
        .padding(.horizontal, scaled(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func baselinePane(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text.isEmpty ? " " : text)
                .font(.system(size: scaled(12), design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(scaled(10))
        }
        .frame(maxWidth: .infinity, minHeight: scaled(100), maxHeight: scaled(180), alignment: .topLeading)
        .background(theme.elevatedSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }
}
