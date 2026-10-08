import Foundation

/// The text of tab labels, design.md §10.3.
public enum DocumentTabLabel {
    /// Labels by document ID. A name shared by several tabs gets the shortest parent path that tells
    /// it apart from the others; every other tab shows its name alone.
    public static func labels(for tabs: [WorkspaceTabItem]) -> [String: String] {
        var labels: [String: String] = [:]
        for group in Dictionary(grouping: tabs, by: \.displayName).values {
            guard group.count > 1 else {
                labels[group[0].documentID] = group[0].displayName
                continue
            }
            let parents = group.map { Array($0.relativePath.split(separator: "/").dropLast()) }
            for (index, tab) in group.enumerated() {
                let others = parents.indices.filter { $0 != index }.map { parents[$0] }
                let ownParents = parents[index]
                let depth = (1...max(1, ownParents.count)).first { depth in
                    !others.contains { $0.suffix(depth) == ownParents.suffix(depth) }
                } ?? ownParents.count
                let prefix = ownParents.suffix(depth).joined(separator: "/")
                labels[tab.documentID] = prefix.isEmpty ? tab.displayName : "\(prefix)/\(tab.displayName)"
            }
        }
        return labels
    }

    /// Middle-elides `label` to fit `width`, keeping the extension whole: `improving-onb…rate.md`.
    /// The head says what the file is and the end says which one, so both are kept.
    public static func middleElided(
        _ label: String,
        toFit width: CGFloat,
        measure: (String) -> CGFloat
    ) -> String {
        guard measure(label) > width else { return label }
        let fileExtension = (label as NSString).pathExtension
        let tail = fileExtension.isEmpty || fileExtension.count + 1 >= label.count ? "" : ".\(fileExtension)"
        let body = Array(label.dropLast(tail.count))

        func elided(keeping kept: Int) -> String {
            let endCount = kept / 4
            return String(body.prefix(kept - endCount)) + "\u{2026}" + String(body.suffix(endCount)) + tail
        }

        var fitted = elided(keeping: 0)
        var low = 1
        var high = body.count - 1
        while low <= high {
            let kept = (low + high) / 2
            let candidate = elided(keeping: kept)
            if measure(candidate) <= width {
                fitted = candidate
                low = kept + 1
            } else {
                high = kept - 1
            }
        }
        return fitted
    }
}
