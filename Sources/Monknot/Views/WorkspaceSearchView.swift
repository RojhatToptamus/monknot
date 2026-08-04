import MonknotCore
import AppKit
import SwiftUI

/// Workspace search is a narrow utility surface. Its layout density is capped
/// independently while control and glyph sizing remains fixed with the rest of
/// the application chrome.
enum WorkspaceSearchLayoutPolicy {
    static let maximumUtilityZoomScale = 1.6

    static func effectiveZoomScale(_ zoomScale: Double) -> Double {
        min(maximumUtilityZoomScale, WorkspaceZoomPolicy.clamp(zoomScale))
    }

    static func fieldHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        max(
            34,
            MonknotMetrics.interfaceControl(
                34,
                theme: theme,
                zoomScale: effectiveZoomScale(zoomScale)
            )
        )
    }
}

struct WorkspaceSearchView: View {
    @ObservedObject var state: WorkspaceSearchState
    let documents: [WorkspaceDocument]
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let openResult: (WorkspaceSearchResult) -> Void
    let replaceAll: () -> Void
    let makeReplacePreview: () -> WorkspaceReplacePreview?
    let copyResults: () -> Void
    let canConfigureReplace: Bool
    let canReviewReplace: Bool

    @State private var replaceConfirmation: WorkspaceReplacePreview?
    @State private var isReplaceExpanded = false
    @State private var didCopyResults = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var panelZoomScale: Double {
        WorkspaceSearchLayoutPolicy.effectiveZoomScale(zoomScale)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: panelZoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: panelZoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: panelZoomScale)
    }

    private var groupedResults: [WorkspaceSearchResultGroup] {
        WorkspaceSearchResultGrouping.groups(from: state.results)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            searchControls

            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)

            searchBody
        }
        .onAppear {
            focusSearchField()
        }
        .onChange(of: state.focusSerial) { _, _ in
            focusSearchField()
        }
        .onExitCommand(perform: close)
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(
            isPresented: Binding(
                get: { replaceConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        replaceConfirmation = nil
                    }
                }
            )
        ) {
            if let preview = replaceConfirmation {
                WorkspaceReplaceConfirmationSheet(
                    preview: preview,
                    theme: theme,
                    cancel: { replaceConfirmation = nil },
                    confirm: {
                        replaceConfirmation = nil
                        replaceAll()
                    }
                )
            }
        }
    }

    private var searchHeader: some View {
        ViewThatFits(in: .horizontal) {
            searchHeaderContent(showsShortcut: true)
            searchHeaderContent(showsShortcut: false)
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.l))
        .padding(.top, scaled(MonknotMetrics.Spacing.m))
        .padding(.bottom, scaled(MonknotMetrics.Spacing.s))
    }

    private func searchHeaderContent(showsShortcut: Bool) -> some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            Text("Find in Workspace")
                .font(.system(size: textScaled(14), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
                .lineLimit(1)
                .fixedSize(horizontal: showsShortcut, vertical: false)

            Spacer(minLength: scaled(MonknotMetrics.Spacing.xs))

            if showsShortcut {
                Text("⇧⌘F")
                    .font(.system(size: textScaled(10), weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.sidebarMutedColor(prominence: 0.72))
                    .fixedSize()
            }

            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Workspace Search",
                theme: theme,
                zoomScale: panelZoomScale,
                size: .compact,
                action: close
            )
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            queryField
            replaceDisclosure
            searchStatusRow
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.l))
        .padding(.bottom, scaled(MonknotMetrics.Spacing.l))
    }

    private var queryField: some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyphScaled(14), weight: .medium))
                .foregroundStyle(theme.sidebarMutedColor())
                .accessibilityHidden(true)

            TextField(
                "Search workspace",
                text: Binding(
                    get: { state.query },
                    set: { state.setQuery($0, documents: documents) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(.system(size: textScaled(13)))
            .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
            .onSubmit {
                if let selected = state.selectedResult ?? state.results.first {
                    openResult(selected)
                }
            }

            MonknotIconButton(
                systemImage: "xmark.circle.fill",
                label: "Clear Search",
                theme: theme,
                zoomScale: panelZoomScale,
                isDisabled: state.query.isEmpty,
                size: .compact
            ) {
                if !state.query.isEmpty {
                    state.setQuery("", documents: documents)
                    focusSearchField()
                }
            }
            .opacity(state.query.isEmpty ? 0 : 1)
            .accessibilityHidden(state.query.isEmpty)
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.m))
        .frame(
            minHeight: WorkspaceSearchLayoutPolicy.fieldHeight(
                theme: theme,
                zoomScale: zoomScale
            )
        )
        .background(
            theme.insetFillColor,
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: panelZoomScale))
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: panelZoomScale))
                .strokeBorder(
                    isSearchFocused ? theme.accentColor.opacity(0.86) : theme.borderColor,
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
        }
        .animation(MonknotMotion.hoverAnimation, value: isSearchFocused)
    }

    private var replaceDisclosure: some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            MonknotActionButton(
                title: "Replace",
                systemImage: isReplaceExpanded ? "chevron.down" : "chevron.right",
                role: .quiet,
                theme: theme,
                zoomScale: panelZoomScale
            ) {
                isReplaceExpanded.toggle()
            }
            .accessibilityValue(isReplaceExpanded ? "Expanded" : "Collapsed")

            if isReplaceExpanded {
                replaceField
                replaceActions

                if let message = state.replaceStatusMessage {
                    Text(message)
                        .font(.system(size: textScaled(11), weight: .medium))
                        .foregroundStyle(theme.sidebarMutedColor())
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var replaceField: some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: glyphScaled(13), weight: .medium))
                .foregroundStyle(theme.sidebarMutedColor())
                .accessibilityHidden(true)

            TextField(
                "Replace with",
                text: Binding(
                    get: { state.replaceText },
                    set: { state.setReplaceText($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: textScaled(13)))
            .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
            .disabled(!canConfigureReplace)

            MonknotIconButton(
                systemImage: "xmark.circle.fill",
                label: "Clear Replacement",
                theme: theme,
                zoomScale: panelZoomScale,
                isDisabled: !canConfigureReplace || state.replaceText.isEmpty,
                size: .compact
            ) {
                if !state.replaceText.isEmpty {
                    state.setReplaceText("")
                }
            }
            .opacity(state.replaceText.isEmpty ? 0 : 1)
            .accessibilityHidden(state.replaceText.isEmpty)
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.m))
        .frame(
            minHeight: WorkspaceSearchLayoutPolicy.fieldHeight(
                theme: theme,
                zoomScale: zoomScale
            )
        )
        .background(
            theme.insetFillColor,
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: panelZoomScale))
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: panelZoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .opacity(canConfigureReplace ? 1 : 0.52)
    }

    private var replaceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
                replaceScopeMenu
                Spacer(minLength: 0)
                reviewReplaceButton
            }

            VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
                replaceScopeMenu
                reviewReplaceButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var replaceScopeMenu: some View {
        Menu {
            ForEach(WorkspaceReplaceScope.allCases, id: \.rawValue) { scope in
                Button {
                    state.replaceScope = scope
                    state.clearReplaceStatus()
                } label: {
                    Label(
                        scope.title,
                        systemImage: state.replaceScope == scope ? "checkmark" : scope.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: scaled(MonknotMetrics.Spacing.xs)) {
                Image(systemName: state.replaceScope.systemImage)
                    .font(.system(size: glyphScaled(11), weight: .medium))

                Text(state.replaceScope.title)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: glyphScaled(9), weight: .semibold))
            }
            .font(.system(size: textScaled(12), weight: .medium))
            .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.82))
            .padding(.horizontal, scaled(MonknotMetrics.Spacing.m))
            .frame(minHeight: max(28, MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: panelZoomScale)))
            .background(
                theme.insetFillColor,
                in: RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: panelZoomScale))
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: panelZoomScale))
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!canConfigureReplace)
        .accessibilityLabel("Replace scope")
        .accessibilityValue(state.replaceScope.title)
    }

    private var reviewReplaceButton: some View {
        MonknotActionButton(
            title: "Replace All",
            role: .primary,
            theme: theme,
            zoomScale: panelZoomScale,
            isDisabled: !canReviewReplace
        ) {
            guard let preview = makeReplacePreview() else { return }
            if preview.hasMatches {
                replaceConfirmation = preview
            } else {
                state.setReplaceStatusMessage(WorkspaceReplacePreview.summaryMessage(for: preview))
            }
        }
    }

    @ViewBuilder
    private var searchStatusRow: some View {
        if !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: scaled(MonknotMetrics.Spacing.xs)) {
                if state.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(max(0.8, theme.layoutScale(zoomScale: panelZoomScale) * 0.78))
                        .accessibilityHidden(true)
                }

                Text(searchStatusText)
                    .font(.system(size: textScaled(11), weight: .medium))
                    .foregroundStyle(
                        state.errorMessage == nil
                            ? theme.sidebarMutedColor()
                            : Color(hex: theme.semanticColors.diffRemoved)
                    )
                    .lineLimit(2)

                Spacer(minLength: 0)

                if !state.isSearching, !state.results.isEmpty {
                    MonknotIconButton(
                        systemImage: didCopyResults ? "checkmark" : "doc.on.doc",
                        label: didCopyResults ? "Results Copied" : "Copy Search Results",
                        theme: theme,
                        zoomScale: panelZoomScale,
                        size: .compact,
                        action: copySearchResults
                    )
                }
            }
            .frame(minHeight: scaled(24))
        }
    }

    private var searchStatusText: String {
        if let errorMessage = state.errorMessage {
            return errorMessage
        }

        if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search text and PDF files"
        }

        if state.isSearching {
            return "Searching…"
        }

        let matchCount = state.results.count
        let fileCount = groupedResults.count
        var text = "\(matchCount) match\(matchCount == 1 ? "" : "es") in \(fileCount) file\(fileCount == 1 ? "" : "s")"
        if state.skippedLargeFileCount > 0 {
            text += " · \(state.skippedLargeFileCount) large file\(state.skippedLargeFileCount == 1 ? "" : "s") skipped"
        }
        return text
    }

    @ViewBuilder
    private var searchBody: some View {
        if let errorMessage = state.errorMessage {
            errorState(errorMessage)
        } else if state.isSearching {
            loadingState
        } else if state.results.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                MonknotScrollView {
                    resultList
                }
                .onChange(of: state.selectedResultIndex) { _, index in
                    proxy.scrollTo(index)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var resultList: some View {
        LazyVStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.m)) {
            ForEach(groupedResults) { group in
                VStack(alignment: .leading, spacing: scaled(2)) {
                    resultGroupHeader(group)

                    ForEach(group.matches) { match in
                        resultRow(match)
                    }
                }
            }
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.xs))
        .padding(.vertical, scaled(MonknotMetrics.Spacing.s))
    }

    private func resultGroupHeader(_ group: WorkspaceSearchResultGroup) -> some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.xs)) {
            Image(systemName: group.kind.resolvedSystemImage)
                .font(.system(size: glyphScaled(12), weight: .medium))
                .foregroundStyle(theme.sidebarMutedColor(prominence: 0.78))
                .accessibilityHidden(true)

            Text(group.relativePath)
                .font(.system(size: textScaled(12), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.relativePath)

            Spacer(minLength: 0)

            Text("\(group.matches.count)")
                .font(.system(size: textScaled(10), weight: .medium, design: .monospaced))
                .foregroundStyle(theme.sidebarMutedColor(prominence: 0.7))
                .accessibilityLabel("\(group.matches.count) matches")
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.s))
        .padding(.top, scaled(MonknotMetrics.Spacing.xs))
        .padding(.bottom, scaled(2))
    }

    private func resultRow(_ match: IndexedWorkspaceSearchResult) -> some View {
        Button {
            state.selectResult(at: match.index)
            openResult(match.result)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: scaled(MonknotMetrics.Spacing.s)) {
                Text(resultLocationLabel(match.result))
                    .font(.system(size: textScaled(10), weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.sidebarMutedColor(prominence: 0.72))
                    .frame(width: scaled(30), alignment: .trailing)

                Text(highlightedPreview(for: match.result))
                    .font(.system(size: textScaled(12)))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.76))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, scaled(MonknotMetrics.Spacing.s))
            .padding(.vertical, scaled(7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarSearchResultButtonStyle(
            theme: theme,
            cornerRadius: theme.chromeRadius(8, zoomScale: panelZoomScale),
            isSelected: match.index == state.selectedResultIndex
        ))
        .id(match.index)
        .accessibilityLabel(
            "\(match.result.displayName), \(resultLocationLabel(match.result)), \(match.result.preview)"
        )
    }

    private func resultLocationLabel(_ result: WorkspaceSearchResult) -> String {
        result.kind == .text ? "L\(result.line)" : result.locationLabel
    }

    private func highlightedPreview(for result: WorkspaceSearchResult) -> AttributedString {
        let text = result.preview
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = NSMutableAttributedString(string: text)

        guard !query.isEmpty else {
            return AttributedString(attributed)
        }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        let highlightColor = NSColor(hex: theme.accent).withAlphaComponent(theme.isDark ? 0.32 : 0.22)

        while searchRange.length > 0 {
            let found = nsText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard found.location != NSNotFound, found.length > 0 else { break }
            attributed.addAttribute(.backgroundColor, value: highlightColor, range: found)

            let nextLocation = found.location + found.length
            guard nextLocation < nsText.length else { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return AttributedString(attributed)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            ProgressView()
                .controlSize(.small)

            Text("Searching workspace")
                .font(.system(size: textScaled(14), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))

            Text("Looking through text and searchable PDF files.")
                .font(.system(size: textScaled(12)))
                .foregroundStyle(theme.sidebarMutedColor())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(scaled(MonknotMetrics.Spacing.xxl))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching workspace")
    }

    private var emptyState: some View {
        searchStateView(
            systemImage: "doc.text.magnifyingglass",
            title: state.query.isEmpty ? "Search this workspace" : "No matches",
            detail: state.query.isEmpty
                ? "Type a word or phrase above to search text and PDFs."
                : "Try a different word or phrase."
        )
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: glyphScaled(24), weight: .regular))
                .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))

            Text("Search couldn’t finish")
                .font(.system(size: textScaled(14), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))

            Text(message)
                .font(.system(size: textScaled(12)))
                .foregroundStyle(theme.sidebarMutedColor())
                .fixedSize(horizontal: false, vertical: true)

            MonknotActionButton(
                title: "Try Again",
                systemImage: "arrow.clockwise",
                role: .quiet,
                theme: theme,
                zoomScale: panelZoomScale
            ) {
                state.refresh(documents: documents)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(scaled(MonknotMetrics.Spacing.xxl))
    }

    private func searchStateView(
        systemImage: String,
        title: String,
        detail: String,
        color: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            Image(systemName: systemImage)
                .font(.system(size: glyphScaled(20), weight: .regular))
                .foregroundStyle(color ?? theme.sidebarMutedColor())

            Text(title)
                .font(.system(size: textScaled(13), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))

            Text(detail)
                .font(.system(size: textScaled(11)))
                .foregroundStyle(theme.sidebarMutedColor())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(scaled(MonknotMetrics.Spacing.xxl))
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func copySearchResults() {
        copyResults()
        copyFeedbackTask?.cancel()
        didCopyResults = true
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_400_000_000)
            } catch {
                return
            }
            didCopyResults = false
            copyFeedbackTask = nil
        }
    }
}

private struct WorkspaceReplaceConfirmationSheet: View {
    let preview: WorkspaceReplacePreview
    let theme: AppTheme
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Replace \(preview.totalReplacements) match\(preview.totalReplacements == 1 ? "" : "es") in \(preview.affectedFileCount) file\(preview.affectedFileCount == 1 ? "" : "s")?")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)

                Text("The scope was chosen in Find in Workspace. This action changes the files listed below and can be undone with ⌘Z while Monknot stays open.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MonknotScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(preview.fileResults.enumerated()), id: \.element.documentID) { index, result in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.tertiaryForegroundColor)

                            Text(result.relativePath)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.foregroundColor)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 12)

                            Text("\(result.replacementCount)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.mutedForegroundColor)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .overlay(alignment: .bottom) {
                            if index < preview.fileResults.count - 1 {
                                Rectangle()
                                    .fill(theme.separatorColor)
                                    .frame(height: 1)
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 10))

            if preview.skippedDirtyCount > 0 || preview.skippedLargeFileCount > 0 {
                Text(skippedMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }

            HStack(spacing: 10) {
                Spacer()

                MonknotActionButton(
                    title: "Cancel",
                    role: .secondary,
                    theme: theme,
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)

                MonknotActionButton(
                    title: "Replace All",
                    role: .primary,
                    theme: theme,
                    action: confirm
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.contentSurfaceColor)
    }

    private var skippedMessage: String {
        var parts: [String] = []
        if preview.skippedDirtyCount > 0 {
            parts.append("\(preview.skippedDirtyCount) unsaved file\(preview.skippedDirtyCount == 1 ? "" : "s")")
        }
        if preview.skippedLargeFileCount > 0 {
            parts.append("\(preview.skippedLargeFileCount) large file\(preview.skippedLargeFileCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + " will be skipped."
    }
}

struct IndexedWorkspaceSearchResult: Identifiable {
    let index: Int
    let result: WorkspaceSearchResult

    var id: Int { index }
}

struct WorkspaceSearchResultGroup: Identifiable {
    let documentID: String
    let relativePath: String
    let kind: WorkspaceSearchResultKind
    var matches: [IndexedWorkspaceSearchResult]

    var id: String { documentID }
}

enum WorkspaceSearchResultGrouping {
    static func groups(from results: [WorkspaceSearchResult]) -> [WorkspaceSearchResultGroup] {
        var groups: [WorkspaceSearchResultGroup] = []
        var groupIndexByDocumentID: [String: Int] = [:]

        for (index, result) in results.enumerated() {
            let indexedResult = IndexedWorkspaceSearchResult(index: index, result: result)

            if let groupIndex = groupIndexByDocumentID[result.documentID] {
                groups[groupIndex].matches.append(indexedResult)
            } else {
                groupIndexByDocumentID[result.documentID] = groups.count
                groups.append(WorkspaceSearchResultGroup(
                    documentID: result.documentID,
                    relativePath: result.relativePath,
                    kind: result.kind,
                    matches: [indexedResult]
                ))
            }
        }

        return groups
    }
}

private struct SidebarSearchResultButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, theme: theme, cornerRadius: cornerRadius, isSelected: isSelected)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let theme: AppTheme
        let cornerRadius: CGFloat
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(backgroundFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(configuration.isPressed ? theme.borderColor : Color.clear, lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(MonknotMotion.hoverAnimation, value: isHovered)
                .onHover { isHovered = $0 }
                .monknotPointerCursor()
        }

        private var backgroundFill: Color {
            if configuration.isPressed || isSelected {
                return theme.selectedRowColor
            }
            if isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
            }
            return .clear
        }
    }
}
