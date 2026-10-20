import Foundation
import MonknotCore

/// A move, rename, copy or Move to Trash of workspace items as one user action, which Edit › Undo
/// takes back and Edit › Redo makes again (design.md §10.4). A drop of several items is one
/// operation.
struct WorkspaceFileOperation: Sendable {
    let verb: WorkspaceFileOperationVerb
    /// In the order they were made.
    var steps: [WorkspaceFileOperationStep]
    let workspaceURL: URL
    /// Orders the operation against the workspace Replace's undo: the newer goes first.
    var serial: Int

    /// What Edit › Undo and Redo name the operation: Move “a.md”, Copy 3 Items, Move 2 Items to
    /// Trash.
    var actionName: String {
        let subject = steps.count == 1 ? "“\(steps[0].itemName)”" : "\(steps.count) Items"
        return verb == .trash ? "Move \(subject) to Trash" : "\(verb.title) \(subject)"
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
    case trash

    var title: String {
        switch self {
        case .move: "Move"
        case .rename: "Rename"
        case .copy: "Copy"
        case .duplicate: "Duplicate"
        case .trash: "Move to Trash"
        }
    }
}

enum WorkspaceFileOperationStep: Sendable {
    case move(WorkspaceFileMoveStep)
    case copy(WorkspaceFileCopyStep)
    case trash(WorkspaceFileTrashStep)

    /// The name the item had when the user acted on it.
    var itemName: String {
        switch self {
        case .move(let move): move.sourceURL.lastPathComponent
        case .copy(let copy): copy.sourceURL.lastPathComponent
        case .trash(let trash): trash.originalURL.lastPathComponent
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
    /// The copy as it was made, so undoing it refuses once it has been edited since.
    var fingerprint: WorkspaceItemFingerprint?
}

/// A file or folder Monknot moved to the Trash, and where the Trash keeps it.
struct WorkspaceFileTrashStep: Sendable {
    let originalURL: URL
    let trashedURL: URL
    let isDirectory: Bool
}

/// What a file or folder holds, as far as an undo needs to know whether it changed: each file's
/// size and modification date, and each item's path inside a folder.
struct WorkspaceItemFingerprint: Equatable, Sendable {
    private let entries: [Entry]

    private struct Entry: Equatable, Sendable {
        let subpath: String
        let size: Int?
        let modified: Date?
    }

    /// Nil when the item cannot be read. Reads the disk each time: a `URL` keeps the resource values
    /// it read once, which would hide a change.
    static func read(_ url: URL) -> WorkspaceItemFingerprint? {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let isFolder = attributes[.type] as? FileAttributeType == .typeDirectory
        var entries = [entry("", attributes, isFolder: isFolder)]
        if isFolder, let subpaths = FileManager.default.subpaths(atPath: path) {
            // Hidden files (a .DS_Store Finder writes on viewing the folder) are not the copy's
            // content, so they never make an undo refuse.
            for subpath in subpaths.sorted() where !subpath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                let itemAttributes = (try? FileManager.default.attributesOfItem(atPath: path + "/" + subpath)) ?? [:]
                entries.append(entry(subpath, itemAttributes, isFolder: itemAttributes[.type] as? FileAttributeType == .typeDirectory))
            }
        }
        return WorkspaceItemFingerprint(entries: entries)
    }

    private static func entry(_ subpath: String, _ attributes: [FileAttributeKey: Any], isFolder: Bool) -> Entry {
        Entry(
            subpath: subpath,
            size: isFolder ? nil : (attributes[.size] as? NSNumber)?.intValue,
            modified: isFolder ? nil : attributes[.modificationDate] as? Date
        )
    }
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
    /// Whether there is an operation to undo newer than the workspace Replace that can be undone.
    var undoPrecedesWorkspaceReplace = false
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
    /// stacks pass their bounds. An operation that alone keeps more text than the bound is not
    /// kept, and nothing older is either: Undo can never step past an operation it cannot undo.
    mutating func record(_ operation: WorkspaceFileOperation) {
        redoStack.removeAll()
        var retainedBytes = operation.retainedTextByteCount
        guard retainedBytes <= Self.maximumRetainedTextBytes else {
            undoStack.removeAll()
            return
        }
        undoStack.append(operation)
        retainedBytes = undoStack.reduce(0) { $0 + $1.retainedTextByteCount }
        while undoStack.count > Self.maximumOperationCount || retainedBytes > Self.maximumRetainedTextBytes {
            retainedBytes -= undoStack.removeFirst().retainedTextByteCount
        }
    }

    mutating func didUndo() {
        guard let operation = undoStack.popLast() else { return }
        redoStack.append(operation)
    }

    /// The redone operation is the newest action again, with `serial`, as `redone` made it (a copy
    /// made again is a new copy).
    mutating func didRedo(serial: Int, redone: WorkspaceFileOperation) {
        guard redoStack.popLast() != nil else { return }
        var operation = redone
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
    case copyChanged(String)
    case notInTrash(String)
    /// A note with unsaved changes links to what the step moves: the step waits until it is saved.
    case unsavedLinks(note: String, undoing: Bool)
    case rollbackFailed(operation: String, rollback: String)

    /// The operation still matches the disk, so it stays to be undone or redone later.
    var keepsOperation: Bool {
        if case .unsavedLinks = self { return true }
        return false
    }

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
        case .copyChanged(let name):
            "“\(name)” changed after it was made."
        case .notInTrash(let name):
            "“\(name)” is no longer in the Trash."
        case .unsavedLinks(let note, let undoing):
            "Save \(note) first: its unsaved links would no longer lead where they do after \(undoing ? "undoing" : "redoing") this move."
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
    let moveItemToTrash: @Sendable (URL) throws -> URL?
    /// The unsaved text a copy made again carries, by the copied item's path: its own ("" subpath)
    /// and that of each document inside it, as Duplicate copies it.
    var unsavedCopyTexts: [String: [WorkspaceUnsavedCopyText]] = [:]
    /// The Markdown notes with unsaved changes, and the workspace's documents, which a move checks
    /// before it changes anything, as the move itself did.
    var unsavedMarkdown: [WorkspaceUnsavedMarkdown] = []
    var documents: [WorkspaceDocument] = []

    /// Makes the steps and returns the operation as made: a copy made again carries the new copy's
    /// fingerprint.
    @discardableResult
    func apply(_ operation: WorkspaceFileOperation, _ direction: WorkspaceFileOperationDirection) throws -> WorkspaceFileOperation {
        let steps = direction == .undo ? Array(operation.steps.reversed()) : operation.steps
        try checkUnsavedLinks(steps, direction)
        var made: [WorkspaceFileOperationStep] = []
        do {
            for step in steps {
                try Task.checkCancellation()
                made.append(try apply(step, direction))
            }
        } catch {
            try putBack(made, after: direction, failure: error)
            throw error
        }
        var applied = operation
        applied.steps = direction == .undo ? made.reversed() : made
        return applied
    }

    /// A move would leave a link in unsaved text pointing where the item no longer is: the move
    /// refused that, and its undo and redo do too.
    private func checkUnsavedLinks(_ steps: [WorkspaceFileOperationStep], _ direction: WorkspaceFileOperationDirection) throws {
        guard !unsavedMarkdown.isEmpty else { return }
        let planner = MarkdownLinkMovePlanner()
        for case .move(let move) in steps {
            let (fromURL, toURL) = direction == .undo
                ? (move.destinationURL, move.sourceURL)
                : (move.sourceURL, move.destinationURL)
            guard WorkspaceDocumentSupport.isURL(fromURL, containedIn: workspaceURL),
                  WorkspaceDocumentSupport.isURL(toURL, containedIn: workspaceURL)
            else { continue }
            for unsaved in unsavedMarkdown {
                let rewrites = try? planner.rewrites(
                    in: unsaved.text,
                    of: unsaved.document,
                    moving: fromURL,
                    to: toURL,
                    workspaceRootURL: workspaceURL,
                    documents: documents
                )
                if rewrites?.isEmpty != true {
                    throw WorkspaceFileOperationError.unsavedLinks(note: unsaved.document.displayName, undoing: direction == .undo)
                }
            }
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
                _ = try apply(step, direction.opposite)
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

    private func apply(_ step: WorkspaceFileOperationStep, _ direction: WorkspaceFileOperationDirection) throws -> WorkspaceFileOperationStep {
        switch (step, direction) {
        case (.move(let move), .undo):
            try moveBack(move)
        case (.move(let move), .redo):
            try moveAgain(move)
        case (.copy(let copy), .undo):
            try checkItem(at: copy.copyURL, isDirectory: copy.isDirectory)
            try checkContainment(of: copy.copyURL)
            if let fingerprint = copy.fingerprint, WorkspaceItemFingerprint.read(copy.copyURL) != fingerprint {
                throw WorkspaceFileOperationError.copyChanged(copy.copyURL.lastPathComponent)
            }
            _ = try moveItemToTrash(copy.copyURL)
        case (.copy(let copy), .redo):
            return .copy(try copyAgain(copy))
        case (.trash(let trash), .undo):
            try putBackFromTrash(trash)
        case (.trash(let trash), .redo):
            return .trash(try trashAgain(trash))
        }
        return step
    }

    /// Moves the item from the Trash back to the name it had, which must still be free.
    private func putBackFromTrash(_ trash: WorkspaceFileTrashStep) throws {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: trash.trashedURL.path))?[.type] as? FileAttributeType,
              (type == .typeDirectory) == trash.isDirectory
        else {
            throw WorkspaceFileOperationError.notInTrash(trash.originalURL.lastPathComponent)
        }
        try checkTarget(trash.originalURL, isFree: true)
        try checkContainment(of: trash.originalURL)
        try FileManager.default.moveItem(at: trash.trashedURL, to: trash.originalURL)
    }

    /// Moves the item put back to the Trash again, and returns the step with where the Trash keeps
    /// it now.
    private func trashAgain(_ trash: WorkspaceFileTrashStep) throws -> WorkspaceFileTrashStep {
        try checkItem(at: trash.originalURL, isDirectory: trash.isDirectory)
        try checkContainment(of: trash.originalURL)
        let trashedURL = try moveItemToTrash(trash.originalURL) ?? trash.trashedURL
        return WorkspaceFileTrashStep(originalURL: trash.originalURL, trashedURL: trashedURL, isDirectory: trash.isDirectory)
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

    /// Copies the item again to the name its copy had, from the pasted snapshot while it exists, and
    /// returns the step with the new copy's fingerprint.
    private func copyAgain(_ copy: WorkspaceFileCopyStep) throws -> WorkspaceFileCopyStep {
        try checkItem(at: copy.sourceURL, isDirectory: copy.isDirectory)
        try checkTarget(copy.copyURL, isFree: true)
        try checkContainment(of: copy.copyURL)

        if let contentsURL = copy.contentsURL, FileManager.default.fileExists(atPath: contentsURL.path) {
            try FileManager.default.copyItem(at: contentsURL, to: copy.copyURL)
        } else {
            try FileManager.default.copyItem(at: copy.sourceURL, to: copy.copyURL)
            do {
                for unsaved in unsavedCopyTexts[copy.sourceURL.standardizedFileURL.path] ?? [] {
                    let url = unsaved.subpath.isEmpty ? copy.copyURL : copy.copyURL.appendingPathComponent(unsaved.subpath)
                    try WorkspaceTextFileGuard.writeUTF8Text(unsaved.text, to: url)
                }
            } catch {
                _ = try? moveItemToTrash(copy.copyURL)
                throw error
            }
        }
        var made = copy
        made.fingerprint = WorkspaceItemFingerprint.read(copy.copyURL)
        return made
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

/// A Markdown note's unsaved text.
struct WorkspaceUnsavedMarkdown: Sendable {
    let document: WorkspaceDocument
    let text: String
}
