import Foundation

public struct WorkspaceTabItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { documentID }

    public var documentID: String
    public var displayName: String
    public var relativePath: String
    public var kind: WorkspaceDocumentKind
    public var isPinned: Bool

    public init(
        documentID: String,
        displayName: String,
        relativePath: String,
        kind: WorkspaceDocumentKind,
        isPinned: Bool = false
    ) {
        self.documentID = documentID
        self.displayName = displayName
        self.relativePath = relativePath
        self.kind = kind
        self.isPinned = isPinned
    }

    public init(document: WorkspaceDocument, isPinned: Bool = false) {
        self.init(
            documentID: document.id,
            displayName: document.displayName,
            relativePath: document.relativePath,
            kind: document.kind,
            isPinned: isPinned
        )
    }

    public mutating func updateSnapshot(from document: WorkspaceDocument) {
        displayName = document.displayName
        relativePath = document.relativePath
        kind = document.kind
    }
}

/// Per-window metadata for tabs the user explicitly closed.
///
/// This history is intentionally not Codable: reopening a tab must use the current
/// workspace document and reload its content rather than restore an old buffer.
public struct WorkspaceClosedTabHistory: Equatable, Sendable {
    public static let defaultCapacity = 20

    public private(set) var tabs: [WorkspaceTabItem] = []
    private let capacity: Int

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func hasAvailableTab(documentIDs: Set<String>) -> Bool {
        tabs.contains { documentIDs.contains($0.documentID) }
    }

    public mutating func record(_ tab: WorkspaceTabItem) {
        tabs.removeAll { $0.documentID == tab.documentID }
        tabs.append(tab)
        if tabs.count > capacity {
            tabs.removeFirst(tabs.count - capacity)
        }
    }

    public mutating func discard(documentID: String) {
        tabs.removeAll { $0.documentID == documentID }
    }

    public mutating func takeMostRecent(
        availableDocumentIDs: Set<String>
    ) -> WorkspaceTabItem? {
        while let tab = tabs.popLast() {
            if availableDocumentIDs.contains(tab.documentID) {
                return tab
            }
        }
        return nil
    }

    public mutating func remapDocumentID(
        from sourceID: String,
        to destinationID: String,
        document: WorkspaceDocument? = nil
    ) {
        guard sourceID != destinationID else {
            if let document,
               let index = tabs.firstIndex(where: { $0.documentID == destinationID }) {
                tabs[index].updateSnapshot(from: document)
            }
            return
        }

        guard tabs.contains(where: {
            $0.documentID == sourceID || $0.documentID == destinationID
        }) else {
            return
        }

        for index in tabs.indices where tabs[index].documentID == sourceID {
            tabs[index].documentID = destinationID
        }

        var newestByDocumentID: [String: WorkspaceTabItem] = [:]
        var newestFirstIDs: [String] = []
        for tab in tabs.reversed() {
            if var newest = newestByDocumentID[tab.documentID] {
                newest.isPinned = newest.isPinned || tab.isPinned
                newestByDocumentID[tab.documentID] = newest
            } else {
                newestByDocumentID[tab.documentID] = tab
                newestFirstIDs.append(tab.documentID)
            }
        }
        tabs = newestFirstIDs.reversed().compactMap { newestByDocumentID[$0] }

        if let document,
           let index = tabs.firstIndex(where: { $0.documentID == destinationID }) {
            tabs[index].updateSnapshot(from: document)
        }
    }

    public mutating func reset() {
        tabs.removeAll()
    }
}

public struct WorkspaceTabState: Codable, Equatable, Sendable {
    public private(set) var tabs: [WorkspaceTabItem]
    public private(set) var selectedDocumentID: String?
    public private(set) var isEmptyByUserChoice: Bool

    public init(
        tabs: [WorkspaceTabItem] = [],
        selectedDocumentID: String? = nil,
        isEmptyByUserChoice: Bool = false
    ) {
        self.tabs = tabs
        self.selectedDocumentID = selectedDocumentID
        self.isEmptyByUserChoice = isEmptyByUserChoice
        normalizeSelection()
    }

    public var openDocumentIDs: Set<String> {
        Set(tabs.map(\.documentID))
    }

    public func contains(documentID: String) -> Bool {
        tabs.contains { $0.documentID == documentID }
    }

    public func tab(for documentID: String) -> WorkspaceTabItem? {
        tabs.first { $0.documentID == documentID }
    }

    public mutating func reset() {
        tabs = []
        selectedDocumentID = nil
        isEmptyByUserChoice = false
    }

    public mutating func open(_ document: WorkspaceDocument) {
        isEmptyByUserChoice = false

        if let index = tabs.firstIndex(where: { $0.documentID == document.id }) {
            tabs[index].updateSnapshot(from: document)
            selectedDocumentID = document.id
            return
        }

        tabs.append(WorkspaceTabItem(document: document))
        selectedDocumentID = document.id
    }

    @discardableResult
    public mutating func activate(documentID: String?) -> Bool {
        guard let documentID else {
            selectedDocumentID = nil
            isEmptyByUserChoice = tabs.isEmpty
            return true
        }

        guard contains(documentID: documentID) else {
            return false
        }

        selectedDocumentID = documentID
        isEmptyByUserChoice = false
        return true
    }

    @discardableResult
    public mutating func close(documentID: String) -> String? {
        guard let index = tabs.firstIndex(where: { $0.documentID == documentID }) else {
            return selectedDocumentID
        }

        let wasSelected = selectedDocumentID == documentID
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedDocumentID = nil
            isEmptyByUserChoice = true
            return nil
        }

        if wasSelected {
            let nextIndex = min(index, tabs.count - 1)
            selectedDocumentID = tabs[nextIndex].documentID
        }

        return selectedDocumentID
    }

    public mutating func togglePin(documentID: String) {
        guard let index = tabs.firstIndex(where: { $0.documentID == documentID }) else {
            return
        }

        var tab = tabs.remove(at: index)
        tab.isPinned.toggle()

        if tab.isPinned {
            let insertionIndex = tabs.firstIndex { !$0.isPinned } ?? tabs.endIndex
            tabs.insert(tab, at: insertionIndex)
        } else {
            tabs.append(tab)
        }
    }

    public mutating func moveTab(documentID: String, before targetDocumentID: String?) {
        guard targetDocumentID != documentID,
              let sourceIndex = tabs.firstIndex(where: { $0.documentID == documentID }) else {
            return
        }

        let tab = tabs.remove(at: sourceIndex)
        if let targetDocumentID,
           let targetIndex = tabs.firstIndex(where: { $0.documentID == targetDocumentID }) {
            tabs.insert(tab, at: targetIndex)
        } else {
            tabs.append(tab)
        }
        regroupPinnedTabs()
    }

    public mutating func updateSnapshots(from documents: [WorkspaceDocument]) {
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        for index in tabs.indices {
            if let document = documentsByID[tabs[index].documentID] {
                tabs[index].updateSnapshot(from: document)
            }
        }
    }

    @discardableResult
    public mutating func pruneUnavailableDocuments(
        availableDocumentIDs: Set<String>,
        preserving preservedDocumentIDs: Set<String> = []
    ) -> String? {
        let allowedDocumentIDs = availableDocumentIDs.union(preservedDocumentIDs)
        guard !allowedDocumentIDs.isEmpty else {
            tabs = []
            selectedDocumentID = nil
            return selectedDocumentID
        }

        tabs.removeAll { !allowedDocumentIDs.contains($0.documentID) }
        normalizeSelection()
        return selectedDocumentID
    }

    public mutating func remapDocumentID(
        sourceID: String,
        destinationID: String,
        document: WorkspaceDocument? = nil
    ) {
        guard sourceID != destinationID else {
            if let document, let index = tabs.firstIndex(where: { $0.documentID == destinationID }) {
                tabs[index].updateSnapshot(from: document)
            }
            return
        }

        let sourceIndex = tabs.firstIndex { $0.documentID == sourceID }
        let destinationIndex = tabs.firstIndex { $0.documentID == destinationID }

        switch (sourceIndex, destinationIndex) {
        case let (.some(sourceIndex), .some(destinationIndex)):
            let sourceTab = tabs[sourceIndex]
            let destinationTab = tabs[destinationIndex]
            var mergedTab = destinationTab
            mergedTab.isPinned = sourceTab.isPinned || destinationTab.isPinned
            if let document {
                mergedTab.updateSnapshot(from: document)
            }

            tabs[destinationIndex] = mergedTab
            tabs.remove(at: sourceIndex)
        case let (.some(sourceIndex), .none):
            tabs[sourceIndex].documentID = destinationID
            if let document {
                tabs[sourceIndex].updateSnapshot(from: document)
            } else {
                tabs[sourceIndex].displayName = URL(fileURLWithPath: destinationID).lastPathComponent
                tabs[sourceIndex].relativePath = tabs[sourceIndex].displayName
            }
        case let (.none, .some(destinationIndex)):
            if let document {
                tabs[destinationIndex].updateSnapshot(from: document)
            }
        case (.none, .none):
            break
        }

        if selectedDocumentID == sourceID {
            selectedDocumentID = destinationID
        }

        regroupPinnedTabs()
    }

    private mutating func normalizeSelection() {
        if let selectedDocumentID, tabs.contains(where: { $0.documentID == selectedDocumentID }) {
            return
        }

        selectedDocumentID = tabs.first?.documentID
    }

    private mutating func regroupPinnedTabs() {
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    }
}
