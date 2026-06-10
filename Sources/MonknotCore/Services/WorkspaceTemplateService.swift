import Foundation

public enum WorkspaceTemplateService {
    public static func bootstrapStarterWorkspace(at rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        let readmeURL = root.appendingPathComponent("README.md")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inbox"),
            withIntermediateDirectories: true
        )

        try writeIfMissing("""
        # Workspace

        Start here. Use this file as the map for the project, notes, and documents in this folder.

        ## Focus

        - Current priority:
        - Next decision:
        - Open questions:

        ## Links

        - [[Project Brief]]
        - [[Ideas]]
        """, to: readmeURL)

        try writeIfMissing("""
        # Project Brief

        ## Goal

        ## Constraints

        ## Decisions

        ## Next Steps

        - [ ]
        """, to: root.appendingPathComponent("docs/Project Brief.md"))

        try writeIfMissing("""
        # Ideas

        Capture loose ideas here, then link or move them into project notes when they become concrete.
        """, to: root.appendingPathComponent("notes/Ideas.md"))

        try writeIfMissing("", to: root.appendingPathComponent("inbox/.gitkeep"))

        return readmeURL
    }

    private static func writeIfMissing(_ text: String, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
