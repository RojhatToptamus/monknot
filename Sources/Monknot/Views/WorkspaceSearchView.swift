import MonknotCore
import AppKit
import SwiftUI

/// Workspace search uses the same zoom factor as the rest of the workspace.
enum WorkspaceSearchLayoutPolicy {
    static let fieldBorderWidth: CGFloat = 1

    static func densityZoomScale(_ zoomScale: Double) -> Double {
        WorkspaceZoomPolicy.clamp(zoomScale)
    }

    static func fieldHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceControl(
            28,
            theme: theme,
            zoomScale: zoomScale
        )
    }
}

struct WorkspaceSearchView: View {
    @ObservedObject var state: WorkspaceSearchState
    let documents: [WorkspaceDocument]
    let dirtyTextByDocumentID: [String: String]
    let dirtyPDFDataByDocumentID: [String: Data]
    @Binding var searchOptions: MonknotSearchOptions
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let workspaceSearchFocusChanged: (Bool) -> Void
    let openResult: (WorkspaceSearchResult) -> Void
    let replaceAll: () -> Void
    let makeReplacePreview: () -> WorkspaceReplacePreview?
    let copyResults: () -> Void
    let canConfigureReplace: Bool
    let canReviewReplace: Bool

    /// Results from the previous query while the next search runs.
    static let staleResultsOpacity = 0.5

    @State private var replaceConfirmation: WorkspaceReplacePreview?
    @State private var isReplaceExpanded = false
    @State private var didCopyResults = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case query
        case replacement
    }

    private var densityZoomScale: Double {
        WorkspaceSearchLayoutPolicy.densityZoomScale(zoomScale)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: densityZoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
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
        .onChange(of: focusedField) { previousField, currentField in
            let wasFocused = previousField != nil
            let isFocused = currentField != nil
            if wasFocused != isFocused {
                workspaceSearchFocusChanged(isFocused)
            }
        }
        .onChange(of: searchOptions) { _, options in
            state.refresh(
                options: options,
                documents: documents,
                dirtyTextByDocumentID: dirtyTextByDocumentID,
                dirtyPDFDataByDocumentID: dirtyPDFDataByDocumentID
            )
        }
        .onExitCommand(perform: close)
        .onDisappear {
            workspaceSearchFocusChanged(false)
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

    /// Same geometry as the sidebar header it replaces: 40 tall, the title where the workspace name sits
    /// and the close button where the header actions sit (design.md §10.4).
    private var searchHeader: some View {
        HStack(spacing: scaled(6)) {
            Text("Find in Workspace")
                .font(.system(size: textScaled(13), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.92))
                .lineLimit(1)

            Spacer(minLength: scaled(4))

            MonknotIconButton(
                systemImage: "xmark",
                label: "Close Workspace Search",
                theme: theme,
                zoomScale: zoomScale,
                size: .sidebarHeader,
                action: close
            )
        }
        .padding(.leading, scaled(20))
        .padding(.trailing, scaled(10))
        .frame(height: scaled(40))
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
            queryField
                .padding(.horizontal, scaled(10))

            VStack(alignment: .leading, spacing: scaled(2)) {
                replaceDisclosure
                if isReplaceExpanded {
                    VStack(alignment: .leading, spacing: scaled(MonknotMetrics.Spacing.s)) {
                        replaceField
                        replaceActions
                        if let message = state.replaceStatusMessage {
                            Text(message)
                                .font(.system(size: textScaled(12), weight: .regular))
                                .foregroundStyle(theme.tertiaryForegroundColor)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // With the row gutter, the same 10 inset as the query field.
                    .padding(.horizontal, scaled(4))
                    .padding(.bottom, scaled(MonknotMetrics.Spacing.xs))
                }
                searchStatusRow
            }
            .padding(.horizontal, scaled(6))
        }
        .padding(.bottom, scaled(MonknotMetrics.Spacing.xs))
    }

    /// The same field as Find in the titlebar: a 28 inset field with the search glyph, the query, Clear,
    /// and the two match options, whose glyph turns `accent` while on (design.md §1.3).
    private var queryField: some View {
        HStack(spacing: scaled(6)) {
            MonknotSearchGlyph(theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.mutedForegroundColor)

            TextField(
                "Search workspace",
                text: Binding(
                    get: { state.query },
                    set: {
                        state.setQuery(
                            $0,
                            options: searchOptions,
                            documents: documents,
                            dirtyTextByDocumentID: dirtyTextByDocumentID,
                            dirtyPDFDataByDocumentID: dirtyPDFDataByDocumentID
                        )
                    }
                )
            )
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .query)
            .font(.system(size: textScaled(13)))
            .foregroundStyle(theme.foregroundColor)
            .onSubmit {
                // Results from the previous query don't open while a new search runs.
                guard !state.isSearching else { return }
                if let selected = state.selectedResult ?? state.results.first {
                    openResult(selected)
                }
            }

            if !state.query.isEmpty {
                MonknotTabCloseButton(label: "Clear Search", theme: theme, zoomScale: zoomScale) {
                    state.setQuery(
                        "",
                        options: searchOptions,
                        documents: documents,
                        dirtyTextByDocumentID: dirtyTextByDocumentID,
                        dirtyPDFDataByDocumentID: dirtyPDFDataByDocumentID
                    )
                    focusSearchField()
                }
            }

            HStack(spacing: scaled(2)) {
                searchOptionButton(
                    systemImage: "textformat",
                    label: "Match Case",
                    isActive: searchOptions.isCaseSensitive
                ) {
                    searchOptions.isCaseSensitive.toggle()
                }

                searchOptionButton(
                    systemImage: "character.cursor.ibeam",
                    label: "Match Whole Word",
                    isActive: searchOptions.isWholeWord
                ) {
                    searchOptions.isWholeWord.toggle()
                }
            }
        }
        .padding(.leading, scaled(MonknotMetrics.Spacing.m))
        .padding(.trailing, scaled(3))
        .frame(height: WorkspaceSearchLayoutPolicy.fieldHeight(theme: theme, zoomScale: zoomScale))
        .background(
            theme.insetFillColor,
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        )
        .overlay {
            // design.md §3: the one place a 1px accent stroke belongs is a focused field.
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(
                    focusedField == .query ? theme.accentColor : theme.borderColor,
                    lineWidth: WorkspaceSearchLayoutPolicy.fieldBorderWidth
                )
        }
    }

    private func searchOptionButton(
        systemImage: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            isActive: isActive,
            size: .sidebarHeader,
            drawsActiveBackground: false,
            focusRingPlacement: .contained,
            action: action
        )
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// A disclosure row like every other in the sidebar: the chevron in the glyph column, then the label.
    private var replaceDisclosure: some View {
        Button {
            isReplaceExpanded.toggle()
        } label: {
            HStack(spacing: scaled(8)) {
                SidebarDisclosureChevron(isExpanded: isReplaceExpanded, theme: theme, zoomScale: zoomScale)
                Text("Replace")
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scaled(10))
            .frame(height: scaled(30))
            .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(
            theme: theme,
            isSelected: false,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
        .accessibilityLabel("Replace")
        .accessibilityValue(isReplaceExpanded ? "Expanded" : "Collapsed")
    }

    private var replaceField: some View {
        HStack(spacing: scaled(6)) {
            TextField(
                "Replace with",
                text: Binding(
                    get: { state.replaceText },
                    set: { state.setReplaceText($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .replacement)
            .font(.system(size: textScaled(13)))
            .foregroundStyle(canConfigureReplace ? theme.foregroundColor : theme.disabledForegroundColor)
            .disabled(!canConfigureReplace)

            if canConfigureReplace, !state.replaceText.isEmpty {
                MonknotTabCloseButton(label: "Clear Replacement", theme: theme, zoomScale: zoomScale) {
                    state.setReplaceText("")
                }
            }
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.m))
        .frame(height: WorkspaceSearchLayoutPolicy.fieldHeight(theme: theme, zoomScale: zoomScale))
        .background(
            theme.insetFillColor,
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(
                    focusedField == .replacement
                        ? theme.accentColor
                        : theme.borderColor.opacity(canConfigureReplace ? 1 : MonknotIconButton.disabledBorderOpacity),
                    lineWidth: WorkspaceSearchLayoutPolicy.fieldBorderWidth
                )
        }
    }

    private var replaceActions: some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            replaceScopeMenu
            Spacer(minLength: 0)
            reviewReplaceButton
        }
    }

    private var replaceScopeMenu: some View {
        Menu {
            ForEach(WorkspaceReplaceScope.allCases, id: \.rawValue) { scope in
                Button {
                    state.replaceScope = scope
                    state.clearReplaceStatus()
                } label: {
                    if state.replaceScope == scope {
                        Label(scope.title, systemImage: "checkmark")
                    } else {
                        Text(scope.title)
                    }
                }
            }
        } label: {
            Text(state.replaceScope.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: textScaled(12)))
        .foregroundStyle(canConfigureReplace ? theme.mutedForegroundColor : theme.disabledForegroundColor)
        .disabled(!canConfigureReplace)
        .help("Where Replace All applies")
        .accessibilityLabel("Replace scope")
        .accessibilityValue(state.replaceScope.title)
    }

    /// Opens a confirmation listing every file first, so it is a secondary button with an ellipsis.
    private var reviewReplaceButton: some View {
        MonknotActionButton(
            title: "Replace All…",
            role: .secondary,
            theme: theme,
            zoomScale: zoomScale,
            size: .bar,
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
        if hasQuery {
            HStack(spacing: scaled(6)) {
                // The spinner and the copy button keep their slots, so the status text never moves.
                MonknotProgressIndicator(
                    size: MonknotMetrics.interfaceGlyph(12, theme: theme, zoomScale: zoomScale),
                    theme: theme,
                    isAnimating: state.isSearching
                )
                .opacity(state.isSearching ? 1 : 0)
                .accessibilityHidden(!state.isSearching)

                Text(searchStatusText)
                    .font(.system(size: textScaled(12), weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(
                        state.errorMessage == nil
                            ? theme.tertiaryForegroundColor
                            : Color(hex: theme.semanticColors.diffRemoved)
                    )
                    .lineLimit(2)

                Spacer(minLength: 0)

                MonknotIconButton(
                    systemImage: didCopyResults ? "checkmark" : "doc.on.doc",
                    label: didCopyResults ? "Results Copied" : "Copy Search Results",
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: state.isSearching || state.results.isEmpty,
                    size: .sidebarHeader,
                    action: copySearchResults
                )
            }
            .padding(.leading, scaled(10))
            .padding(.trailing, scaled(4))
            .frame(minHeight: scaled(30))
        }
    }

    private var hasQuery: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchStatusText: String {
        if let errorMessage = state.errorMessage {
            return errorMessage
        }
        if state.isSearching {
            return "Searching…"
        }
        if state.results.isEmpty {
            return "No matches"
        }

        let matchCount = state.results.count
        let fileCount = state.resultGroups.count
        let matches = state.reachedMatchLimit
            ? "\(matchCount)+ matches"
            : "\(matchCount) match\(matchCount == 1 ? "" : "es")"
        var text = "\(matches) in \(fileCount) file\(fileCount == 1 ? "" : "s")"
        if state.skippedLargeFileCount > 0 {
            text += " · \(state.skippedLargeFileCount) large file\(state.skippedLargeFileCount == 1 ? "" : "s") skipped"
        }
        return text
    }

    /// The status row carries every state in one quiet line; the body only ever holds results, a hint
    /// before the first search, or Try Again after an error.
    @ViewBuilder
    private var searchBody: some View {
        if state.errorMessage != nil {
            HStack {
                MonknotActionButton(
                    title: "Try Again",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .bar
                ) {
                    state.refresh(
                        options: searchOptions,
                        documents: documents,
                        dirtyTextByDocumentID: dirtyTextByDocumentID,
                        dirtyPDFDataByDocumentID: dirtyPDFDataByDocumentID
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(scaled(16))
            .frame(maxHeight: .infinity, alignment: .top)
        } else if !hasQuery {
            Text("Searches the text of every note and PDF in this workspace.")
                .font(.system(size: textScaled(12)))
                .foregroundStyle(theme.tertiaryForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, scaled(16))
                .padding(.vertical, scaled(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.results.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        } else {
            // While a new search runs, the previous results stay in place, dimmed, until the new
            // ones replace them.
            ScrollViewReader { proxy in
                MonknotScrollView(theme: theme) {
                    resultList
                }
                .onChange(of: state.selectedResultIndex) { _, index in
                    proxy.scrollTo(WorkspaceSearchListItem.ID.match(index))
                }
            }
            .scrollContentBackground(.hidden)
            .opacity(state.isSearching ? Self.staleResultsOpacity : 1)
            .allowsHitTesting(!state.isSearching)
            .animation(MonknotMotion.hoverAnimation, value: state.isSearching)
        }
    }

    /// One flat lazy list of file headers and matches, each with a fixed height, so the lazy stack
    /// estimates its length correctly. Rows are equatable: moving the selection redraws two rows.
    private var resultList: some View {
        let query = state.resultsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationWidthTemplates = state.resultLocationWidthTemplates
        return LazyVStack(alignment: .leading, spacing: scaled(2)) {
            ForEach(state.resultListItems) { item in
                switch item {
                case .header(let group):
                    WorkspaceSearchFileRow(
                        group: group,
                        countText: groupCountText(group),
                        theme: theme,
                        zoomScale: zoomScale
                    )
                case .match(let match):
                    WorkspaceSearchResultRow(
                        match: match,
                        query: query,
                        searchOptions: searchOptions,
                        isSelected: match.index == state.selectedResultIndex,
                        locationWidthTemplates: locationWidthTemplates,
                        theme: theme,
                        zoomScale: zoomScale
                    ) {
                        state.selectResult(at: match.index)
                        openResult(match.result)
                    }
                    .equatable()
                }
            }
        }
        .padding(.horizontal, scaled(6))
        .padding(.vertical, scaled(6))
    }

    private func groupCountText(_ group: WorkspaceSearchResultGroup) -> String {
        state.truncatedDocumentIDs.contains(group.documentID) ? "\(group.matches.count)+" : "\(group.matches.count)"
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            focusedField = .query
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
        MonknotSheetLayout(
            title: "Replace \(preview.totalReplacements) match\(preview.totalReplacements == 1 ? "" : "es") in \(preview.affectedFileCount) file\(preview.affectedFileCount == 1 ? "" : "s")?",
            message: "These files change on disk. ⌘Z undoes the replace while Monknot stays open.",
            theme: theme
        ) {
            VStack(alignment: .leading, spacing: 8) {
                MonknotScrollView(theme: theme) {
                    VStack(spacing: 0) {
                        ForEach(Array(preview.fileResults.enumerated()), id: \.element.documentID) { index, result in
                            HStack(spacing: 8) {
                                MonknotFileKindGlyph(systemImage: "doc.text", theme: theme, zoomScale: 1)
                                    .foregroundStyle(theme.tertiaryForegroundColor)

                                Text(result.relativePath)
                                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: 1))
                                    .foregroundStyle(theme.foregroundColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 12)

                                Text("\(result.replacementCount)")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.tertiaryForegroundColor)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .overlay(alignment: .bottom) {
                                if index < preview.fileResults.count - 1 {
                                    Rectangle()
                                        .fill(theme.separatorColor)
                                        .frame(height: 1)
                                        .padding(.leading, 36)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(theme.borderColor, lineWidth: 1)
                }

                if preview.skippedDirtyCount > 0 || preview.skippedLargeFileCount > 0 {
                    Text(skippedMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
            }
        } buttons: {
            MonknotActionButton(title: "Cancel", role: .secondary, theme: theme, action: cancel)
                .keyboardShortcut(.cancelAction)
            MonknotActionButton(title: "Replace All", role: .destructive, theme: theme, action: confirm)
                .keyboardShortcut(.defaultAction)
        }
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
    /// Which match on its line this is (0 for the first), so a row can show its own occurrence.
    var occurrenceInLine = 0

    var id: Int { index }
}

struct WorkspaceSearchResultGroup: Identifiable {
    let documentID: String
    let relativePath: String
    let kind: WorkspaceSearchResultKind
    var matches: [IndexedWorkspaceSearchResult]

    var id: String { documentID }
}

enum WorkspaceSearchListItem: Identifiable {
    enum ID: Hashable {
        case file(String)
        case match(Int)
    }

    case header(WorkspaceSearchResultGroup)
    case match(IndexedWorkspaceSearchResult)

    var id: ID {
        switch self {
        case .header(let group): .file(group.documentID)
        case .match(let match): .match(match.index)
        }
    }
}

enum WorkspaceSearchResultGrouping {
    /// Each file's header followed by its matches, as one flat sequence.
    static func listItems(from groups: [WorkspaceSearchResultGroup]) -> [WorkspaceSearchListItem] {
        groups.flatMap { group in
            [.header(group)] + group.matches.map { .match($0) }
        }
    }

    static func groups(from results: [WorkspaceSearchResult]) -> [WorkspaceSearchResultGroup] {
        var groups: [WorkspaceSearchResultGroup] = []
        var groupIndexByDocumentID: [String: Int] = [:]

        for (index, result) in results.enumerated() {
            var indexedResult = IndexedWorkspaceSearchResult(index: index, result: result)

            if let groupIndex = groupIndexByDocumentID[result.documentID] {
                // For a PDF `line` is the page, so the line's text has to match too.
                if let previous = groups[groupIndex].matches.last,
                   previous.result.line == result.line,
                   previous.result.kind == result.kind,
                   previous.result.preview == result.preview {
                    indexedResult.occurrenceInLine = previous.occurrenceInLine + 1
                }
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

/// A file in the results: the kind glyph in the glyph column, the name, its folder, and the match count.
private struct WorkspaceSearchFileRow: View {
    let group: WorkspaceSearchResultGroup
    let countText: String
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private var fileName: String {
        (group.relativePath as NSString).lastPathComponent
    }

    private var folderPath: String {
        (group.relativePath as NSString).deletingLastPathComponent
    }

    private var name: some View {
        Text(fileName)
            .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(theme.foregroundColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            MonknotFileKindGlyph(systemImage: group.kind.resolvedSystemImage, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .accessibilityHidden(true)

            // The folder only when the whole name fits beside it; a clipped stub of a path reads as noise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: scaled(6)) {
                    name.fixedSize()
                    if !folderPath.isEmpty {
                        Text(folderPath)
                            .font(.system(size: textScaled(12)))
                            .foregroundStyle(theme.tertiaryForegroundColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(minWidth: scaled(40), alignment: .leading)
                    }
                }
                name
            }
            .help(group.relativePath)

            Spacer(minLength: scaled(4))

            Text(countText)
                .font(.system(size: textScaled(12)))
                .monospacedDigit()
                .foregroundStyle(theme.tertiaryForegroundColor)
        }
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(30))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.relativePath), \(countText) matches")
    }
}

/// The text shown for a match: its line, clipped at the front so this occurrence is in view, with the
/// occurrence's range. Two matches on one line therefore read differently.
enum WorkspaceSearchSnippet {
    /// Characters of context kept before the match when the line is clipped, and the least it keeps.
    static let leadingContext = 18
    static let minimumContext = 8

    static func make(
        preview: String,
        query: String,
        options: MonknotSearchOptions,
        occurrence: Int
    ) -> (text: String, match: Range<String.Index>?) {
        let ranges = MonknotTextSearch.matchingRanges(of: query, in: preview, options: options)
        guard !ranges.isEmpty,
              let match = Range(ranges[min(occurrence, ranges.count - 1)], in: preview)
        else { return (preview, nil) }

        let offset = preview.distance(from: preview.startIndex, to: match.lowerBound)
        guard offset > leadingContext else { return (preview, match) }

        // Clip at a word boundary shortly before the match, keeping a few words of context, then mark
        // the cut with an ellipsis.
        var start = preview.index(match.lowerBound, offsetBy: -leadingContext)
        if let space = preview[start..<match.lowerBound].firstIndex(of: " "),
           preview.distance(from: space, to: match.lowerBound) > minimumContext {
            start = preview.index(after: space)
        }
        let text = "…" + preview[start...]
        let shift = preview.distance(from: start, to: match.lowerBound) + 1
        let lower = text.index(text.startIndex, offsetBy: shift)
        let upper = text.index(lower, offsetBy: preview.distance(from: match.lowerBound, to: match.upperBound))
        return (text, lower..<upper)
    }
}

/// The location column of the result list: one width for every row, from the widest label in the
/// results, so line numbers line up and the snippets share a left edge.
enum WorkspaceSearchLocationColumn {
    static func label(for result: WorkspaceSearchResult) -> String {
        result.kind == .text ? "\(result.line)" : result.locationLabel
    }

    /// The widest label of each kind in `results`, as monospaced-digit templates.
    static func widthTemplates(for results: [WorkspaceSearchResult]) -> [String] {
        var widestTextLine = 0
        var widestPage = 0
        for result in results {
            switch result.kind {
            case .text:
                widestTextLine = max(widestTextLine, result.line)
            case .pdf:
                widestPage = max(widestPage, result.line)
            }
        }
        var templates: [String] = []
        if widestTextLine > 0 {
            templates.append(MonknotStableWidth.lineNumberTemplate(maximumLine: widestTextLine))
        }
        if widestPage > 0 {
            templates.append("p" + MonknotStableWidth.lineNumberTemplate(maximumLine: widestPage))
        }
        return templates
    }
}

/// One match: the line (or page) number in a fixed gutter and one line of text with this occurrence
/// marked in `sel` (design.md §1.3 keeps accent off search matches). Row primitive, 30 tall.
private struct WorkspaceSearchResultRow: View, Equatable {
    let match: IndexedWorkspaceSearchResult
    let query: String
    let searchOptions: MonknotSearchOptions
    let isSelected: Bool
    let locationWidthTemplates: [String]
    let theme: AppTheme
    let zoomScale: Double
    let open: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.match.index == rhs.match.index
            && lhs.locationWidthTemplates == rhs.locationWidthTemplates
            && lhs.match.result == rhs.match.result
            && lhs.match.occurrenceInLine == rhs.match.occurrenceInLine
            && lhs.query == rhs.query
            && lhs.searchOptions == rhs.searchOptions
            && lhs.isSelected == rhs.isSelected
            && lhs.theme == rhs.theme
            && lhs.zoomScale == rhs.zoomScale
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: scaled(8)) {
                Text(locationLabel)
                    .monknotReservingWidth(of: locationWidthTemplates)
                    .font(.system(size: textScaled(12)))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)

                Text(snippet)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, scaled(10))
            .frame(height: scaled(30))
            .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
        .help(match.result.preview)
        .accessibilityLabel("\(match.result.displayName), \(accessibilityLocation), \(match.result.preview)")
    }

    private var locationLabel: String {
        WorkspaceSearchLocationColumn.label(for: match.result)
    }

    private var accessibilityLocation: String {
        match.result.kind == .text ? "line \(match.result.line)" : "page \(match.result.line)"
    }

    private var snippet: AttributedString {
        let parts = WorkspaceSearchSnippet.make(
            preview: match.result.preview,
            query: query,
            options: searchOptions,
            occurrence: match.occurrenceInLine
        )
        var attributed = AttributedString(parts.text)
        if let range = parts.match,
           let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[lower..<upper].foregroundColor = theme.foregroundColor
            // On a selected row the match sits on `sel` already, so it takes the press tint instead.
            attributed[lower..<upper].backgroundColor = isSelected ? theme.pressedFillColor : theme.selectedRowColor
        }
        return attributed
    }
}
