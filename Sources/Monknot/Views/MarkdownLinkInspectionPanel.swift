import MonknotCore
import SwiftUI

struct MarkdownLinkInspectionPanel: View {
    @ObservedObject var state: MarkdownLinkInspectionState
    let document: WorkspaceDocument
    let documentsByID: [String: WorkspaceDocument]
    let theme: AppTheme
    let zoomScale: Double
    let refresh: () -> Void
    let close: () -> Void
    let openSource: (String, MarkdownSourceLocation) -> Void
    let openTarget: (String) -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }


    private var panelWidth: CGFloat {
        min(scaled(340), 420)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A panel header is a bar: no rule under it, as the sidebar's (design.md §10.6).
            header
            content
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .background(theme.sidebarSurfaceColor)
        // A structural edge takes `line`, not the in-container `line2` (design.md §3).
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1)
        }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link inspection for \(document.displayName)")
    }

    /// The sidebar header's geometry: 40 tall, the title on the rows' glyph edge, the actions 2 apart
    /// inside the list gutter. The document's path follows the title in 12 `ink3`.
    private var header: some View {
        HStack(spacing: scaled(MonknotMetrics.barItemGapBase)) {
            HStack(alignment: .firstTextBaseline, spacing: scaled(6)) {
                Text("Links")
                    .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                Text(document.relativePath)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(document.relativePath)

            Spacer(minLength: scaled(8))

            MonknotIconButton(
                systemImage: "arrow.clockwise",
                label: "Refresh Links",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: state.isLoading,
                action: refresh
            )
            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Links",
                theme: theme,
                zoomScale: zoomScale,
                action: close
            )
        }
        .padding(.leading, scaled(MonknotMetrics.listGutterBase + MonknotMetrics.rowPaddingBase))
        .padding(.trailing, scaled(MonknotMetrics.listGutterBase))
        .frame(height: MonknotMetrics.barHeight(theme: theme, zoomScale: zoomScale))
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            VStack(spacing: scaled(10)) {
                MonknotProgressIndicator(
                    size: MonknotMetrics.interfaceControl(MonknotMetrics.loadingSpinnerSizeBase, theme: theme, zoomScale: zoomScale),
                    theme: theme
                )
                Text("Checking workspace links…")
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = state.errorMessage {
            MonknotEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Links could not be checked",
                detail: errorMessage,
                theme: theme,
                zoomScale: zoomScale
            ) {
                MonknotActionButton(
                    title: "Try Again",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .bar,
                    action: refresh
                )
            }
        } else if let inspection = state.inspection {
            MonknotScrollView(theme: theme) {
                LazyVStack(alignment: .leading, spacing: scaled(16)) {
                    incomingSection(inspection.incomingLinks)
                    outgoingSection(inspection.outgoingIssues)
                    if inspection.skippedDocumentCount > 0 {
                        Text("Skipped \(inspection.skippedDocumentCount) unreadable or large Markdown file\(inspection.skippedDocumentCount == 1 ? "" : "s").")
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .foregroundStyle(theme.tertiaryForegroundColor)
                            .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
                    }
                }
                // The list gutter, as in the sidebar.
                .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
                .padding(.top, scaled(MonknotMetrics.listTopInsetBase))
                .padding(.bottom, scaled(12))
            }
        } else {
            EmptyView()
        }
    }

    private func incomingSection(_ links: [MarkdownIncomingLink]) -> some View {
        linkSection(title: "Incoming", count: links.count) {
            if links.isEmpty {
                emptyRow("No Markdown files link here.")
            } else {
                ForEach(links) { link in
                    MonknotListRow(theme: theme, isSelected: false) {
                        openSource(link.sourceDocumentID, link.location)
                    } label: {
                        linkRowLabel(
                            systemImage: "arrow.turn.down.right",
                            title: link.sourceRelativePath,
                            detail: "Line \(link.location.line), column \(link.column) · \(link.label)"
                        )
                    }
                    .accessibilityLabel("Incoming link from \(link.sourceRelativePath), line \(link.location.line), column \(link.column)")
                }
            }
        }
    }

    private func outgoingSection(_ issues: [MarkdownOutgoingLinkIssue]) -> some View {
        linkSection(title: "Outgoing issues", count: issues.count) {
            if issues.isEmpty {
                emptyRow("No unresolved or ambiguous links.")
            } else {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: scaled(4)) {
                        MonknotListRow(theme: theme, isSelected: false) {
                            openSource(document.id, issue.location)
                        } label: {
                            linkRowLabel(
                                systemImage: issueSystemImage(issue.kind),
                                title: issue.label,
                                detail: "\(issueTitle(issue.kind)) · line \(issue.location.line), column \(issue.column)"
                            )
                        }
                        .accessibilityLabel("\(issueTitle(issue.kind)) link \(issue.label), line \(issue.location.line), column \(issue.column)")

                        if issue.kind == .ambiguous {
                            ForEach(issue.candidateDocumentIDs, id: \.self) { documentID in
                                if let candidate = documentsByID[documentID] {
                                    // A candidate is a row under its issue, one indent in.
                                    Button {
                                        openTarget(documentID)
                                    } label: {
                                        MonknotListRowLabel(
                                            leading: .kind(systemImage: "arrow.right"),
                                            title: candidate.relativePath,
                                            depth: 1,
                                            theme: theme,
                                            zoomScale: zoomScale
                                        )
                                    }
                                    .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale))
                                    .accessibilityLabel("Open ambiguous target \(candidate.relativePath)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func linkSection<Rows: View>(
        title: String,
        count: Int,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: scaled(5)) {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(MonknotTypography.groupHeader(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
            rows()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
            .padding(.vertical, scaled(6))
    }

    /// A link row: its glyph in the 18 column, the 13 title, and a 12 `ink3` detail under it.
    private func linkRowLabel(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scaled(8)) {
            MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)
            VStack(alignment: .leading, spacing: scaled(2)) {
                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
        .padding(.vertical, scaled(6))
    }

    private func issueTitle(_ kind: MarkdownOutgoingLinkIssueKind) -> String {
        switch kind {
        case .missing: return "Unresolved"
        case .ambiguous: return "Ambiguous"
        }
    }

    private func issueSystemImage(_ kind: MarkdownOutgoingLinkIssueKind) -> String {
        switch kind {
        case .missing: return "link"
        case .ambiguous: return "arrow.triangle.branch"
        }
    }
}
