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

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private var panelWidth: CGFloat {
        min(scaled(340), 420)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separatorColor)
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

    private var header: some View {
        HStack(spacing: scaled(8)) {
            VStack(alignment: .leading, spacing: scaled(2)) {
                Text("Links")
                    .font(.system(size: textScaled(13), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text(document.relativePath)
                    .font(.system(size: textScaled(12)))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: scaled(8))

            MonknotIconButton(
                systemImage: "arrow.clockwise",
                label: "Refresh Links",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: state.isLoading,
                size: .compact,
                action: refresh
            )
            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Links",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact,
                action: close
            )
        }
        .padding(.leading, scaled(16))
        .padding(.trailing, scaled(10))
        .frame(height: scaled(44))
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            VStack(spacing: scaled(10)) {
                MonknotProgressIndicator(
                    size: scaled(18),
                    theme: theme
                )
                Text("Checking workspace links…")
                    .font(.system(size: textScaled(12)))
                    .foregroundStyle(theme.mutedForegroundColor)
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
                            .font(.system(size: textScaled(12)))
                            .foregroundStyle(theme.tertiaryForegroundColor)
                            .padding(.horizontal, scaled(10))
                    }
                }
                // The list gutter, as in the sidebar.
                .padding(.horizontal, scaled(6))
                .padding(.vertical, scaled(12))
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
                                    // A candidate is a quiet row under its issue, one indent in.
                                    Button {
                                        openTarget(documentID)
                                    } label: {
                                        HStack(spacing: scaled(8)) {
                                            Image(systemName: "arrow.right")
                                                .font(.system(
                                                    size: MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale)
                                                ))
                                                .foregroundStyle(theme.tertiaryForegroundColor)
                                                .frame(width: scaled(MonknotMetrics.rowIconColumnWidthBase))
                                            Text(candidate.relativePath)
                                                .font(.system(size: textScaled(12)))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.leading, scaled(10 + 16))
                                        .padding(.trailing, scaled(10))
                                        .frame(height: scaled(26))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(MonknotRowButtonStyle(
                                        theme: theme,
                                        isSelected: false,
                                        cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                                    ))
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
                    .textCase(.uppercase)
                    .tracking(MonknotTypography.eyebrowTracking(theme: theme, zoomScale: zoomScale))
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(MonknotTypography.eyebrow(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.horizontal, scaled(10))
            rows()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: textScaled(12)))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(6))
    }

    /// A link row: its glyph in the 18 column, the 13 title, and a 12 `ink3` detail under it.
    private func linkRowLabel(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scaled(8)) {
            MonknotSystemGlyph(systemImage: systemImage, nominalPointSizeBase: 15, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .frame(width: scaled(MonknotMetrics.rowIconColumnWidthBase))
            VStack(alignment: .leading, spacing: scaled(2)) {
                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: textScaled(12)))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, scaled(10))
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
