import Foundation

public struct TerminalTabItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var sequenceNumber: Int
    public var workingDirectoryPath: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        sequenceNumber: Int,
        workingDirectoryPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sequenceNumber = sequenceNumber
        self.workingDirectoryPath = workingDirectoryPath
    }
}

public struct TerminalTabState: Codable, Equatable, Sendable {
    public private(set) var tabs: [TerminalTabItem]
    public private(set) var selectedTerminalID: String?
    public private(set) var nextTerminalNumber: Int

    public init(
        tabs: [TerminalTabItem] = [],
        selectedTerminalID: String? = nil,
        nextTerminalNumber: Int = 1
    ) {
        self.tabs = tabs
        self.selectedTerminalID = selectedTerminalID
        self.nextTerminalNumber = max(nextTerminalNumber, Self.nextNumber(after: tabs))
        normalizeSelection()
    }

    public var isEmpty: Bool {
        tabs.isEmpty
    }

    public var selectedTerminal: TerminalTabItem? {
        guard let selectedTerminalID else { return nil }
        return tabs.first { $0.id == selectedTerminalID }
    }

    public func contains(terminalID: String) -> Bool {
        tabs.contains { $0.id == terminalID }
    }

    public func tab(for terminalID: String) -> TerminalTabItem? {
        tabs.first { $0.id == terminalID }
    }

    @discardableResult
    public mutating func create(workingDirectoryPath: String? = nil) -> TerminalTabItem {
        let sequenceNumber = nextTerminalNumber
        nextTerminalNumber += 1

        let tab = TerminalTabItem(
            title: Self.defaultTitle(for: sequenceNumber),
            sequenceNumber: sequenceNumber,
            workingDirectoryPath: workingDirectoryPath
        )
        tabs.append(tab)
        selectedTerminalID = tab.id
        return tab
    }

    @discardableResult
    public mutating func activate(terminalID: String) -> Bool {
        guard contains(terminalID: terminalID) else {
            return false
        }

        selectedTerminalID = terminalID
        return true
    }

    @discardableResult
    public mutating func remove(terminalID: String) -> String? {
        guard let index = tabs.firstIndex(where: { $0.id == terminalID }) else {
            return selectedTerminalID
        }

        let wasSelected = selectedTerminalID == terminalID
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTerminalID = nil
            return nil
        }

        if wasSelected {
            let nextIndex = min(index, tabs.count - 1)
            selectedTerminalID = tabs[nextIndex].id
        }

        return selectedTerminalID
    }

    public mutating func rename(terminalID: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == terminalID }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        tabs[index].title = trimmedTitle
    }

    public mutating func updateWorkingDirectoryPath(_ path: String?, for terminalID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == terminalID }) else {
            return
        }

        tabs[index].workingDirectoryPath = path
    }

    public mutating func removeAll() {
        tabs = []
        selectedTerminalID = nil
    }

    private mutating func normalizeSelection() {
        if let selectedTerminalID, tabs.contains(where: { $0.id == selectedTerminalID }) {
            return
        }

        selectedTerminalID = tabs.first?.id
    }

    private static func defaultTitle(for sequenceNumber: Int) -> String {
        sequenceNumber == 1 ? "zsh" : "zsh \(sequenceNumber)"
    }

    private static func nextNumber(after tabs: [TerminalTabItem]) -> Int {
        (tabs.map(\.sequenceNumber).max() ?? 0) + 1
    }
}
