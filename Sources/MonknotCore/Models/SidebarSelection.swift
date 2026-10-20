import Foundation

/// The items the sidebar selects itself (design.md §10.4): a clicked folder, or files and folders
/// picked with the arrow keys, ⇧ or ⌘. `anchorID` is where a ⇧ range starts and `leadID` the item
/// the keyboard moves from. `rows` are the item IDs of the rows the tree shows, top to bottom.
public struct SidebarSelection: Equatable, Sendable {
    /// In the order they were picked.
    public private(set) var itemIDs: [String]
    public private(set) var anchorID: String?
    public private(set) var leadID: String?

    public init() {
        itemIDs = []
        anchorID = nil
        leadID = nil
    }

    public init(single itemID: String) {
        itemIDs = [itemID]
        anchorID = itemID
        leadID = itemID
    }

    private init(itemIDs: [String], anchorID: String?, leadID: String?) {
        var seen = Set<String>()
        self.itemIDs = itemIDs.filter { seen.insert($0).inserted }
        self.anchorID = anchorID.flatMap { seen.contains($0) ? $0 : nil } ?? self.itemIDs.first
        self.leadID = leadID.flatMap { seen.contains($0) ? $0 : nil } ?? self.itemIDs.last
    }

    public var isEmpty: Bool { itemIDs.isEmpty }
    public var count: Int { itemIDs.count }

    public func contains(_ itemID: String) -> Bool {
        itemIDs.contains(itemID)
    }

    /// ⌘-click: adds the item, which becomes the anchor and lead, or takes it out. Taking out the
    /// lead leaves the last item picked as the lead.
    public func toggling(_ itemID: String) -> SidebarSelection {
        if contains(itemID) {
            let remaining = itemIDs.filter { $0 != itemID }
            return SidebarSelection(
                itemIDs: remaining,
                anchorID: anchorID == itemID ? remaining.last : anchorID,
                leadID: leadID == itemID ? remaining.last : leadID
            )
        }
        return SidebarSelection(itemIDs: itemIDs + [itemID], anchorID: itemID, leadID: itemID)
    }

    /// ⇧-click: the rows from the anchor to the item, in place of the rest; the anchor stays. The
    /// lead stands in for an anchor the tree does not show; with neither, the item alone.
    public func extending(to itemID: String, rows: [String]) -> SidebarSelection {
        guard let targetIndex = rows.firstIndex(of: itemID) else { return SidebarSelection(single: itemID) }
        guard let anchorID = [anchorID, leadID].compactMap({ $0 }).first(where: { rows.contains($0) }),
              let anchorIndex = rows.firstIndex(of: anchorID)
        else {
            return SidebarSelection(single: itemID)
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return SidebarSelection(itemIDs: Array(rows[range]), anchorID: anchorID, leadID: itemID)
    }

    /// ↑ and ↓ (`offset` −1 and 1), Home and End (an offset past either end): the row that far
    /// from the lead, alone, or with ⇧ (`extending`) the rows from the anchor to it. From a lead
    /// the tree does not show, or from nothing, ↓ goes to the first row and ↑ to the last, and Home
    /// and End to the first and last. Nil when the tree shows no rows.
    public func moving(by offset: Int, rows: [String], extending: Bool) -> SidebarSelection? {
        guard !rows.isEmpty else { return nil }
        let targetIndex: Int
        if let leadID, let leadIndex = rows.firstIndex(of: leadID) {
            let step = min(max(offset, -rows.count), rows.count)
            targetIndex = min(max(leadIndex + step, 0), rows.count - 1)
        } else if offset <= -rows.count {
            targetIndex = 0
        } else if offset >= rows.count {
            targetIndex = rows.count - 1
        } else {
            targetIndex = offset < 0 ? rows.count - 1 : 0
        }
        let target = rows[targetIndex]
        return extending ? self.extending(to: target, rows: rows) : SidebarSelection(single: target)
    }

    /// ⌘A: every row, the lead kept when it is one of them.
    public static func all(_ rows: [String], leadID: String?) -> SidebarSelection {
        SidebarSelection(itemIDs: rows, anchorID: rows.first, leadID: leadID)
    }

    /// The selection with only the items `isIncluded` keeps.
    public func filtered(_ isIncluded: (String) -> Bool) -> SidebarSelection {
        SidebarSelection(itemIDs: itemIDs.filter(isIncluded), anchorID: anchorID, leadID: leadID)
    }

    /// The selection with each item, the anchor and the lead replaced by `transform`'s result, as
    /// when the items move.
    public func mapped(_ transform: (String) -> String) -> SidebarSelection {
        SidebarSelection(itemIDs: itemIDs.map(transform), anchorID: anchorID.map(transform), leadID: leadID.map(transform))
    }

    /// A selection of exactly these items, in this order, the last one the lead.
    public static func items(_ itemIDs: [String]) -> SidebarSelection {
        SidebarSelection(itemIDs: itemIDs, anchorID: itemIDs.first, leadID: itemIDs.last)
    }
}

/// Type-to-select in the sidebar: typed characters within a second of each other make one prefix,
/// and the first row from the lead on whose name starts with it is selected.
public struct SidebarTypeSelect: Sendable {
    public static let resetInterval: TimeInterval = 1

    public private(set) var prefix = ""
    private var lastKeyTime: TimeInterval = -.infinity

    public init() {}

    /// Whether a key typed at `time` adds to the prefix rather than starting a new one; a space
    /// only selects as part of a name already being typed.
    public func continues(at time: TimeInterval) -> Bool {
        !prefix.isEmpty && time - lastKeyTime < Self.resetInterval
    }

    /// Adds the typed `characters` at `time` and returns the row to select, if any: from the lead
    /// itself while the prefix grows, from the row after it when a new prefix starts, wrapping round.
    /// `names` are the rows' names, matching `rows`.
    public mutating func type(
        _ characters: String,
        at time: TimeInterval,
        rows: [String],
        names: [String],
        leadID: String?
    ) -> String? {
        let continues = time - lastKeyTime < Self.resetInterval
        prefix = continues ? prefix + characters : characters
        lastKeyTime = time
        guard !rows.isEmpty, rows.count == names.count, !prefix.isEmpty else { return nil }

        let leadIndex = leadID.flatMap { rows.firstIndex(of: $0) }
        let start = leadIndex.map { continues ? $0 : $0 + 1 } ?? 0
        for step in 0..<rows.count {
            let index = (start + step) % rows.count
            if names[index].range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                return rows[index]
            }
        }
        return nil
    }
}
