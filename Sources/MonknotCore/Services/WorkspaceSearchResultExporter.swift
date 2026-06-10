import Foundation

public enum WorkspaceSearchResultExporter {
    public static func tabSeparatedText(
        results: [WorkspaceSearchResult],
        query: String
    ) -> String {
        var lines = ["path\tline\tpreview\tquery"]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for result in results {
            let location = result.kind == .pdf ? "p\(result.line)" : "\(result.line)"
            let preview = result.preview
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("\(result.relativePath)\t\(location)\t\(preview)\t\(trimmedQuery)")
        }
        return lines.joined(separator: "\n")
    }
}
