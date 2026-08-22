import Foundation

public enum WorkspaceSearchResultExporter {
    public static func tabSeparatedText(
        results: [WorkspaceSearchResult],
        query: String
    ) -> String {
        var lines = ["path\tline\tpreview\tquery"]
        let trimmedQuery = sanitized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        for result in results {
            let location = result.kind == .pdf ? "p\(result.line)" : "\(result.line)"
            lines.append("\(sanitized(result.relativePath))\t\(location)\t\(sanitized(result.preview))\t\(trimmedQuery)")
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
