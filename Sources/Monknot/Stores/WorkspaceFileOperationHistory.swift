import Foundation
import MonknotCore

/// A move, rename or copy of workspace items as one user action, which Edit › Undo takes back and
/// Edit › Redo makes again (design.md §10.4). A drop of several items is one operation.
struct WorkspaceFileOperation: Sendable {
    let verb: WorkspaceFileOperationVerb
    /// In the order they were made.
    let steps: [WorkspaceFileOperationStep]
    let workspaceURL: URL
    /// Orders the operation against the workspace Replace's undo: the newer goes first.
    var serial: Int

    /// What Edit › Undo and Redo name the operation: Move “a.md”, Copy 3 Items.
    var actionName: String {
        guard steps.count == 1, let step = steps.first else {
            return "\(verb.title) \(steps.count) Items"
        }
        return "\(verb.title) “\(step.itemName)”"
    }

    /// The bytes of note text the operation keeps to put rewritten links back.
    var retainedTextByteCount: Int {
        steps.reduce(0) { total, step in
            guard case .move(let move) = step else { return total }
            return total + move.rewrittenFiles.reduce(0) {
                $0 + $1.originalRevision.text.utf8.count + $1.writtenRevision.text.utf8.count
            }
        }
    }
}

enum WorkspaceFileOperationVerb: Sendable {
    case move
    case rename
    case copy
    case duplicate

    var title: String {
        switch self {
        case .move: "Move"
        case .rename: "Rename"
        case .copy: "Copy"
        case .duplicate: "Duplicate"
        }
    }
}

enum WorkspaceFileOperationStep: Sendable {
    case move(WorkspaceFileMoveStep)
    case copy(WorkspaceFileCopyStep)

    /// The name the item had when the user acted on it.
    var itemName: String {
        switch self {
        case .move(let move): move.sourceURL.lastPathComponent
        case .copy(let copy): copy.sourceURL.lastPathComponent
        }
    }
}

/// A file or folder Monknot moved or renamed, with the Markdown links the move rewrote. The source
/// may be in another workspace, when a Cut there was pasted here.
struct WorkspaceFileMoveStep: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let isDirectory: Bool
    let usedCaseOnlyRenameHop: Bool
    let rewrittenFiles: [WorkspaceFileMoveRewrite]
}

/// A note whose links a move rewrote. Its URL differs before and after the move when the note is
/// the moved item or inside it.
struct WorkspaceFileMoveRewrite: Sendable {
    let originalURL: URL
    let finalURL: URL
    let originalRevision: WorkspaceTextRevision
    let writtenRevision: WorkspaceTextRevision
}

/// A copy Monknot made of a file or folder.
struct WorkspaceFileCopyStep: Sendable {
    let sourceURL: URL
    /// The snapshot a pasted Copy was made of, while it exists.
    let contentsURL: URL?
    let copyURL: URL
    let isDirectory: Bool
}

enum WorkspaceFileOperationDirection: Sendable {
    case undo
    case redo

    var opposite: Self {
        self == .undo ? .redo : .undo
    }
}

/// What Edit › Undo and Redo offer for files, published for the menu.
struct WorkspaceFileOperationUndoState: Equatable, Sendable {
    var undoActionName: String?
    var redoActionName: String?
    /// Whether the operation to undo is newer than the workspace Replace that can be undone.
    var undoPrecedesWorkspaceReplace = true
}

/// The undo and redo stacks of file operations. They hold paths and the text of rewritten notes,
/// so they are bounded by count and by that text.
struct WorkspaceFileOperationHistory {
    static let maximumOperationCount = 50
    static let maximumRetainedTextBytes = 16 * 1024 * 1024

    private(set) var undoStack: [WorkspaceFileOperation] = []
    private(set) var redoStack: [WorkspaceFileOperation] = []

    var nextUndo: WorkspaceFileOperation? { undoStack.last }
    var nextRedo: WorkspaceFileOperation? { redoStack.last }

    /// A new action goes on top of Undo and ends what Redo held. The oldest operations go once the
    /// stacks pass their bounds; the newest always stays.
    mutating func record(_ operation: WorkspaceFileOperation) {
        undoStack.append(operation)
        redoStack.removeAll()
        while undoStack.count > 1,
              undoStack.count > Self.maximumOperationCount
                || undoStack.reduce(0, { $0 + $1.retainedTextByteCount }) > Self.maximumRetainedTextBytes {
            undoStack.removeFirst()
        }
    }

    mutating func didUndo() {
        guard let operation = undoStack.popLast() else { return }
        redoStack.append(operation)
    }

    /// The redone operation is the newest action again, with `serial`.
    mutating func didRedo(serial: Int) {
        guard var operation = redoStack.popLast() else { return }
        operation.serial = serial
        undoStack.append(operation)
    }

    /// Drops the operation Undo or Redo would make next, which the disk no longer matches.
    mutating func discardNext(_ direction: WorkspaceFileOperationDirection) {
        switch direction {
        case .undo: _ = undoStack.popLast()
        case .redo: _ = redoStack.popLast()
        }
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// Why an undo or redo of a file operation was refused or failed.
enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case itemMissing(name: String, folder: String)
    case nameTaken(name: String, folder: String)
    case folderMissing(String)
    case linksChanged(String)
    case outsideWorkspace(String)
    case rollbackFailed(operation: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .itemMissing(let name, let folder):
            "“\(name)” is no longer in “\(folder)”."
        case .nameTaken(let name, let folder):
            "Another item is now named “\(name)” in “\(folder)”."
        case .folderMissing(let folder):
            "“\(folder)” no longer exists."
        case .linksChanged(let name):
            "“\(name)” changed after the move updated its links."
        case .outsideWorkspace(let name):
            "“\(name)” is no longer safely inside the workspace."
        case .rollbackFailed(let operation, let rollback):
            operation.isEmpty
                ? "Putting things back was incomplete (\(rollback))."
                : "\(operation) Putting things back was incomplete (\(rollback))."
        }
    }
}

/// Makes an operation's steps on disk, backwards for Undo and forwards for Redo. Each step first
/// checks that the disk still matches what the operation left (the item is where it put it,
/// nothing took the name it goes back to, rewritten notes hold the text it wrote) and never
/// overwrites anything. An operation is all or nothing: a step that cannot be made puts back the
/// ones made before it.
struct WorkspaceFileOperationDisk: Sendable {
    let workspaceURL: URL
    let moveItemToTrash: @Sendable (URL) throws -> Void
    /// The unsaved text a copy made again carries, by the copied item's path: its own ("" subpath)
    /// and that of each document inside it, as Duplicate copies it.
    var unsavedCopyTexts: [String: [WorkspaceUnsavedCopyText]] = [:]

    func apply(_ operation: WorkspaceFileOperation, _ direction: WorkspaceFileOperationDirection) throws {
        let steps = direction == .undo ? Array(operation.steps.reversed()) : operation.steps
        var made: [WorkspaceFileOperationStep] = []
        do {
            for step in steps {
                try Task.checkCancellation()
                try apply(step, direction)
                made.append(step)
            }
        } catch {
            try putBack(made, after: direction, failure: error)
            throw error
        }
    }

    /// Reverses an operation `apply` made in `direction`, when what followed it (`failure`, or the
    /// store not taking its result) means it must not stand.
    func rollBack(
        _ operation: WorkspaceFileOperation,
        after direction: WorkspaceFileOperationDirection,
        failure: Error? = nil
    ) throws {
        let made = direction == .undo ? Array(operation.steps.reversed()) : operation.steps
        try putBack(made, after: direction, failure: failure)
    }

    private func putBack(
        _ made: [WorkspaceFileOperationStep],
        after direction: WorkspaceFileOperationDirection,
        failure: Error?
    ) throws {
        var failures: [String] = []
        for step in made.reversed() {
            do {
                try apply(step, direction.opposite)
            } catch {
                failures.append("\(step.itemName): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw WorkspaceFileOperationError.rollbackFailed(
                operation: failure?.localizedDescription ?? "",
                rollback: failures.joined(separator: "; ")
            )
        }
    }

    private func apply(_ step: WorkspaceFileOperationStep, _ direction: WorkspaceFileOperationDirection) throws {
        switch (step, direction) {
        case (.move(let move), .undo):
            try moveBack(move)
        case (.move(let move), .redo):
            try moveAgain(move)
        case (.copy(let copy), .undo):
            try checkItem(at: copy.copyURL, isDirectory: copy.isDirectory)
            try checkContainment(of: copy.copyURL)
            try moveItemToTrash(copy.copyURL)
        case (.copy(let copy), .redo):
            try copyAgain(copy)
        }
    }

    /// Puts each rewritten note's links back, then the item where it was.
    private func moveBack(_ move: WorkspaceFileMoveStep) throws {
        try checkMove(of: move, from: move.destinationURL, to: move.sourceURL)
        for rewrite in move.rewrittenFiles {
            try checkText(at: rewrite.finalURL, is: rewrite.writtenRevision)
        }

        var restored: [WorkspaceFileMoveRewrite] = []
        do {
            for rewrite in move.rewrittenFiles.reversed() {
                try write(rewrite.originalRevision, to: rewrite.finalURL, replacing: rewrite.writtenRevision)
                restored.append(rewrite)
            }
            try WorkspaceStore.moveWorkspaceItem(
                from: move.destinationURL,
                to: move.sourceURL,
                usingCaseOnlyRenameHop: move.usedCaseOnlyRenameHop
            )
        } catch {
            var failures: [String] = []
            for rewrite in restored.reversed() {
                do {
                    try write(rewrite.writtenRevision, to: rewrite.finalURL, replacing: rewrite.originalRevision)
                } catch {
                    failures.append("\(rewrite.finalURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard failures.isEmpty else {
                throw WorkspaceFileOperationError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: failures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    /// Moves the item again, then writes the links the move wrote.
    private func moveAgain(_ move: WorkspaceFileMoveStep) throws {
        try checkMove(of: move, from: move.sourceURL, to: move.destinationURL)
        for rewrite in move.rewrittenFiles {
            try checkText(at: rewrite.originalURL, is: rewrite.originalRevision)
        }

        try WorkspaceStore.moveWorkspaceItem(
            from: move.sourceURL,
            to: move.destinationURL,
            usingCaseOnlyRenameHop: move.usedCaseOnlyRenameHop
        )
        var written: [WorkspaceFileMoveRewrite] = []
        do {
            for rewrite in move.rewrittenFiles {
                try write(rewrite.writtenRevision, to: rewrite.finalURL, replacing: rewrite.originalRevision)
                written.append(rewrite)
            }
        } catch {
            var failures: [String] = []
            for rewrite in written.reversed() {
                do {
                    try write(rewrite.originalRevision, to: rewrite.finalURL, replacing: rewrite.writtenRevision)
                } catch {
                    failures.append("\(rewrite.finalURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            do {
                try WorkspaceStore.moveWorkspaceItem(
                    from: move.destinationURL,
                    to: move.sourceURL,
                    usingCaseOnlyRenameHop: move.usedCaseOnlyRenameHop
                )
            } catch {
                failures.append("move: \(error.localizedDescription)")
            }
            guard failures.isEmpty else {
                throw WorkspaceFileOperationError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: failures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    /// Copies the item again to the name its copy had, from the pasted snapshot while it exists.
    private func copyAgain(_ copy: WorkspaceFileCopyStep) throws {
        try checkItem(at: copy.sourceURL, isDirectory: copy.isDirectory)
        try checkTarget(copy.copyURL, isFree: true)
        try checkContainment(of: copy.copyURL)

        if let contentsURL = copy.contentsURL, FileManager.default.fileExists(atPath: contentsURL.path) {
            try FileManager.default.copyItem(at: contentsURL, to: copy.copyURL)
            return
        }
        try FileManager.default.copyItem(at: copy.sourceURL, to: copy.copyURL)
        do {
            for unsaved in unsavedCopyTexts[copy.sourceURL.standardizedFileURL.path] ?? [] {
                let url = unsaved.subpath.isEmpty ? copy.copyURL : copy.copyURL.appendingPathComponent(unsaved.subpath)
                try WorkspaceTextFileGuard.writeUTF8Text(unsaved.text, to: url)
            }
        } catch {
            try? moveItemToTrash(copy.copyURL)
            throw error
        }
    }

    // MARK: Checks

    private func checkMove(of move: WorkspaceFileMoveStep, from currentURL: URL, to targetURL: URL) throws {
        try checkItem(at: currentURL, isDirectory: move.isDirectory)
        try checkTarget(targetURL, isFree: !WorkspaceFileIdentity.isCaseOnlyRename(from: currentURL, to: targetURL))
        try checkContainment(of: currentURL)
        try checkContainment(of: targetURL)
    }

    /// The item is at `url`, and is still a folder or a file as it was. A symbolic link is the
    /// link, as the move recorded it.
    private func checkItem(at url: URL, isDirectory: Bool) throws {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
              (type == .typeDirectory) == isDirectory
        else {
            throw WorkspaceFileOperationError.itemMissing(name: url.lastPathComponent, folder: folderName(of: url))
        }
    }

    /// The folder `url` goes into exists and, when `isFree`, nothing has its name there.
    private func checkTarget(_ url: URL, isFree: Bool) throws {
        let folderURL = url.deletingLastPathComponent()
        var folderIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &folderIsDirectory),
              folderIsDirectory.boolValue
        else {
            throw WorkspaceFileOperationError.folderMissing(folderURL.lastPathComponent)
        }
        // A broken symbolic link holds the name too.
        if isFree, (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            throw WorkspaceFileOperationError.nameTaken(name: url.lastPathComponent, folder: folderName(of: url))
        }
    }

    /// An end of the operation inside the workspace is still inside it once symbolic links are
    /// followed. A Cut pasted from another workspace goes back outside this one.
    private func checkContainment(of url: URL) throws {
        guard WorkspaceDocumentSupport.isURL(url, containedIn: workspaceURL) else { return }
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard WorkspaceStore.isCanonicalURL(folder, containedIn: root) else {
            throw WorkspaceFileOperationError.outsideWorkspace(url.lastPathComponent)
        }
    }

    private func checkText(at url: URL, is revision: WorkspaceTextRevision) throws {
        guard let current = try? WorkspaceConditionalTextWriter.read(from: url), current == revision else {
            throw WorkspaceFileOperationError.linksChanged(url.lastPathComponent)
        }
    }

    private func write(
        _ revision: WorkspaceTextRevision,
        to url: URL,
        replacing expected: WorkspaceTextRevision
    ) throws {
        do {
            try WorkspaceConditionalTextWriter.write(revision.text, to: url, expecting: .present(expected))
        } catch WorkspaceTextRevisionError.changedOnDisk {
            throw WorkspaceFileOperationError.linksChanged(url.lastPathComponent)
        }
    }

    private func folderName(of url: URL) -> String {
        let folderURL = url.deletingLastPathComponent().standardizedFileURL
        return folderURL == workspaceURL.standardizedFileURL
            ? workspaceURL.lastPathComponent
            : folderURL.lastPathComponent
    }
}

/// Unsaved text a copy carries in place of the file's: the copied file's own (`subpath` "") or a
/// document's inside a copied folder.
struct WorkspaceUnsavedCopyText: Sendable {
    let subpath: String
    let text: String
}
