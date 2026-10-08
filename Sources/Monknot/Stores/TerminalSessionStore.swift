import Combine
import Foundation

enum TerminalSessionStatus: Equatable {
    case idle
    case running
    case exited(Int32?)
    case failed(String)
}

/// The raw bytes a terminal session has produced, so that its view can show output that arrived before
/// it finished loading. Bytes rather than a String: a read can end inside a UTF-8 sequence, and only
/// the terminal emulator's decoder joins the halves correctly.
struct TerminalOutputLog: Equatable {
    static let defaultCapacity = 2 * 1024 * 1024

    let capacity: Int
    private(set) var chunks: [Data] = []
    /// Absolute offset of the first kept byte; older bytes were dropped to stay within `capacity`.
    private(set) var startOffset = 0
    private(set) var endOffset = 0

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = capacity
    }

    mutating func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        chunks.append(bytes)
        endOffset += bytes.count
        while endOffset - startOffset > capacity, chunks.count > 1 {
            startOffset += chunks.removeFirst().count
        }
    }

    /// The bytes from `offset` to the end, or `nil` when some of them were already dropped.
    func bytes(from offset: Int) -> Data? {
        guard offset >= startOffset else { return nil }
        var result = Data()
        var chunkStart = startOffset
        for chunk in chunks {
            let chunkEnd = chunkStart + chunk.count
            if chunkEnd > offset {
                result.append(chunk.dropFirst(max(0, offset - chunkStart)))
            }
            chunkStart = chunkEnd
        }
        return result
    }
}

/// The live view of a terminal session. It stays with the session, so hiding the drawer or switching
/// terminal tabs never throws away the screen, its modes or its scrollback.
@MainActor
protocol TerminalSessionPresentation: AnyObject {
    /// New output was appended to `output`, or `outputEpoch` changed because the session restarted.
    func sessionOutputDidChange()
    /// The session was stopped for good; release the view.
    func sessionDidStop()
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: URL
    @Published private(set) var status: TerminalSessionStatus = .idle
    /// Everything the current process printed. Not published: output arrives every frame and only the
    /// presentation reads it.
    private(set) var output = TerminalOutputLog()
    /// Changes when the output starts over (a restart), so a view knows to reset rather than append.
    private(set) var outputEpoch = 0
    var presentation: TerminalSessionPresentation?

    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let maxPendingOutputBeforeFlush = 32_000
    private let outputFlushIntervalNanoseconds: UInt64 = 16_000_000
    private var ptySession: TerminalPTYSession?
    private var sessionGeneration = 0
    private var pendingOutput = Data()
    private var outputFlushTask: Task<Void, Never>?
    /// The size the view last reported. A restarted shell starts at it: the view keeps its size across
    /// a restart and reports only changes.
    private var terminalSize = (columns: 100, rows: 32)

    init(initialDirectory: URL? = nil) {
        workingDirectory = Self.resolvedDirectory(initialDirectory) ?? Self.homeDirectory
    }

    func startIfNeeded() {
        startIfNeeded(in: nil)
    }

    func startIfNeeded(in directory: URL?) {
        guard ptySession == nil else { return }
        guard status == .idle else { return }

        workingDirectory = Self.resolvedDirectory(directory ?? workingDirectory) ?? workingDirectory
        beginNewOutput()
        isRunning = true
        status = .running
        sessionGeneration += 1
        let generation = sessionGeneration

        let session = TerminalPTYSession(
            outputHandler: { [weak self] bytes in
                Task { @MainActor in
                    self?.enqueueOutput(bytes, generation: generation)
                }
            },
            exitHandler: { [weak self] status in
                Task { @MainActor in
                    self?.handleExit(status, generation: generation)
                }
            }
        )

        do {
            try session.start(
                workingDirectory: workingDirectory,
                columns: terminalSize.columns,
                rows: terminalSize.rows
            )
            ptySession = session
        } catch {
            appendStatusLine("monknot: \(error.localizedDescription)")
            isRunning = false
            status = .failed(error.localizedDescription)
        }
        presentation?.sessionOutputDidChange()
    }

    func restart() {
        restart(in: workingDirectory)
    }

    func restart(in directory: URL?) {
        workingDirectory = Self.resolvedDirectory(directory) ?? workingDirectory
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        isRunning = false
        status = .idle
        startIfNeeded()
    }

    func send(_ text: String) {
        startIfNeeded()
        guard isRunning else { return }
        ptySession?.write(text)
    }

    func send(_ bytes: Data) {
        startIfNeeded()
        guard isRunning else { return }
        ptySession?.write(bytes)
    }

    func resize(columns: Int, rows: Int) {
        terminalSize = (columns, rows)
        ptySession?.resize(columns: columns, rows: rows)
    }

    func stop() {
        flushPendingOutput(generation: sessionGeneration)
        sessionGeneration += 1
        ptySession?.stop()
        ptySession = nil
        pendingOutput = Data()
        outputFlushTask?.cancel()
        outputFlushTask = nil
        isRunning = false
        status = .idle
        presentation?.sessionDidStop()
        presentation = nil
    }

    private func beginNewOutput() {
        output = TerminalOutputLog()
        outputEpoch += 1
        pendingOutput = Data()
        outputFlushTask?.cancel()
        outputFlushTask = nil
    }

    private func enqueueOutput(_ bytes: Data, generation: Int) {
        guard generation == sessionGeneration else { return }

        pendingOutput.append(bytes)

        if pendingOutput.count >= maxPendingOutputBeforeFlush {
            outputFlushTask?.cancel()
            flushPendingOutput(generation: generation)
            return
        }

        guard outputFlushTask == nil else { return }
        let flushInterval = outputFlushIntervalNanoseconds
        outputFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: flushInterval)
            } catch {
                return
            }

            self?.flushPendingOutput(generation: generation)
        }
    }

    private func flushPendingOutput(generation: Int) {
        outputFlushTask = nil
        guard generation == sessionGeneration else {
            pendingOutput = Data()
            return
        }
        guard !pendingOutput.isEmpty else { return }

        output.append(pendingOutput)
        pendingOutput = Data()
        presentation?.sessionOutputDidChange()
    }

    private func handleExit(_ status: Int32?, generation: Int) {
        guard generation == sessionGeneration else { return }

        flushPendingOutput(generation: generation)
        isRunning = false
        self.status = .exited(status)
        ptySession = nil

        if let status {
            appendStatusLine("[Process exited with status \(status)]")
        } else {
            appendStatusLine("[Process exited]")
        }
        presentation?.sessionOutputDidChange()
    }

    /// A line of Monknot's own on its own row; the terminal does not translate a bare newline.
    private func appendStatusLine(_ line: String) {
        output.append(Data("\r\n\(line)\r\n".utf8))
    }

    deinit {
        outputFlushTask?.cancel()
        ptySession?.stop()
    }

    static func resolvedDirectory(_ url: URL?, containedIn workspaceRoot: URL? = nil) -> URL? {
        guard let url else { return nil }

        let standardizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)

        let resolvedDirectory: URL
        if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            resolvedDirectory = isDirectory.boolValue ? standardizedURL : standardizedURL.deletingLastPathComponent()
        } else {
            let parentURL = standardizedURL.deletingLastPathComponent()
            var parentIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
                  parentIsDirectory.boolValue
            else {
                return Self.resolvedDirectory(workspaceRoot)
            }
            resolvedDirectory = parentURL
        }

        guard let workspaceRoot else { return resolvedDirectory }
        let resolvedRoot = workspaceRoot.standardizedFileURL
        var rootIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: resolvedRoot.path,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            return nil
        }
        let canonicalDirectory = resolvedDirectory.resolvingSymlinksInPath()
        let canonicalRoot = resolvedRoot.resolvingSymlinksInPath()
        let rootComponents = canonicalRoot.pathComponents
        let directoryComponents = canonicalDirectory.pathComponents
        guard directoryComponents.count >= rootComponents.count,
              Array(directoryComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return resolvedRoot
        }
        return resolvedDirectory
    }
}
