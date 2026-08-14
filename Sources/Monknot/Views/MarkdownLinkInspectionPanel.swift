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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.separatorColor)
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
                    .font(.system(size: textScaled(10.5)))
                    .foregroundStyle(theme.mutedForegroundColor)
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
        .padding(.horizontal, scaled(12))
        .frame(height: scaled(48))
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
                Button("Try Again", action: refresh)
                    .buttonStyle(.bordered)
            }
        } else if let inspection = state.inspection {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scaled(16)) {
                    incomingSection(inspection.incomingLinks)
                    outgoingSection(inspection.outgoingIssues)
                    if inspection.skippedDocumentCount > 0 {
                        Text("Skipped \(inspection.skippedDocumentCount) unreadable or large Markdown file\(inspection.skippedDocumentCount == 1 ? "" : "s").")
                            .font(.system(size: textScaled(10.5)))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .padding(.horizontal, scaled(12))
                    }
                }
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
                        HStack(alignment: .top, spacing: scaled(8)) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: textScaled(11)))
                                .foregroundStyle(theme.mutedForegroundColor)
                                .frame(width: scaled(16), height: scaled(18))
                            VStack(alignment: .leading, spacing: scaled(2)) {
                                Text(link.sourceRelativePath)
                                    .font(.system(size: textScaled(12), weight: .medium))
                                    .foregroundStyle(theme.foregroundColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Line \(link.location.line), column \(link.column) · \(link.label)")
                                    .font(.system(size: textScaled(10.5)))
                                    .foregroundStyle(theme.mutedForegroundColor)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, scaled(12))
                        .padding(.vertical, scaled(7))
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
                            HStack(alignment: .top, spacing: scaled(8)) {
                                Image(systemName: issueSystemImage(issue.kind))
                                    .font(.system(size: textScaled(11)))
                                    .foregroundStyle(theme.mutedForegroundColor)
                                    .frame(width: scaled(16), height: scaled(18))
                                VStack(alignment: .leading, spacing: scaled(2)) {
                                    Text(issue.label)
                                        .font(.system(size: textScaled(12), weight: .medium))
                                        .foregroundStyle(theme.foregroundColor)
                                        .lineLimit(1)
                                    Text("\(issueTitle(issue.kind)) · line \(issue.location.line), column \(issue.column)")
                                        .font(.system(size: textScaled(10.5)))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, scaled(12))
                            .padding(.vertical, scaled(7))
                        }
                        .accessibilityLabel("\(issueTitle(issue.kind)) link \(issue.label), line \(issue.location.line), column \(issue.column)")

                        if issue.kind == .ambiguous {
                            ForEach(issue.candidateDocumentIDs, id: \.self) { documentID in
                                if let candidate = documentsByID[documentID] {
                                    Button {
                                        openTarget(documentID)
                                    } label: {
                                        Label(candidate.relativePath, systemImage: "arrow.right")
                                            .font(.system(size: textScaled(10.5)))
                                            .foregroundStyle(theme.accentColor)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, scaled(36))
                                            .padding(.trailing, scaled(12))
                                            .padding(.vertical, scaled(3))
                                    }
                                    .buttonStyle(.plain)
                                    .monknotPointerCursor()
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
                Text(title.uppercased())
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(.system(size: textScaled(10), weight: .semibold))
            .foregroundStyle(theme.mutedForegroundColor)
            .padding(.horizontal, scaled(12))
            rows()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: textScaled(11.5)))
            .foregroundStyle(theme.mutedForegroundColor)
            .padding(.horizontal, scaled(12))
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
