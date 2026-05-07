import Darwin
import Foundation

enum TerminalPTYError: LocalizedError {
    case openMasterFailed
    case grantFailed
    case unlockFailed
    case slaveNameFailed
    case openSlaveFailed

    var errorDescription: String? {
        switch self {
        case .openMasterFailed:
            return "Could not open a pseudo-terminal."
        case .grantFailed:
            return "Could not grant pseudo-terminal access."
        case .unlockFailed:
            return "Could not unlock the pseudo-terminal."
        case .slaveNameFailed:
            return "Could not resolve the pseudo-terminal device."
        case .openSlaveFailed:
            return "Could not open the pseudo-terminal device."
        }
    }
}

final class TerminalPTYSession {
    private let outputHandler: @Sendable (String) -> Void
    private let exitHandler: @Sendable (Int32?) -> Void
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "com.local.Markprev.terminal-pty")
    private let stateLock = NSLock()
    private var didFinish = false

    init(
        outputHandler: @escaping @Sendable (String) -> Void,
        exitHandler: @escaping @Sendable (Int32?) -> Void
    ) {
        self.outputHandler = outputHandler
        self.exitHandler = exitHandler
    }

    func start(workingDirectory: URL) throws {
        guard childPID <= 0 else { return }

        let shellPath = strdup("/bin/zsh")
        let arg0 = strdup("zsh")
        let arg1 = strdup("-il")
        let cwdPath = strdup(workingDirectory.path)
        defer {
            free(shellPath)
            free(arg0)
            free(arg1)
            free(cwdPath)
        }

        guard let shellPath, let arg0, let arg1, let cwdPath else {
            throw TerminalPTYError.openMasterFailed
        }

        var master: Int32 = -1
        var windowSize = winsize(ws_row: 32, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &windowSize)

        guard pid >= 0 else {
            throw TerminalPTYError.openMasterFailed
        }

        if pid == 0 {
            chdir(cwdPath)
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("CLICOLOR", "1", 1)
            setenv("MARKPREV_TERMINAL", "1", 1)

            var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
            execv(shellPath, &argv)
            _exit(127)
        }

        masterFD = master
        childPID = pid
        didFinish = false
        startReading(masterFD: master)
        waitForChild(pid)
    }

    func write(_ string: String) {
        guard masterFD >= 0, let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(masterFD, baseAddress, buffer.count)
        }
    }

    func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var windowSize = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &windowSize)
    }

    func stop() {
        stopReadSource()

        if childPID > 0 {
            kill(childPID, SIGTERM)
            childPID = -1
        }

        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func startReading(masterFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        source.setCancelHandler { }
        readSource = source
        source.resume()
    }

    private func readAvailableOutput() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(masterFD, &buffer, buffer.count)

        if count > 0 {
            outputHandler(String(decoding: buffer.prefix(count), as: UTF8.self))
        } else {
            finish(status: nil)
        }
    }

    private func stopReadSource() {
        readSource?.cancel()
        readSource = nil
    }

    private func waitForChild(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitCode = (status >> 8) & 0xFF
            self?.finish(status: Int32(exitCode))
        }
    }

    private func finish(status: Int32?) {
        stateLock.lock()
        if didFinish {
            stateLock.unlock()
            return
        }
        didFinish = true
        stateLock.unlock()

        stopReadSource()
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        childPID = -1
        exitHandler(status)
    }

    deinit {
        stop()
    }
}
