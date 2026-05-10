import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MarkprevTerminalSmokeTests {
    @MainActor
    static func main() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MarkprevTerminalSmokeTests-\(UUID().uuidString)", isDirectory: true)
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
                workspaceURL: root,
                selectedDocumentURL: note
            )?.standardizedFileURL == root.standardizedFileURL,
            "app-level terminal policy should prefer the workspace root over the selected file's folder"
        )
        expect(
            TerminalWorkingDirectoryPolicy.directory(
                workspaceURL: nil,
                selectedDocumentURL: note
            )?.standardizedFileURL == docs.standardizedFileURL,
            "app-level terminal policy should use the selected file parent only without a workspace root"
        )

        let collection = TerminalSessionCollectionStore()
        collection.ensureActiveTerminal(in: nil)
        expect(
            collection.activeSession == nil,
            "terminal collection should not create a home-directory session before an app directory is known"
        )

        collection.setDefaultDirectory(note)
        collection.ensureActiveTerminal(in: nil)
        guard let session = collection.activeSession else {
            fputs("FAIL: terminal collection should create a session once a default directory is known\n", stderr)
            exit(1)
        }
        expect(
            session.workingDirectory.standardizedFileURL == docs.standardizedFileURL,
            "terminal collection should create sessions in the selected file's parent directory"
        )
        collection.stopAll()

        print("Markprev terminal smoke tests passed")
    }
}
