import Foundation

public struct WorkspaceReplacePreview: Equatable, Sendable {
    public let fileResults: [WorkspaceReplaceFileResult]
    public let totalReplacements: Int
    public let skippedDirtyCount: Int
    public let skippedLargeFileCount: Int

    public init(
        fileResults: [WorkspaceReplaceFileResult],
        totalReplacements: Int,
        skippedDirtyCount: Int = 0,
        skippedLargeFileCount: Int = 0
    ) {
        self.fileResults = fileResults
        self.totalReplacements = totalReplacements
        self.skippedDirtyCount = skippedDirtyCount
        self.skippedLargeFileCount = skippedLargeFileCount
    }

    public var affectedFileCount: Int {
        fileResults.count
    }

    public var hasMatches: Bool {
        totalReplacements > 0
    }

    public static func summaryMessage(for preview: WorkspaceReplacePreview) -> String {
        guard preview.hasMatches else {
            return "No replaceable matches were found."
        }

        var lines = [
            "\(preview.totalReplacements) replacement\(preview.totalReplacements == 1 ? "" : "s") in \(preview.affectedFileCount) file\(preview.affectedFileCount == 1 ? "" : "s"):"
        ]

        for result in preview.fileResults.prefix(12) {
            lines.append("• \(result.relativePath) (\(result.replacementCount))")
        }

        if preview.fileResults.count > 12 {
            lines.append("• …and \(preview.fileResults.count - 12) more file(s)")
        }

        if preview.skippedDirtyCount > 0 {
            lines.append("\(preview.skippedDirtyCount) unsaved file\(preview.skippedDirtyCount == 1 ? "" : "s") will be skipped.")
        }

        if preview.skippedLargeFileCount > 0 {
            lines.append("\(preview.skippedLargeFileCount) large file\(preview.skippedLargeFileCount == 1 ? "" : "s") will be skipped.")
        }

        return lines.joined(separator: "\n")
    }
}
