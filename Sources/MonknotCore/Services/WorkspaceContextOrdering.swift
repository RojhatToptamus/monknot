import Foundation

public enum WorkspaceContextOrdering: Sendable {
    public static func orderedContextPaths(from paths: [String], preferredRelativePaths: [String]) -> [String] {
        let pathSet = Set(paths)
        var seen = Set<String>()
        var ordered: [String] = []

        for path in preferredRelativePaths where pathSet.contains(path) {
            guard seen.insert(path).inserted else { continue }
            ordered.append(path)
        }

        for path in paths {
            guard seen.insert(path).inserted else { continue }
            ordered.append(path)
        }

        return ordered
    }
}
