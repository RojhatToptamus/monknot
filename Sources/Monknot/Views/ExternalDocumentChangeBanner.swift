import MonknotCore
import SwiftUI

struct ExternalDocumentDiffSummary: Equatable {
    let addedLineCount: Int
    let removedLineCount: Int

    init(diff: ExternalDocumentUnifiedDiff?) {
        let lines = diff?.hunks.flatMap(\.lines) ?? []
        addedLineCount = lines.lazy.filter { $0.kind == .addition }.count
        removedLineCount = lines.lazy.filter { $0.kind == .removal }.count
    }
}

struct ExternalDocumentDiffLayoutMetrics: Equatable {
    let rowHeight: CGFloat
    let hunkHeaderHeight: CGFloat
    let oldLineNumberWidth: CGFloat
    let newLineNumberWidth: CGFloat
    let markerWidth: CGFloat
    let horizontalInset: CGFloat
    let codeFontSize: CGFloat
    let codeCharacterWidth: CGFloat

    init(theme: AppTheme, zoomScale: Double) {
        rowHeight = MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale)
        hunkHeaderHeight = MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
        oldLineNumberWidth = MonknotMetrics.interfaceDensity(42, theme: theme, zoomScale: zoomScale)
        newLineNumberWidth = MonknotMetrics.interfaceDensity(42, theme: theme, zoomScale: zoomScale)
        markerWidth = MonknotMetrics.interfaceDensity(28, theme: theme, zoomScale: zoomScale)
        horizontalInset = MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: zoomScale)
        codeFontSize = MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)
        codeCharacterWidth = codeFontSize * 0.72
    }

    func height(for _: ExternalDocumentDiffLine) -> CGFloat {
        rowHeight
    }

    func contentWidth(for diff: ExternalDocumentUnifiedDiff, viewportWidth: CGFloat) -> CGFloat {
        let longestLine = diff.hunks
            .lazy
            .flatMap(\.lines)
            .map { line in
                visualColumnCount(in: line.text) + (line.hasTerminatingNewline ? 0 : 13)
            }
            .max() ?? 0
        let gutterWidth = oldLineNumberWidth + newLineNumberWidth + markerWidth
        let textWidth = CGFloat(max(longestLine, 1)) * codeCharacterWidth
        return max(viewportWidth, gutterWidth + horizontalInset * 2 + textWidth)
    }

    private func visualColumnCount(in text: String) -> Int {
        var column = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 9 {
                column += 4 - (column % 4)
            } else if scalar.value >= 0x1100 {
                column += 2
            } else {
                column += 1
            }
        }
        return column
    }
}

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
        HStack(spacing: scaled(MonknotMetrics.Spacing.l)) {
            Image(systemName: isRemovedExternally ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(15, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(isRemovedExternally ? removedColor : theme.accentColor)
                .frame(width: scaled(18))

            Text(message)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isPDF {
                MonknotActionButton(
                    title: "Save a Copy…",
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
                MonknotActionButton(
                    title: "Review Changes…",
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale,
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
                    role: .destructive,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isSaving || isRemovedExternally
                ) {
                    isConfirmingTextUseDisk = true
                }
            }
        }
        .padding(.horizontal, scaled(16))
        .padding(.vertical, scaled(8))
        .frame(maxWidth: .infinity, minHeight: scaled(46))
        .background(isRemovedExternally ? removedColor.opacity(theme.isDark ? 0.12 : 0.10) : theme.selectedRowColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isRemovedExternally ? removedColor.opacity(theme.isDark ? 0.22 : 0.20) : theme.borderColor)
                .frame(height: 1)
        }
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

    private var removedColor: Color {
        Color(hex: theme.semanticColors.diffRemoved)
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
            VStack(alignment: .leading, spacing: 0) {
                sheetHeader

                VStack(alignment: .leading, spacing: scaled(12)) {
                    diffSurface(state)
                        .frame(minHeight: scaled(300))

                    DisclosureGroup(isExpanded: $showsBaseline) {
                        baselinePane(state.review.baselineText)
                            .padding(.top, scaled(8))
                    } label: {
                        Text("Baseline used for three-way comparison")
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .foregroundStyle(theme.mutedForegroundColor)
                    }
                    .tint(theme.mutedForegroundColor)
                }
                .padding(.horizontal, scaled(16))
                .padding(.vertical, scaled(14))
                .frame(maxHeight: .infinity, alignment: .top)

                footer(state)
            }
            .frame(
                minWidth: scaled(680),
                idealWidth: scaled(820),
                maxWidth: scaled(980),
                minHeight: scaled(460),
                idealHeight: scaled(560),
                maxHeight: scaled(720)
            )
            .background(theme.surfaceColor)
            .onExitCommand {
                store.cancelExternalDocumentReview()
            }
        } else {
            EmptyView()
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: scaled(8)) {
            Text("Review External Changes")
                .font(MonknotTypography.panelTitle(theme: theme))
                .foregroundStyle(theme.foregroundColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scaled(16))
        .frame(height: scaled(48))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderColor).frame(height: 1)
        }
    }

    private func diffSurface(_ state: ExternalDocumentReviewState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            diffFileHeader(state)
            Rectangle().fill(theme.separatorColor).frame(height: 1)
            unifiedDiff(state.diskToMineDiff)
        }
        .background(theme.elevatedSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unified diff from disk to my version")
    }

    private func diffFileHeader(_ state: ExternalDocumentReviewState) -> some View {
        let summary = ExternalDocumentDiffSummary(diff: state.diskToMineDiff)
        return HStack(spacing: scaled(8)) {
            Image(systemName: "doc.text")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(14, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(theme.tertiaryForegroundColor)
                .frame(width: scaled(18))
            Text(state.displayName)
                .font(.system(
                    size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Disk → Mine")
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.mutedForegroundColor)
                .lineLimit(1)
            Spacer(minLength: scaled(12))
            diffCount("+\(summary.addedLineCount)", color: addedColor, label: "added lines")
            diffCount("−\(summary.removedLineCount)", color: removedColor, label: "removed lines")
        }
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(38))
    }

    private func diffCount(_ value: String, color: Color, label: String) -> some View {
        Text(value)
            .font(.system(
                size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale),
                weight: .semibold,
                design: .monospaced
            ))
            .foregroundStyle(color)
            .accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    private func unifiedDiff(_ diff: ExternalDocumentUnifiedDiff?) -> some View {
        if let diff, diff.hasChanges {
            GeometryReader { geometry in
                let metrics = ExternalDocumentDiffLayoutMetrics(theme: theme, zoomScale: zoomScale)
                let contentWidth = metrics.contentWidth(for: diff, viewportWidth: geometry.size.width)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                            hunkHeader(hunk, metrics: metrics)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                diffRow(line, metrics: metrics)
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .textSelection(.enabled)
                }
            }
        } else {
            Text("Disk and local text are identical.")
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.mutedForegroundColor)
                .padding(scaled(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func hunkHeader(
        _ hunk: ExternalDocumentDiffHunk,
        metrics: ExternalDocumentDiffLayoutMetrics
    ) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: metrics.oldLineNumberWidth)
            Text("")
                .frame(width: metrics.newLineNumberWidth)
            Text("⋯")
                .frame(width: metrics.markerWidth)
                .foregroundStyle(theme.tertiaryForegroundColor)
            Text(hunkDescription(hunk))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(theme.mutedForegroundColor)
                .padding(.trailing, metrics.horizontalInset)
        }
        .font(.system(size: metrics.codeFontSize, weight: .regular, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: metrics.hunkHeaderHeight, maxHeight: metrics.hunkHeaderHeight, alignment: .leading)
        .background(theme.foregroundColor.opacity(theme.isDark ? 0.035 : 0.028))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separatorColor).frame(height: 1)
        }
    }

    private func hunkDescription(_ hunk: ExternalDocumentDiffHunk) -> String {
        "Disk lines \(lineRange(start: hunk.oldStartLine, count: hunk.oldLineCount)) → Mine lines \(lineRange(start: hunk.newStartLine, count: hunk.newLineCount))"
    }

    private func lineRange(start: Int, count: Int) -> String {
        guard count > 0 else { return "none" }
        guard count > 1 else { return String(start) }
        return "\(start)–\(start + count - 1)"
    }

    private func diffRow(
        _ line: ExternalDocumentDiffLine,
        metrics: ExternalDocumentDiffLayoutMetrics
    ) -> some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLineNumber, width: metrics.oldLineNumberWidth)
            lineNumber(line.newLineNumber, width: metrics.newLineNumberWidth)
            Text(line.indicator)
                .fontWeight(line.kind == .context ? .regular : .semibold)
                .foregroundStyle(markerColor(for: line.kind))
                .frame(width: metrics.markerWidth)
                .accessibilityLabel(lineAccessibilityLabel(for: line.kind))
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(theme.foregroundColor.opacity(0.90))
            if !line.hasTerminatingNewline {
                Text("  No newline")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
        }
        .font(.system(size: metrics.codeFontSize, weight: .regular, design: .monospaced))
        .padding(.trailing, metrics.horizontalInset)
        .frame(maxWidth: .infinity, minHeight: metrics.height(for: line), maxHeight: metrics.height(for: line), alignment: .leading)
        .background(rowBackground(for: line.kind))
    }

    private func lineNumber(_ value: Int?, width: CGFloat) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.trailing, scaled(8))
            .frame(width: width, alignment: .trailing)
    }

    private func markerColor(for kind: ExternalDocumentDiffLine.Kind) -> Color {
        switch kind {
        case .context: return theme.tertiaryForegroundColor
        case .removal: return removedColor
        case .addition: return addedColor
        }
    }

    private func rowBackground(for kind: ExternalDocumentDiffLine.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .removal: return removedColor.opacity(theme.isDark ? 0.14 : 0.10)
        case .addition: return addedColor.opacity(theme.isDark ? 0.14 : 0.10)
        }
    }

    private func lineAccessibilityLabel(for kind: ExternalDocumentDiffLine.Kind) -> String {
        switch kind {
        case .context: return "Context"
        case .removal: return "Removed"
        case .addition: return "Added"
        }
    }

    private func baselinePane(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text.isEmpty ? " " : text)
                .font(.system(
                    size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale),
                    weight: .regular,
                    design: .monospaced
                ))
                .foregroundStyle(theme.foregroundColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(scaled(10))
        }
        .frame(maxWidth: .infinity, minHeight: scaled(96), maxHeight: scaled(160), alignment: .topLeading)
        .background(theme.elevatedSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }

    private func footer(_ state: ExternalDocumentReviewState) -> some View {
        HStack(spacing: scaled(12)) {
            statusLabel(state)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: scaled(8)) {
                MonknotActionButton(
                    title: "Save a Copy…",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: saveCopy
                )
                MonknotActionButton(
                    title: "Cancel",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale
                ) {
                    store.cancelExternalDocumentReview()
                }
                if state.canMerge {
                    MonknotActionButton(
                        title: "Merge",
                        role: .secondary,
                        theme: theme,
                        zoomScale: zoomScale
                    ) {
                        store.resolveExternalDocumentReview(.merge)
                    }
                }
                MonknotActionButton(
                    title: "Keep Mine",
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale
                ) {
                    store.resolveExternalDocumentReview(.keepLocal)
                }
                MonknotActionButton(
                    title: "Use Disk",
                    role: .destructive,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: state.review.diskRevision == nil
                ) {
                    store.resolveExternalDocumentReview(.useDisk)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, scaled(16))
        .padding(.vertical, scaled(12))
        .background(theme.elevatedSurfaceColor)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderColor).frame(height: 1)
        }
    }

    @ViewBuilder
    private func statusLabel(_ state: ExternalDocumentReviewState) -> some View {
        if state.review.diskRevision == nil {
            status(
                "The disk file is unavailable. Save a copy or keep your local version.",
                systemImage: "exclamationmark.triangle",
                color: removedColor
            )
        } else if state.hasMergeConflict {
            status(
                "The changes overlap and cannot be merged automatically.",
                systemImage: "exclamationmark.triangle",
                color: theme.mutedForegroundColor
            )
        } else if state.canMerge {
            status(
                "Disk and local edits do not overlap.",
                systemImage: "checkmark.circle",
                color: addedColor
            )
        } else {
            status(
                "Choose which validated version to keep.",
                systemImage: "info.circle",
                color: theme.mutedForegroundColor
            )
        }
    }

    private func status(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(color)
            .lineLimit(2)
    }

    private var addedColor: Color {
        Color(hex: theme.semanticColors.diffAdded)
    }

    private var removedColor: Color {
        Color(hex: theme.semanticColors.diffRemoved)
    }
}
