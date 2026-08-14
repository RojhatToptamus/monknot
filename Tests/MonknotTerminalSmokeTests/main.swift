import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MonknotTerminalSmokeTests {
    @MainActor
    static func main() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MonknotTerminalSmokeTests-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let note = docs.appendingPathComponent("Note.md")
        defer {
            try? fileManager.removeItem(at: root)
        }

        do {
            try fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
            try "# Note\n".write(to: note, atomically: true, encoding: .utf8)
        } catch {
            fputs("FAIL: could not prepare terminal smoke workspace: \(error)\n", stderr)
            exit(1)
        }

        expect(
            TerminalSessionStore.resolvedDirectory(nil) == nil,
            "nil terminal directory should not resolve to the user's home directory"
        )
        expect(
            TerminalSessionStore.resolvedDirectory(note)?.standardizedFileURL == docs.standardizedFileURL,
            "selected file should resolve to its parent directory"
        )
        expect(
            TerminalSessionStore.resolvedDirectory(docs)?.standardizedFileURL == docs.standardizedFileURL,
            "selected directory should resolve to itself"
        )
        expect(
            TerminalSessionStore.resolvedDirectory(docs.appendingPathComponent("Draft.md"))?.standardizedFileURL == docs.standardizedFileURL,
            "a missing file path with an existing parent should resolve to the parent directory"
        )
        expect(
            TerminalWorkingDirectoryPolicy.directory(
                preference: .activeDocumentFolder,
                workspaceURL: root,
                selectedDocumentURL: note
            )?.standardizedFileURL == docs.standardizedFileURL,
            "the default terminal policy should use the selected file's folder"
        )
        expect(
            TerminalWorkingDirectoryPolicy.directory(
                preference: .workspaceRoot,
                workspaceURL: root,
                selectedDocumentURL: note
            )?.standardizedFileURL == root.standardizedFileURL,
            "the workspace-root terminal policy should use the workspace root"
        )
        let external = fileManager.temporaryDirectory.appendingPathComponent("External.md")
        expect(
            TerminalWorkingDirectoryPolicy.directory(
                preference: .activeDocumentFolder,
                workspaceURL: root,
                selectedDocumentURL: external
            )?.standardizedFileURL == root.standardizedFileURL,
            "external documents should fall back to the workspace root"
        )

        let collection = TerminalSessionCollectionStore()
        collection.ensureActiveTerminal(in: nil)
        expect(
            collection.activeSession == nil,
            "terminal collection should not create a home-directory session before an app directory is known"
        )

        collection.ensureActiveTerminal(in: docs, workspaceRoot: root)
        guard let session = collection.activeSession else {
            fputs("FAIL: terminal collection should create a session once a default directory is known\n", stderr)
            exit(1)
        }
        expect(
            session.workingDirectory.standardizedFileURL == docs.standardizedFileURL,
            "terminal collection should create sessions in the selected file's parent directory"
        )

        let otherRoot = root.appendingPathComponent("Other", isDirectory: true)
        try? fileManager.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        guard let secondSession = collection.createTerminal(in: otherRoot, workspaceRoot: otherRoot) else {
            fputs("FAIL: terminal collection should create a second session in a new workspace\n", stderr)
            exit(1)
        }
        expect(
            session.workingDirectory.standardizedFileURL == docs.standardizedFileURL,
            "changing workspaces must not move an existing terminal"
        )
        expect(
            secondSession.workingDirectory.standardizedFileURL == otherRoot.standardizedFileURL,
            "a new terminal should use the new workspace directory"
        )
        collection.stopAll()

        print("Monknot terminal smoke tests passed")
    }
}
